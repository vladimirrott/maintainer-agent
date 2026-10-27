#!/usr/bin/env python3
"""Render every project figure in the prose from its source. Never type one.

    render_figures.py [--root DIR] --check (--tests N | --no-tests)   verify, change nothing
    render_figures.py [--root DIR] --write [--tests N | --no-tests]   rewrite the stale ones
    render_figures.py [--root DIR] --values [--tests N]               print name and value

A figure in README.md, CONTRIBUTING.md or docs/ is a marker around its value:

    <!-- fig:NAME -->VALUE<!-- /fig -->              exact, for a figure only a deliberate act moves
    <!-- fig:NAME floor=K -->VALUE<!-- /fig -->      a rounded floor: floor(v/K)*K and a trailing +

Each NAME is counted by one function in FIGURES, and scripts/check_claims.sh and
scripts/check_drift.py call these same functions. The floor a name takes is part
of the registry (FLOORS), so a marker cannot quietly turn a test count into an
exact figure that goes stale on every pull request.

--check exits 1 with one `FAIL file:line: reason` per problem: a stale marker, an
unknown name, a malformed or nested marker, a marker inside a code fence, a
figure typed outside a marker, a required site that stopped stating its figure,
no markers at all, and a source that could not be read. It never skips: a
figure whose source cannot be read is a failure, because an empty answer from
something that was not read is not a pass.

--check takes the test count from the caller (--tests N, the number check_claims.sh
measured after running the suite) rather than running the suite a second time.
--no-tests is for the suite itself, which cannot know its own count yet: the tests
marker is then checked for structure, name and floor but not for its value.
--write without --tests runs the suite itself. --write is idempotent, and it
writes nothing at all while any problem other than a stale value stands.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


class SourceError(Exception):
    """A figure's source could not be read, or read as nothing."""


# --- sources ----------------------------------------------------------------
# One function per figure. Every one fails closed: a missing directory, an
# unparseable file and a count of zero are all SourceError, never a number.

def _count_files(root: Path, rel: str, pattern: str) -> int:
    d = root / rel
    if not d.is_dir():
        raise SourceError(f"{rel} is not a directory")
    n = len(list(d.glob(pattern)))
    if n == 0:
        raise SourceError(f"{rel} holds no {pattern} file")
    return n


def backends(root: Path, tests: int | None) -> int:
    return _count_files(root, "lib/backends", "*.sh")


def evals(root: Path, tests: int | None) -> int:
    return _count_files(root, "evals/scenarios", "*.md")


def denied_verbs(root: Path, tests: int | None) -> int:
    """The VERB count, not the rule count: the generator spells each verb from
    wherever the binary lives, so the rule count differs between machines."""
    rel = "profiles/sysknife/deny.json"
    try:
        d = json.loads((root / rel).read_text())
        n = len(d.get("spelled_everywhere", [])) + len(d.get("bare_exact", []))
    except (OSError, ValueError, AttributeError, TypeError) as e:
        raise SourceError(f"{rel} could not be read: {e}") from e
    if n == 0:
        raise SourceError(f"{rel} lists no verbs")
    return n


def lessons(root: Path, tests: int | None) -> int:
    try:
        text = (root / "docs/lessons.md").read_text()
    except OSError as e:
        raise SourceError(f"docs/lessons.md could not be read: {e}") from e
    nums = [int(n) for n in re.findall(r"^## (\d+)\.", text, re.M)]
    if not nums:
        raise SourceError("docs/lessons.md has no numbered entries, so no count can be checked")
    if nums != list(range(1, len(nums) + 1)):
        raise SourceError("docs/lessons.md numbers its entries out of order or with a gap")
    return len(nums)


def _stories(root: Path) -> tuple[int, list[int]]:
    """(story count, the numbers of the stories marked [GAP])."""
    try:
        t = (root / "docs/user-stories.md").read_text()
    except OSError as e:
        raise SourceError(f"docs/user-stories.md could not be read: {e}") from e
    parts = re.split(r"^\*\*(\d+)\.", t, flags=re.M)
    total = len(parts) // 2
    if total == 0:
        raise SourceError("docs/user-stories.md has no numbered stories")
    return total, [int(parts[i]) for i in range(1, len(parts), 2) if "[GAP]" in parts[i + 1]]


