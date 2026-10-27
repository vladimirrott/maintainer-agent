#!/usr/bin/env python3
"""Hold the documentation to what the tree does. One checker, one check per claim.

    check_drift.py [--root DIR] [--only NAME]...    run every check, or the named ones

Exits 0 when every check passes, 1 and one line per problem when any fails.
`--root` points at a copy of the tree, which is how tests/run-tests.sh plants a
defect and proves each check fails on it.

Each check is a function registered by name in CHECKS. A check returns a list of
problem strings, and a check that could not read what it compares returns a
problem too: an empty answer from something that was not read is not a pass.
"""
from __future__ import annotations

import argparse
import ast
import io
import re
import sys
import tokenize
from pathlib import Path

# No .pyc: a bytecode file beside the script records the absolute path of whoever
# ran it, and the suite greps the tree for exactly that.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_figures  # noqa: E402  one counting module for this checker and check_claims.sh


def _read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


# --- repo-names -------------------------------------------------------------
# README: "Nothing in bin/ or lib/ carries a repository's name." That holds for
# executable lines. Comments and docstrings cite the incidents that taught each
# rule, and the incidents name their repositories, so they are not scanned.

# The tool's own name is also the name of the repository the `magent` profile
# maintains, so it cannot count as a project name. `sysknife-maint` is the old
# name of this tool, kept in two strings that recognise reports written under it.
_OWN_NAMES = {"maintainer-agent"}
_LEGACY = "sysknife-maint"


def _profile_names(root: Path) -> set[str]:
    """Every name that identifies a deployed project: profile, repository, account."""
    names: set[str] = set()
    for env in sorted((root / "profiles").glob("*/profile.env")):
        d = env.parent.name
        if d.startswith("_"):
            continue
        names.add(d)
        text = env.read_text()
        slug = re.search(r'^REPO_SLUG="([^"$]+)"', text, re.M)
        if slug and "/" in slug.group(1) and "_" not in slug.group(1):
            names.update(slug.group(1).split("/"))
        acct = re.search(r'^GH_ACCOUNT="([^"$]+)"', text, re.M)
        if acct and "_" not in acct.group(1):
            names.add(acct.group(1))
    # Under four characters a "name" is a letter that every script contains, and
    # scanning for it would fail on `read -r`. A repository called `r` is not
    # something this can see, and says so here rather than failing everywhere.
    names = {n for n in names if len(n) >= 4 and n not in _OWN_NAMES}
    # `lacs-project` is also written `lacs` in paths and prose.
    return names | {n.split("-")[0] for n in names if "-" in n}


def _python_code_lines(src: str) -> list[tuple[int, str]]:
    """The lines of a python file with comments and docstrings blanked."""
    lines = src.splitlines()
    doc_spans = []
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) \
                    and isinstance(body[0].value.value, str):
                doc_spans.append((body[0].lineno, body[0].end_lineno))
    blank = {n for a, b in doc_spans for n in range(a, b + 1)}
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type == tokenize.COMMENT:
            row, col = tok.start
            lines[row - 1] = lines[row - 1][:col]
    return [(i + 1, ln) for i, ln in enumerate(lines) if (i + 1) not in blank and ln.strip()]


def _shell_code_lines(src: str) -> list[tuple[int, str]]:
    return [(i + 1, ln) for i, ln in enumerate(src.splitlines())
            if ln.strip() and not ln.lstrip().startswith("#")]


def check_repo_names(root: Path) -> list[str]:
    names = _profile_names(root)
    if not names:
        return ["no deployed profile found under profiles/, so there is no name to look for"]
    pat = re.compile(r"(?<![A-Za-z0-9])(" + "|".join(sorted(map(re.escape, names), key=len, reverse=True))
                     + r")(?![A-Za-z0-9])", re.I)
    files = [p for p in sorted((root / "bin").glob("*")) if p.is_file()]
    files += [p for p in sorted((root / "lib").rglob("*.sh")) if p.is_file()]
    if not files:
        return ["found no files under bin/ or lib/ to scan"]
    problems = []
    for f in files:
        src = f.read_text(errors="replace")
        first = src.splitlines()[0] if src else ""
        lines = _python_code_lines(src) if "python3" in first else _shell_code_lines(src)
        for n, ln in lines:
            m = pat.search(ln.replace(_LEGACY, ""))
            if m:
                problems.append(f"{f.relative_to(root)}:{n}: executable code names '{m.group(1)}': {ln.strip()[:90]}")
    return problems


def _code_files(root: Path) -> list[Path]:
    """Every file that is code rather than prose: what a message or a path in it can point at."""
    out: list[Path] = []
    for pat in ("bin/*", "lib/*.sh", "lib/backends/*", "scripts/*", "platform/**/*", "install.sh",
                "new-profile.sh", "profiles/*/verify.d/*.sh", "profiles/*/profile.env"):
        out += [p for p in sorted(root.glob(pat)) if p.is_file() and "__pycache__" not in p.parts]
    return out


def _defaults(root: Path) -> dict[str, str]:
    return dict(re.findall(r"^([A-Z][A-Z0-9_]*)=(\S+)$", _read(root, "lib/defaults.env"), re.M))


