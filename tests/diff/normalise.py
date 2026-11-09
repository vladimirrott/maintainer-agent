#!/usr/bin/env python3
"""Normalise one recorded scenario so two runs of the same tree compare equal.

Subcommands:
  rules                          print every rule as `name<TAB>reason`
  selftest                       run every rule's own examples, print the count
  filter  --work W --tree T...   stdin to stdout with the rules applied
  finalise --work W --tree T... --out DIR
                                 turn a scenario's raw files into a result directory

A rule exists only if it names the thing that varies between two runs and says
why, and carries examples that must change plus text that must stay unchanged.
The selftest refuses a rule without both. Paths are not rules of this kind:
the tree under test and the scratch directory are replaced by literal match.
"""
import argparse
import hashlib
import os
import re
import stat
import subprocess
import sys

TREE_TOKEN = "<TREE>"
WORK_TOKEN = "<W>"
# Per-file ceiling for keeping a readable copy beside the hash.
KEEP_BYTES = 256 * 1024
# Top-level entries of the scratch directory that are harness machinery, not state.
HARNESS_DIRS = ("stubs", "realbin", "raw")


class Rule:
    """One substitution: a name, why it is needed, a regex, and its own tests."""

    def __init__(self, name, reason, pattern, repl, changes, keeps, flags=0):
        if not reason or "\n" in reason:
            raise ValueError("rule %s needs a one-line reason" % name)
        if not changes or not keeps:
            raise ValueError("rule %s needs examples that change and text that stays" % name)
        self.name, self.reason, self.repl = name, reason, repl
        self.regex = re.compile(pattern, flags)
        self.changes, self.keeps = changes, keeps

    def apply(self, text):
        return self.regex.sub(self.repl, text)


RULES = [
    Rule("iso-timestamp",
         "date -Is, isoformat() and gh timestamps carry the wall clock of the run; only the digits vary, so the separator, the fraction and the zone suffix stay",
         r"\d{4}-\d{2}-\d{2}(?P<sep>[T ])\d{2}:\d{2}:\d{2}(?P<frac>\.\d+)?(?P<zone>Z|[+-]\d{2}:?\d{2})?",
         lambda m: "NNNN-NN-NN%sNN:NN:NN%s%s" % (m.group("sep"), "<FRAC>" if m.group("frac") else "", m.group("zone") or ""),
         [("started 2026-11-09T12:34:56+00:00 ok", "started NNNN-NN-NNTNN:NN:NN+00:00 ok"),
          ("at 2026-11-09 12:34:56.123456Z.", "at NNNN-NN-NN NN:NN:NN<FRAC>Z."),
          ('"recorded_at": "2026-01-01T00:00:00+01:00"', '"recorded_at": "NNNN-NN-NNTNN:NN:NN+01:00"'),
          ("2026-11-09T12:34:56Z", "NNNN-NN-NNTNN:NN:NN" + "Z"),
          ("2026-11-09T12:34:56", "NNNN-NN-NNTNN:NN:NN")],
         ["released 2026-11-09", "version 1.2.3", "ratio 12:34"]),
    Rule("stamp-filename",
         "run ids and log names embed the minute the run started",
         r"\d{4}-\d{2}-\d{2}T\d{2}-\d{2}(?:-\d{2})?",
         "<TS>",
         [("logs/2026-11-09T12-34-review.log", "logs/<TS>-review.log"),
          ("2026-11-09T12-34-56-issues", "<TS>-issues")],
         ["2026-11-09-review", "T12-34 alone"]),
    Rule("epoch-field",
         "lease and run files store the start time as seconds since the epoch",
         r'("(?:renewed|started|acquired|expires|created|updated)[A-Za-z_]*"\s*:\s*)\d{9,}',
         r"\1<EPOCH>",
         [('{"started": 1762690000, "task": "x"}', '{"started": <EPOCH>, "task": "x"}'),
          ('"renewed":1762690000,', '"renewed":<EPOCH>,')],
         ['"ttl_seconds": 3600', '"started": "later"', '"pr": 1762690000']),
    Rule("pid",
         "a process id differs on every run and appears in lease and lock records",
         r'("pid"\s*:\s*|\bpid[ =:]+)\d+',
         r"\1<PID>",
         [('{"pid": 48213, "task": "x"}', '{"pid": <PID>, "task": "x"}'),
          ("held by pid 4821", "held by pid <PID>"),
          ("pid=77", "pid=<PID>")],
         ["rapid 12", "pid unknown", "pr 4821"]),
    Rule("mktemp-file",
         "mktemp names a file tmp. plus ten random characters",
         r"\btmp\.[A-Za-z0-9]{10}\b",
         "tmp.<RAND>",
         [("<W>/tmp/tmp.aB3dE5gH7j", "<W>/tmp/tmp.<RAND>")],
         ["tmp.short", "tmp.12345678901234"]),
    Rule("mktemp-dir",
         "verify scratch directories get eight random characters from mktemp -d",
         r"(verify-work/)[A-Za-z0-9]{8}\b",
         r"\1<RAND>",
         [("<W>/state/verify-work/Xy12AbCd/tree", "<W>/state/verify-work/<RAND>/tree")],
         ["verify-work/short", "verify-work/"]),
    Rule("key-file",
         "install.sh mints a random 64 hex receipt key; a file holding only that is a key",
         r"\A[0-9a-f]{64}\n?\Z",
         "<KEY>",
         [("0123456789abcdef" * 4 + "\n", "<KEY>")],
         ['{"signature": "' + "ab" * 32 + '"}', "ab" * 32 + " and more\n", "ab" * 31]),
]