def stories(root: Path, tests: int | None) -> int:
    return _stories(root)[0]


def gaps(root: Path, tests: int | None) -> int:
    return len(_stories(root)[1])


def profiles(root: Path, tests: int | None) -> int:
    d = root / "profiles"
    if not d.is_dir():
        raise SourceError("profiles is not a directory")
    n = len([p for p in d.glob("*/profile.env") if not p.parent.name.startswith("_")])
    if n == 0:
        raise SourceError("profiles/ holds no profile")
    return n


def tests_count(root: Path, tests: int | None) -> int:
    if tests is None:
        raise SourceError("no test count was given")
    if tests <= 0:
        raise SourceError(f"the measured test count is {tests}, which is not a suite")
    return tests


# name -> counting function. Zero is refused for every one of them except gaps,
# which may one day honestly be zero.
FIGURES = {
    "tests": tests_count,
    "evals": evals,
    "backends": backends,
    "denied_verbs": denied_verbs,
    "lessons": lessons,
    "stories": stories,
    "gaps": gaps,
    "profiles": profiles,
}
# Figures that routine pull requests move are shown as a floor; the rest change
# only by a deliberate act and stay exact.
FLOORS = {"tests": 100, "lessons": 10}
ALLOW_ZERO = {"gaps"}

# Where each figure must be stated. A site that stops stating its figure is a
# failure, so the check cannot drift into inspecting nothing.
REQUIRED = {
    "README.md": ["tests", "evals", "denied_verbs", "backends", "lessons", "profiles"],
    "CONTRIBUTING.md": ["lessons"],
    "docs/SUMMARY.md": ["lessons"],
    "docs/user-stories.md": ["stories", "gaps"],
}


def render(value: int, floor: int | None) -> str:
    """The text a marker holds: thousands separators, and for a floor
    floor(v/K)*K with a trailing +."""
    if floor is None:
        return f"{value:,}"
    return f"{(value // floor) * floor:,}+"


# --- the prose ---------------------------------------------------------------
_OPEN = re.compile(r"<!-- fig:([A-Za-z0-9_]+)(?: floor=([0-9]+))? -->")
_CLOSE = "<!-- /fig -->"
_LOOSE = re.compile(r"<!--\s*/?\s*fig\b")
_CODE_SPAN = re.compile(r"(`+)(.+?)\1")
_FENCE = re.compile(r"^\s*(```|~~~)")

_ONES = ("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
         "fifteen sixteen seventeen eighteen nineteen").split()
_TENS = "twenty thirty forty fifty sixty seventy eighty ninety".split()
_WORD = "(?:" + "|".join(_TENS) + r")(?:-(?:" + "|".join(_ONES[1:10]) + "))?|" + "|".join(reversed(_ONES))
_NUM = rf"(?<![\w.,-])(?:\d[\d,]*\+?|{_WORD})"

# A figure typed where a marker belongs. Each pattern is what a person writes
# when they state that figure in prose, and the number may be digits or a word.
# The patterns are phrased as the statement of a whole figure, not as any
# mention of a noun: "a claim of 42 tests" in the roadmap is an example, and
# "two lessons" there counts two particular entries. A third element, when
# present, is the only file the pattern applies to: the README is the one place
# the suite size, the eval count and the denied-verb count are stated.
BARE = [
    ("tests", re.compile(rf"{_NUM}\s+(?:offline\s+)?tests\b", re.I), "README.md"),
    ("evals", re.compile(rf"{_NUM}\s+(?:adversarial\s+)?eval\b", re.I), "README.md"),
    ("denied_verbs", re.compile(rf"{_NUM}\s+denied\s+verbs", re.I), "README.md"),
    ("lessons", re.compile(rf"(?:\b(?:has|is|have|holds)\s+(?:the\s+)?|\[){_NUM}\s+(?:lessons|entries)\b"
                           rf"|{_NUM}\s+(?:lessons|entries),?\s+(?:each|that)\b", re.I), None),
    ("backends", re.compile(rf"{_NUM}\s+backends\b|^{_NUM},\s+and they are", re.I), None),
    ("profiles", re.compile(rf"{_NUM}\s+profiles\b", re.I), None),
    ("gaps", re.compile(rf"\*\*{_NUM}\s+of\s+{_NUM}\s+have no governing rule", re.I), None),
]