# --- cli-verbs --------------------------------------------------------------
# A command nobody can find is a command nobody uses, and a doc naming a command
# that no longer exists is the defect in docs/lessons.md 12. Three lists have to
# agree: what the code dispatches, what --help prints, what docs/cli.md says.
_TABLE_SCRIPT = r"""
import importlib.machinery, importlib.util, json, sys
path = sys.argv[1]
sys.argv = ["maintainer", "--help"]
loader = importlib.machinery.SourceFileLoader("maintainer_cli", path)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("maintainer_cli", loader))
loader.exec_module(m)
print(json.dumps({v: c.internal for v, c in m.COMMANDS.items()}))
"""


def _run_py(root: Path, *args: str) -> tuple[int, str, str]:
    import os
    import subprocess
    import tempfile
    with tempfile.TemporaryDirectory() as home:
        env = {k: v for k, v in os.environ.items() if not k.startswith("MAINTAINER_")}
        env["HOME"] = home
        p = subprocess.run([sys.executable, "-B", *args], capture_output=True, text=True, env=env)
    return p.returncode, p.stdout, p.stderr


def _case_verbs(text: str, after: str) -> list[str]:
    """The labels of the dispatcher `case` that follows `after` in a bash script."""
    i = text.find(after)
    return re.findall(r"^    ([a-z][a-z-]*)\)", text[i:], re.M) if i >= 0 else []


def check_cli_verbs(root: Path) -> list[str]:
    import json
    problems: list[str] = []
    rc, out, err = _run_py(root, "-c", _TABLE_SCRIPT, str(root / "bin/maintainer"))
    if rc != 0 or not out.strip():
        return [f"could not read bin/maintainer's COMMANDS table: {err.strip()[:160]}"]
    table: dict[str, bool] = json.loads(out)
    rc, helptext, err = _run_py(root, str(root / "bin/maintainer"), "--help")
    if rc != 0 or err.strip():
        problems.append(f"`maintainer --help` exits {rc} and writes {err.strip()[:80]!r} to stderr")
    for verb in table:
        if not re.search(rf"^\s+maintainer {re.escape(verb)}( |$)", helptext, re.M):
            problems.append(f"`maintainer --help` does not print the verb '{verb}'")
    cli = _read(root, "docs/cli.md")
    run_sh_at = cli.find("## Called by run.sh")
    typed, internal_section = (cli[:run_sh_at], cli[run_sh_at:]) if run_sh_at >= 0 else (cli, "")
    rows = set(re.findall(r"^\| `maintainer ([a-z][a-z-]*)[ `]", typed, re.M))
    for verb, is_internal in table.items():
        if is_internal:
            if f"`{verb}`" not in internal_section:
                problems.append(f"docs/cli.md does not list the internal verb '{verb}' under 'Called by run.sh'")
        elif verb not in rows:
            problems.append(f"docs/cli.md has no command-table row for `maintainer {verb}`")
    for verb in sorted(rows - set(table)):
        problems.append(f"docs/cli.md documents `maintainer {verb}`, which is not a verb")
    for tool, after in (("maintainer-merge", "_executed || return 0"), ("maintainer-repo", 'case "${1:-}" in')):
        verbs = _case_verbs(_read(root, f"bin/{tool}"), after)
        doc_rows = set(re.findall(rf"^\| `{tool} ([a-z][a-z-]*)[ `]", cli, re.M))
        if not verbs:
            problems.append(f"found no dispatcher verbs in bin/{tool}")
        for verb in verbs:
            if verb not in doc_rows:
                problems.append(f"docs/cli.md has no row for `{tool} {verb}`")
        for verb in sorted(doc_rows - set(verbs)):
            problems.append(f"docs/cli.md documents `{tool} {verb}`, which the dispatcher does not take")
    return problems


# --- config-docs ------------------------------------------------------------
_ENV_HEADING = "## Environment variables that are not defaults"


def check_config_docs(root: Path) -> list[str]:
    keys = _defaults(root)
    if not keys:
        return ["lib/defaults.env has no keys, or could not be read"]
    doc = _read(root, "docs/configuration.md")
    table = doc.split(_ENV_HEADING)[0]
    rows = dict(re.findall(r"^\| `([A-Z][A-Z0-9_]*)` \| ([^|]+?) \|", table, re.M))
    problems = []
    for k, v in keys.items():
        if k not in rows:
            problems.append(f"docs/configuration.md has no row for {k} (default {v})")
        elif rows[k] != v:
            problems.append(f"docs/configuration.md says {k} defaults to {rows[k]}, lib/defaults.env says {v}")
    for k in sorted(set(rows) - set(keys)):
        problems.append(f"docs/configuration.md documents {k}, which lib/defaults.env does not have")
    return problems


# --- env-vars ---------------------------------------------------------------
_ENV_NAME = re.compile(r"(?<![A-Za-z0-9_])(MAINTAINER_[A-Z][A-Z0-9_]*[A-Z0-9])(?![A-Za-z0-9_])")