class Normaliser:
    def __init__(self, trees, work):
        # Longest first so a path never loses a prefix to a shorter one.
        self.paths = [(p.rstrip("/"), TREE_TOKEN) for p in sorted(set(trees), key=len, reverse=True)]
        self.paths.append((work.rstrip("/"), WORK_TOKEN))

    def text(self, s):
        for path, token in self.paths:
            # No match inside a longer name: /t/tree must leave /t/tree-copy alone.
            s = re.sub(re.escape(path) + r"(?![A-Za-z0-9_-])", token, s)
        for rule in RULES:
            s = rule.apply(s)
        return s


def selftest():
    n = 0
    names = [r.name for r in RULES]
    if len(set(names)) != len(names):
        raise SystemExit("selftest: duplicate rule names")
    for rule in RULES:
        for given, want in rule.changes:
            got = rule.apply(given)
            if got != want:
                raise SystemExit("selftest: rule %s changed %r into %r, wanted %r" % (rule.name, given, got, want))
            n += 1
        for given in rule.keeps:
            got = rule.apply(given)
            if got != given:
                raise SystemExit("selftest: rule %s rewrote %r into %r" % (rule.name, given, got))
            n += 1
    norm = Normaliser(["/t/old", "/real/old"], "/w/x1")
    path_cases = [
        ("/t/old/bin/maintainer-merge", "<TREE>/bin/maintainer-merge"),
        ("/real/old/lib", "<TREE>/lib"),
        ("/w/x1/home/.local", "<W>/home/.local"),
        ("/t/old-copy/bin", "/t/old-copy/bin"),
        ("/w/x10/home", "/w/x10/home"),
        ("see /t/old.", "see <TREE>."),
    ]
    for given, want in path_cases:
        got = norm.text(given)
        if got != want:
            raise SystemExit("selftest: path map turned %r into %r, wanted %r" % (given, got, want))
        n += 1
    print("normalise selftest: %d rules, %d checks passed" % (len(RULES), n))


def clean_git_env():
    env = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C", "TZ": "UTC",
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
           "HOME": "/nonexistent"}
    return env