# Prose that records history or quotes it is not a statement of the present.
_SKIP = {"docs/lessons.md"}


def prose_files(root: Path) -> list[str]:
    out = ["README.md", "CONTRIBUTING.md"]
    out += sorted(p.relative_to(root).as_posix() for p in (root / "docs").rglob("*.md"))
    return [f for f in out if f not in _SKIP]


class Marker:
    def __init__(self, file: str, line: int, start: int, end: int, name: str, floor: int | None, value: str):
        self.file, self.line, self.start, self.end = file, line, start, end
        self.name, self.floor, self.value = name, floor, value


def scan(rel: str, text: str) -> tuple[list[Marker], list[str], dict[int, str]]:
    """(well-formed markers, structural problems, each line with its markers blanked).

    A marker inside a code fence is refused: it would render as the raw tag and
    nothing would ever check it as a figure. A marker inside an inline code span
    is documentation of the syntax, not a figure, and is left alone."""
    markers: list[Marker] = []
    problems: list[str] = []
    blanked: dict[int, str] = {}
    fence = None
    for n, raw in enumerate(text.split("\n"), 1):
        m = _FENCE.match(raw)
        if m:
            fence = None if fence == m.group(1) else (fence or m.group(1))
            blanked[n] = raw
            continue
        if fence:
            if _LOOSE.search(raw):
                problems.append(f"{rel}:{n}: marker inside a code fence, where it would render as the raw tag")
            blanked[n] = raw
            continue
        line = _CODE_SPAN.sub(lambda s: " " * len(s.group(0)) if "fig" in s.group(2) else s.group(0), raw)
        out = list(raw)
        pos = 0
        while True:
            hit = _LOOSE.search(line, pos)
            if not hit:
                break
            o = _OPEN.match(line, hit.start())
            if o is None:
                problems.append(f"{rel}:{n}: malformed marker near {line[hit.start():hit.start() + 40]!r}; "
                                "expected <!-- fig:NAME --> or <!-- fig:NAME floor=K --> then the value then <!-- /fig -->")
                pos = hit.end()
                continue
            close = line.find(_CLOSE, o.end())
            if close < 0:
                problems.append(f"{rel}:{n}: malformed marker '{o.group(1)}': no <!-- /fig --> on the same line")
                pos = o.end()
                continue
            value = line[o.end():close]
            if "<!--" in value:
                problems.append(f"{rel}:{n}: nested or malformed marker '{o.group(1)}': another tag opens before it closes")
                pos = o.end()
                continue
            markers.append(Marker(rel, n, o.end(), close, o.group(1),
                                  int(o.group(2)) if o.group(2) else None, value))
            for i in range(o.start(), close + len(_CLOSE)):
                out[i] = " "
            pos = close + len(_CLOSE)
        blanked[n] = "".join(out)
    return markers, problems, blanked


# --- the check ---------------------------------------------------------------
class Result:
    def __init__(self) -> None:
        self.problems: list[str] = []   # structural and semantic: block --write
        self.stale: list[tuple[Marker, str]] = []
        self.markers = 0
        self.files = 0


