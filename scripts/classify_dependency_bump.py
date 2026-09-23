#!/usr/bin/env python3
"""Decide whether a unified diff is nothing but a dependency bump.

Why this exists. `maintainer-merge verify` proves a guard bites by mutating it
and watching a test go red. A lockfile bump has no guard, so no mutation can be
written, no receipt can be earned, and `merge` refuses the whole class. On
2026-09-23 that pushed sysknife#492 and #495 through `gh pr merge --admin`,
which is the exact path the gate exists to remove.

A dependency bump does carry a provable claim; it is just a different one:

  1. nothing outside dependency metadata changed,
  2. no new place to download from appeared, and
  3. every GitHub Action pin is still a SHA, and names the tag it claims.

This script answers 1 and 2 from the diff alone, and hands the caller the pins
for 3, which needs the network and belongs to whoever has a token.

It prints JSON and exits 0 for a dependency bump, 1 for a refusal. A refusal
names the file and the line, because "refused" with no line is indistinguishable
from a parser that read nothing.

Read on stdin:  git diff / gh pr diff --patch output.
"""

import json
import os
import re
import sys
import typing
from collections import Counter
from urllib.parse import urlparse

CRATES_IO = 'source = "registry+https://github.com/rust-lang/crates.io-index"'
NPM_REGISTRY = "registry.npmjs.org"

# `uses: owner/repo@<40 hex>  # <tag>`, the only shape a pin bump may have.
# An action pinned to a floating tag is the defect this repository's own
# verify-action-pins.sh exists to catch, so a diff that introduces one is not a
# routine bump whatever Dependabot titled it.
PIN = re.compile(
    r"^\s*(?:-\s*)?uses:\s*(?P<action>[^@\s]+)@(?P<sha>[0-9a-f]{40})\s*#\s*(?P<tag>\S+)\s*$"
)

# Lines a Cargo.lock bump is made of. Anything else in that file is somebody
# editing the lockfile by hand, which is not this class.
CARGO_LOCK_OK = (
    "[[package]]",
    "name = ",
    "version = ",
    "source = ",
    "checksum = ",
    "dependencies = [",
    "]",
    "",
)

# npm keys that make installing a package run code, or move where it comes from.
# Each one is a real remote-code-execution surface in a lockfile, so a bump that
# introduces one stops here and goes to a person.
NPM_DANGEROUS = ("hasInstallScript", "scripts", "preinstall", "postinstall", "gypfile")


def classify_path(path):
    base = os.path.basename(path)
    if base == "Cargo.lock":
        return "cargo-lock"
    if base == "Cargo.toml":
        return "cargo-manifest"
    if base == "package-lock.json":
        return "npm-lock"
    if base == "package.json":
        return "npm-manifest"
    if path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
        return "workflow"
    if path.startswith(".github/actions/") and base in ("action.yml", "action.yaml"):
        return "workflow"
    return None


def parse(diff):
    """{path: [(sign, text), ...]} for every changed line, in order."""
    files, path = {}, None
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            # `diff --git a/x b/x`; take the b-side, which is the path after a
            # rename and identical otherwise.
            path = line.split(" b/", 1)[1] if " b/" in line else None
            files.setdefault(path, [])
            continue
        if line.startswith(("--- ", "+++ ", "index ", "@@", "new file", "deleted file",
                            "old mode", "new mode", "similarity index", "rename ",
                            "Binary files")):
            continue
        if path is None:
            continue
        if line.startswith("+"):
            files[path].append(("+", line[1:]))
        elif line.startswith("-"):
            files[path].append(("-", line[1:]))
    return files


def skeleton(text):
    """The line with every quoted literal blanked.

    Two Cargo.toml lines whose skeletons match differ only inside quotes, which
    is what a version bump is. Adding a feature to an array changes a comma,
    outside the quotes, so it does not match and does not pass as a bump.
    """
    return re.sub(r'"[^"]*"', '""', text).strip()


def refuse(reason, path=None, line=None) -> typing.NoReturn:
    out = {"verdict": "refused", "reason": reason}
    if path:
        out["path"] = path
    if line is not None:
        out["line"] = line
    json.dump(out, sys.stdout, indent=2)
    print()
    raise SystemExit(1)


def main():
    diff = sys.stdin.read()
    files = parse(diff)
    if not files:
        # An empty diff and a diff this parser failed to read look the same from
        # here, and one of them must not be called a dependency bump.
        refuse("the diff named no changed file, so nothing was classified")

    pins, kinds, changed_lines = [], {}, 0
    for path, lines in sorted(files.items()):
        kind = classify_path(path)
        if kind is None:
            refuse(f"{path} is not dependency metadata, so this is not a pure bump", path)
        kinds[path] = kind
        changed_lines += len(lines)

        if kind == "cargo-lock":
            for sign, text in lines:
                body = text.strip()
                if sign == "+" and body.startswith("source = ") and body != CRATES_IO:
                    refuse("a lockfile line points at a source that is not crates.io",
                           path, body)
                if not body.startswith(CARGO_LOCK_OK) and not body.startswith('"'):
                    refuse("a Cargo.lock line is not package metadata", path, body)

        elif kind == "cargo-manifest":
            added = Counter(skeleton(t) for s, t in lines if s == "+")
            removed = Counter(skeleton(t) for s, t in lines if s == "-")
            if added != removed:
                only = (added - removed) or (removed - added)
                refuse("a manifest line changed outside its version literal",
                       path, next(iter(only)))

        elif kind in ("npm-lock", "npm-manifest"):
            for sign, text in lines:
                if sign != "+":
                    continue
                body = text.strip()
                for key in NPM_DANGEROUS:
                    if f'"{key}"' in body:
                        refuse(f"the bump adds {key}, so installing it would run code",
                               path, body)
                if body.startswith('"resolved"'):
                    url = body.split('"')[3] if body.count('"') >= 4 else ""
                    if urlparse(url).hostname != NPM_REGISTRY:
                        refuse(f"a tarball comes from somewhere other than {NPM_REGISTRY}",
                               path, body)
                if body.startswith('"integrity"'):
                    value = body.split('"')[3] if body.count('"') >= 4 else ""
                    if not value.startswith(("sha512-", "sha1-")):
                        refuse("an integrity field is not a sha512/sha1 digest", path, body)

        elif kind == "workflow":
            for sign, text in lines:
                match = PIN.match(text)
                if not match:
                    refuse("a workflow line changed that is not an action pin", path,
                           text.strip())
                if sign == "+":
                    pins.append({"action": match["action"], "sha": match["sha"],
                                 "tag": match["tag"]})

    json.dump({
        "verdict": "dependency-bump",
        "files": kinds,
        "changed_lines": changed_lines,
        # The caller verifies these against GitHub: a comment naming a tag the
        # SHA is not on is the whole reason to pin by SHA in the first place.
        "pins": pins,
    }, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
