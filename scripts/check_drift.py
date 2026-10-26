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


CHECKS = {
    "repo-names": check_repo_names,
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