def evaluate(root: Path, tests: int | None, check_tests_value: bool = True,
             names: set[str] | None = None) -> Result:
    """Everything wrong with the figures in the prose. `names` narrows the figure
    checks to those names (check_drift's readme-counts); structural problems and
    the zero-markers refusal are only raised for the whole set."""
    res = Result()
    values: dict[str, int | None] = {}
    failed: set[str] = set()

    def value(name: str) -> int | None:
        if name not in values:
            try:
                if name == "tests" and not check_tests_value:
                    raise SourceError("skipped")
                v = FIGURES[name](root, tests)
                if v == 0 and name not in ALLOW_ZERO:
                    raise SourceError("it counts zero")
                values[name] = v
            except SourceError as e:
                values[name] = None
                if not (name == "tests" and not check_tests_value):
                    failed.add(name)
                    res.problems.append(f"figure '{name}': cannot read its source: {e}")
        return values[name]

    found: dict[str, set[str]] = {}
    for rel in prose_files(root):
        try:
            text = (root / rel).read_text()
        except OSError as e:
            res.problems.append(f"{rel}: cannot read the file: {e}")
            continue
        res.files += 1
        markers, structural, blanked = scan(rel, text)
        if names is None:
            res.problems += structural
        res.markers += len(markers)
        for mk in markers:
            found.setdefault(rel, set()).add(mk.name)
            if mk.name not in FIGURES:
                if names is None:
                    res.problems.append(f"{rel}:{mk.line}: unknown figure '{mk.name}'")
                continue
            if names is not None and mk.name not in names:
                continue
            if mk.floor != FLOORS.get(mk.name):
                want = f"floor={FLOORS[mk.name]}" if mk.name in FLOORS else "no floor"
                res.problems.append(f"{rel}:{mk.line}: figure '{mk.name}' takes {want}")
                continue
            v = value(mk.name)
            if v is None:
                continue
            if mk.floor is not None and v < mk.floor:
                res.problems.append(f"{rel}:{mk.line}: figure '{mk.name}' is {v}, below its floor {mk.floor}")
                continue
            want_text = render(v, mk.floor)
            if mk.value != want_text:
                res.problems.append(f"{rel}:{mk.line}: stale marker '{mk.name}': says {mk.value!r}, "
                                    f"the source renders {want_text!r}")
                res.stale.append((mk, want_text))
        for n, line in blanked.items():
            for name, pat, only in BARE:
                if (names is not None and name not in names) or only not in (None, rel):
                    continue
                for hit in pat.finditer(line):
                    res.problems.append(f"{rel}:{n}: figure '{name}' typed as {hit.group(0).strip()!r} "
                                        f"and not in a marker; write <!-- fig:{name} -->…<!-- /fig -->")
    if names is None and res.markers == 0:
        res.problems.append("no figure markers found in any file, so nothing here is derived")
    for rel, need in REQUIRED.items():
        for name in need:
            if names is not None and name not in names:
                continue
            if rel in found or (root / rel).is_file():
                value(name)   # an unreadable source is reported even when no marker asks for it
                if name not in found.get(rel, set()):
                    res.problems.append(f"{rel}: figure '{name}' is required here and no marker states it")
    if names is None or {"gaps", "stories"} & names:
        res.problems += _gap_list(root)
    return res


def _gap_list(root: Path) -> list[str]:
    """The finding lists the story numbers behind its gap count. Both sides are
    read from the same file, so the prose has to agree with the markers under it."""
    rel = "docs/user-stories.md"
    try:
        t = (root / rel).read_text()
        _, marked = _stories(root)
    except (OSError, SourceError):
        return []   # evaluate() has already reported the unreadable source
    t = re.sub(r"<!-- fig:[A-Za-z0-9_]+(?: floor=[0-9]+)? -->([^<]*)<!-- /fig -->", r"\1", t)
    # The list wraps across lines, so the class admits a newline.
    m = re.search(r"\*\*(\w+) of (\w+) have no governing rule\*\*:([0-9,\s]+)\.", t)
    if not m:
        return [f"{rel}: no longer states its finding in the form the check reads (N of M have no governing rule: list)"]
    listed = [int(x) for x in re.split(r"[,\s]+", m.group(3).strip()) if x]
    if listed != sorted(marked):
        return [f"{rel}: the finding's listed numbers {listed} are not the marked ones {sorted(marked)}"]
    return []