def git_lines(args):
    """Run git, never raising: a failure becomes a visible line in the summary."""
    p = subprocess.run(["git"] + args, env=clean_git_env(), stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = p.stdout.decode("utf-8", "replace")
    if p.returncode != 0:
        out += "!! git %s exited %d: %s\n" % (" ".join(args[-2:]), p.returncode,
                                              p.stderr.decode("utf-8", "replace").strip())
    return out


def git_summary(path, bare):
    base = ["--git-dir=" + path] if bare else ["-C", path]
    parts = ["HEAD " + (git_lines(base + ["symbolic-ref", "-q", "HEAD"]).strip() or "detached"),
             "-- refs", git_lines(base + ["for-each-ref", "--format=%(refname) %(objectname)"]),
             "-- config", git_lines(base + ["config", "--local", "--list"])]
    if not bare:
        parts += ["-- status", git_lines(base + ["status", "--porcelain=v1"])]
    return "\n".join(p.rstrip("\n") for p in parts) + "\n"


def looks_bare(path):
    return all(os.path.exists(os.path.join(path, n)) for n in ("HEAD", "objects", "refs")) \
        and not os.path.exists(os.path.join(path, ".git"))


def entries(work, norm):
    """Yield (path, kind, mode, digest, kept_text_or_None) for every state entry."""
    for top in sorted(os.listdir(work)):
        if top in HARNESS_DIRS:
            continue
        yield from walk(work, os.path.join(work, top), norm)


def walk(work, path, norm):
    rel = os.path.relpath(path, work)
    st = os.lstat(path)
    mode = "%o" % (st.st_mode & 0o7777)
    if os.path.islink(path):
        yield rel, "l", mode, sha(norm.text(os.readlink(path)).encode()), norm.text(os.readlink(path)) + "\n"
        return
    if os.path.isdir(path):
        yield rel, "d", mode, "-", None
        if looks_bare(path):
            text = norm.text(git_summary(path, True))
            yield rel + "/@git-summary", "g", "-", sha(text.encode()), text
            return
        for name in sorted(os.listdir(path)):
            child = os.path.join(path, name)
            if name == ".git":
                text = norm.text(git_summary(path, False))
                yield rel + "/@git-summary", "g", "-", sha(text.encode()), text
                continue
            yield from walk(work, child, norm)
        return
    if not stat.S_ISREG(st.st_mode):
        # A fifo or socket would block a read; record that it exists and what mode it has.
        yield rel, "o", mode, "-", None
        return
    data = open(path, "rb").read()
    try:
        if b"\0" in data:
            raise UnicodeDecodeError("utf-8", b"", 0, 1, "binary")
        text = norm.text(data.decode("utf-8"))
    except UnicodeDecodeError:
        yield rel, "b", mode, sha(data), None
        return
    yield rel, "f", mode, sha(text.encode()), text if len(data) <= KEEP_BYTES else None


def sha(b):
    return hashlib.sha256(b).hexdigest()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def finalise(work, trees, out):
    norm = Normaliser(trees, work)
    raw = os.path.join(work, "raw")
    os.makedirs(out)
    for name in sorted(os.listdir(raw)):
        if name == "setup.log":
            continue
        src = os.path.join(raw, name)
        if name == "rc":
            body = open(src, encoding="utf-8").read()
        else:
            body = norm.text(open(src, "rb").read().decode("utf-8", "replace"))
        write(os.path.join(out, name), body)
    # Every stub gets all three of its logs, empty when it was never called, so a
    # call that disappears reads as a changed file and not as a missing one.
    for stub in sorted(os.listdir(os.path.join(work, "stubs"))):
        for kind in ("argv", "env", "stdin"):
            log = os.path.join(out, "%s.%s.log" % (kind, stub))
            if not os.path.exists(log):
                open(log, "w").close()
    calls = os.path.join(out, "calls.log")
    if not os.path.exists(calls):
        open(calls, "w").close()
    rows, used = [], {}
    for rel, kind, mode, digest, text in entries(work, norm):
        rows.append((norm.text(rel), kind, mode, digest, text))
    rows.sort(key=lambda r: (r[0], r[1], r[3]))
    keep_root = os.path.join(out, "state.files")
    lines = []
    for rel, kind, mode, digest, text in rows:
        lines.append("%s\t%s\t%s\t%s" % (rel, kind, mode, digest))
        if text is not None and kind != "d":
            n = used.get(rel, 0)
            used[rel] = n + 1
            dest = os.path.join(keep_root, rel if n == 0 else "%s~%d" % (rel, n + 1))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            write(dest, text)
    write(os.path.join(out, "state.tree"), "\n".join(lines) + ("\n" if lines else ""))
    if not os.path.isdir(keep_root):
        os.makedirs(keep_root)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("rules")
    sub.add_parser("selftest")
    f = sub.add_parser("filter")
    f.add_argument("--work", required=True)
    f.add_argument("--tree", action="append", default=[])
    z = sub.add_parser("finalise")
    z.add_argument("--work", required=True)
    z.add_argument("--tree", action="append", default=[])
    z.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "rules":
        for r in RULES:
            print("%s\t%s" % (r.name, r.reason))
        print("tree-path\tthe tree under test sits at a different path for --old and --new")
        print("work-path\tthe scratch directory is a fresh mktemp name on every run")
    elif a.cmd == "selftest":
        selftest()
    elif a.cmd == "filter":
        sys.stdout.write(Normaliser(a.tree, a.work).text(sys.stdin.read()))
    else:
        finalise(a.work, a.tree, a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