def check_env_vars(root: Path) -> list[str]:
    keys = set(_defaults(root))
    doc = _read(root, "docs/configuration.md")
    documented = set(_ENV_NAME.findall(doc))
    problems, seen = [], {}
    for f in _code_files(root):
        for name in _ENV_NAME.findall(f.read_text(errors="replace")):
            seen.setdefault(name, f)
    if not seen:
        return ["found no MAINTAINER_ variable in the code, so there is nothing to compare"]
    for name, f in sorted(seen.items()):
        if name in documented or name[len("MAINTAINER_"):] in keys:
            continue
        problems.append(f"{name} is read in {f.relative_to(root)} and docs/configuration.md does not list it")
    return problems


# --- doc-paths --------------------------------------------------------------
def check_doc_paths(root: Path) -> list[str]:
    problems = []
    for f in _code_files(root):
        for path in sorted(set(re.findall(r"(?<![A-Za-z0-9_/.-])(docs/[A-Za-z0-9_./-]*[A-Za-z0-9_]\.md)", f.read_text(errors="replace")))):
            if not (root / path).is_file():
                problems.append(f"{f.relative_to(root)} names {path}, which does not exist")
    return problems


# --- readme-counts ----------------------------------------------------------
def check_readme_counts(root: Path) -> list[str]:
    """The backend and lesson figures: each stated through a marker that
    scripts/render_figures.py renders, and never typed. The counting lives in
    that module so this checker and check_claims.sh cannot count differently."""
    problems: list[str] = []
    try:
        actual = render_figures.backends(root, None)
    except render_figures.SourceError as e:
        return [f"backends: {e}"]
    # The table has one column per backend as well as the sentence stating how many.
    hdr = re.search(r"^## Backends\n.*?^\| \| (.+?) \|\n", _read(root, "README.md"), re.S | re.M)
    if hdr and len([c for c in hdr.group(1).split("|") if c.strip()]) != actual:
        problems.append(f"README's backends table has {len(hdr.group(1).split('|'))} columns, lib/backends has {actual}")
    problems += render_figures.check(root, None, names={"backends", "lessons"})
    return problems


# --- readme-profiles --------------------------------------------------------
def check_readme_profiles(root: Path) -> list[str]:
    readme = _read(root, "README.md")
    rows = dict(re.findall(r"^\| `([a-z][a-z0-9._-]*)` \|[^|]*\| (on|off) \|", readme, re.M))
    problems = []
    declared = {}
    for env in sorted((root / "profiles").glob("*/profile.env")):
        name = env.parent.name
        if name.startswith("_"):
            continue
        m = re.search(r'^POST="(?:\$\{MAINTAINER_POST:-)?(on|off)\}?"', env.read_text(), re.M)
        if not m:
            problems.append(f"profiles/{name}/profile.env declares no readable POST default")
            continue
        declared[name] = m.group(1)
    for name, post in declared.items():
        if name not in rows:
            problems.append(f"README's profile table has no Posts cell for {name}")
        elif rows[name] != post:
            problems.append(f"README says {name} posts '{rows[name]}', profiles/{name}/profile.env says '{post}'")
    for name in sorted(set(rows) - set(declared)):
        problems.append(f"README's profile table names {name}, which is not a profile")
    return problems


# --- changelog-links --------------------------------------------------------
def check_changelog_links(root: Path) -> list[str]:
    text = _read(root, "CHANGELOG.md")
    heads = re.findall(r"^## \[([^\]]+)\]", text, re.M)
    links = dict(re.findall(r"^\[([^\]]+)\]: (\S+)$", text, re.M))
    problems = []
    versions = [h for h in heads if h != "Unreleased"]
    if not versions:
        return ["CHANGELOG.md has no version headings"]
    for h in heads:
        if h not in links:
            problems.append(f"CHANGELOG.md has a '## [{h}]' heading and no [{h}]: link at the foot")
    for v in versions:
        if v in links and not links[v].endswith(f"/v{v}"):
            problems.append(f"CHANGELOG.md's [{v}] link does not end in /v{v}: {links[v]}")
    if "Unreleased" in links and not links["Unreleased"].endswith(f"/compare/v{versions[0]}...HEAD"):
        problems.append(f"CHANGELOG.md's [Unreleased] link should compare v{versions[0]}...HEAD: {links['Unreleased']}")
    return problems


CHECKS = {
    "repo-names": check_repo_names,
    "cli-verbs": check_cli_verbs,
    "config-docs": check_config_docs,
    "env-vars": check_env_vars,
    "doc-paths": check_doc_paths,
    "readme-counts": check_readme_counts,
    "readme-profiles": check_readme_profiles,
    "changelog-links": check_changelog_links,
}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--only", action="append", choices=sorted(CHECKS))
    args = ap.parse_args(argv)
    root = Path(args.root)
    failed = 0
    for name in args.only or sorted(CHECKS):
        problems = CHECKS[name](root)
        for p in problems:
            print(f"FAIL [{name}] {p}", file=sys.stderr)
        failed += bool(problems)
        if not problems:
            print(f"  ok: {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