def check(root: Path, tests: int | None, names: set[str] | None = None, check_tests_value: bool = True) -> list[str]:
    """Problem lines for check_drift.py and the CLI; empty means every figure is current."""
    return evaluate(root, tests, check_tests_value, names).problems


def apply(root: Path, res: Result) -> int:
    """Rewrite the stale markers. Returns how many. Right to left, so an
    earlier edit never moves a later one."""
    by_file: dict[str, list[tuple[Marker, str]]] = {}
    for mk, want in res.stale:
        by_file.setdefault(mk.file, []).append((mk, want))
    for rel, edits in by_file.items():
        lines = (root / rel).read_text().split("\n")
        for mk, want in sorted(edits, key=lambda e: (e[0].line, e[0].start), reverse=True):
            ln = lines[mk.line - 1]
            lines[mk.line - 1] = ln[:mk.start] + want + ln[mk.end:]
        (root / rel).write_text("\n".join(lines))
    return len(res.stale)


def measure_tests(root: Path) -> int:
    """Run the tree's own suite and count passed plus skipped. A skipped case is
    still a case in the suite. The suite's STATUS is read before its output."""
    runner = root / "tests/run-tests.sh"
    if not runner.is_file():
        raise SourceError("tests/run-tests.sh is missing, so the suite cannot be measured")
    p = subprocess.run(["bash", str(runner)], capture_output=True, text=True)
    if p.returncode != 0:
        raise SourceError(f"the test suite is RED (exit {p.returncode}); fix that before believing any number")
    passed = re.findall(r"^ *([0-9]+) passed", p.stdout, re.M)
    skipped = re.findall(r", ([0-9]+) skipped", p.stdout)
    if not passed:
        raise SourceError("could not read the suite's summary line, so the count is unknown")
    return int(passed[-1]) + (int(skipped[-1]) if skipped else 0)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify every figure (the default)")
    mode.add_argument("--write", action="store_true", help="rewrite the stale markers")
    mode.add_argument("--values", action="store_true", help="print each figure's value")
    ap.add_argument("--tests", type=int, help="the test count the caller measured")
    ap.add_argument("--no-tests", action="store_true", help="check the tests marker's structure, not its value")
    args = ap.parse_args(argv)
    root = Path(args.root)
    tests = args.tests

    if args.values:
        for name, fn in FIGURES.items():
            if name == "tests" and tests is None:
                continue
            try:
                print(f"{name} {fn(root, tests)}")
            except SourceError as e:
                print(f"FAIL figure '{name}': cannot read its source: {e}", file=sys.stderr)
                return 1
        return 0

    if args.write:
        if tests is None and not args.no_tests:
            try:
                tests = measure_tests(root)
            except SourceError as e:
                print(f"FAIL figure 'tests': cannot read its source: {e}", file=sys.stderr)
                return 1
    elif tests is None and not args.no_tests:
        print("render_figures.py --check needs --tests N (the count the caller measured) or --no-tests",
              file=sys.stderr)
        return 2

    res = evaluate(root, tests, check_tests_value=not args.no_tests)
    stale_lines = {f"{m.file}:{m.line}:" for m, _ in res.stale}
    blocking = [p for p in res.problems if not any(p.startswith(s) and "stale marker" in p for s in stale_lines)]
    if args.write:
        if blocking:
            for p in res.problems:
                print(f"FAIL {p}", file=sys.stderr)
            print("nothing written: fix the problems above first", file=sys.stderr)
            return 1
        n = apply(root, res)
        again = evaluate(root, tests, check_tests_value=not args.no_tests)
        if again.problems:
            for p in again.problems:
                print(f"FAIL {p}", file=sys.stderr)
            return 1
        print(f"  rewrote {n} marker(s); {again.markers} figure markers in {again.files} files are current")
        return 0

    for p in res.problems:
        print(f"FAIL {p}", file=sys.stderr)
    if res.problems:
        return 1
    print(f"  ok: {res.markers} figure markers in {res.files} files are current")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
