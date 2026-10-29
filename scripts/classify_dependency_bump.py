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
  3. every GitHub Action pin is still a SHA, and names the tag it claims (and
     every base image digest, and every pip hash, is what its registry
     publishes under that tag or version).

This script answers 1 and 2 from the diff alone, and hands the caller the pins,
images and pip packages for 3, which needs the network.

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
#
# `# stable (branch)` marks a pin that tracks a branch on purpose. Its comment
# names a branch, not a tag, so the caller proves the SHA is reachable from
# that branch instead of asking what a tag points at.
PIN = re.compile(
    r"^\s*(?:-\s*)?uses:\s*(?P<action>[^@\s]+)@(?P<sha>[0-9a-f]{40})\s*#\s*(?P<tag>\S+)"
    r"(?P<branch>\s+\(branch\))?\s*$"
)

# What a tag or branch in a pin comment may look like, and what an action path
# may look like. Both are interpolated into a GitHub API path by the caller, and
# GitHub normalises that path before it resolves anything: `v4.2.2/../pull/1/head`
# reaches a pull request's head, which anyone can push, and passed as the tag.
# Same class as sysknife GHSA-j754. A segment is plain characters and never
# empty (so no leading, trailing or doubled `/`). Its first character may not be
# `.` or `-`, which is what keeps `.` and `..` out: there is no second check for
# them, because a second copy of a rule is the copy that drifts. Narrower than
# git's own rules on purpose: a real tag this refuses goes to a person, and a
# path this accepts goes to the network.
REF_SEGMENT = re.compile(r"[A-Za-z0-9_+][A-Za-z0-9._+-]*")
ACTION_SEGMENT = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*")


def _plain_path(text, segment):
    """True when every `/`-separated part of `text` is a plain segment."""
    return all(segment.fullmatch(p) for p in text.split("/"))

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

# `FROM <registry>/<repo>:<tag>@sha256:<64 hex> [AS <stage>]`, the only shape a
# base image may have here. A tag alone is mutable, so the digest is the control
# and a bump that drops it has given up the property the pin existed for,
# whatever Dependabot titled the pull request. `--platform=` and friends are
# allowed through because they change nothing about where the bytes come from.
FROM_PIN = re.compile(
    r"^\s*FROM\s+(?:--[^\s]+\s+)*"
    r"(?P<image>[^\s:@]+):(?P<tag>[^\s@/]+)"
    r"@(?P<digest>sha256:[0-9a-f]{64})"
    r"(?:\s+AS\s+\S+)?\s*$",
    re.IGNORECASE,
)

# A requirements file as pip-compile and Dependabot write it: `name==version`,
# then one `--hash=sha256:` line per published file, every line but the last
# ending in a backslash. That grammar is the whole allowlist. pip also reads
# `--index-url`, `--extra-index-url`, `-f`, `-e`, `-r`, `-c` and `name @ url`
# from this file, and each of those is a place to download from, so none of
# them gets a pattern: a line that matches nothing here goes to a person.
# Extras are left out as well, because `name[x]` installs packages the line
# does not name. An environment marker may follow the pin, in a character set
# with no `@`, `/` or `:`, so it cannot carry a URL.
PIP_REQ = re.compile(
    r"^(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)==(?P<version>[A-Za-z0-9][A-Za-z0-9.+!_-]*)"
    r"(?:\s*;\s*[A-Za-z0-9_.<>=!'\" ()~-]+?)?\s*(?P<cont>\\)?\s*$"
)
PIP_HASH = re.compile(r"^\s+--hash=sha256:(?P<digest>[0-9a-f]{64})\s*(?P<cont>\\)?\s*$")
PIP_INERT = re.compile(r"^\s*(?:#.*)?$")


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
    if base == "Dockerfile" or base.startswith("Dockerfile.") or base.endswith(".Dockerfile"):
        return "dockerfile"
    if base.startswith("requirements") and base.endswith(".txt"):
        return "pip-requirements"
    return None


def parse(diff):
    """{path: [(sign, text), ...]} for every changed line, in order.

    Only inside a hunk. `gh pr diff --patch` concatenates one mbox patch per
    commit, so between two diffs there is a `From <sha>` line, the commit
    message and a bare `---`. Reading +/- by first character alone turns that
    `---` into a removed line and every `- bullet` in a commit body into
    another, filed under whichever path the previous patch ended on. The first
    version did that, and sysknife#494 was refused with a complaint about a
    manifest line reading `--`. It failed closed, which is the right direction
    for the wrong reason: every rebased Dependabot pull request would be refused
    the same way.
    """
    files, path, in_hunk = {}, None, False
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            # `diff --git a/x b/x`; take the b-side, which is the path after a
            # rename and identical otherwise.
            path = line.split(" b/", 1)[1] if " b/" in line else None
            files.setdefault(path, [])
            in_hunk = False
            continue
        if line.startswith("From ") and len(line.split()) > 2:
            # The next commit's mbox header: nothing after it belongs to the
            # file the previous patch was describing.
            path, in_hunk = None, False
            continue
        if line.startswith("@@"):
            in_hunk = path is not None
            continue
        if line.startswith(("--- ", "+++ ", "index ", "new file", "deleted file",
                            "old mode", "new mode", "similarity index", "rename ",
                            "Binary files")):
            continue
        if not in_hunk or path is None:
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

    pins, images, packages, kinds, changed_lines = [], [], [], {}, 0
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

        elif kind == "dockerfile":
            # Paired by image name rather than line by line: the claim is that
            # the same repository moved to a new digest, so every added FROM has
            # to name an image some removed FROM already named. A bump that
            # repoints the build at another registry is a new place to download
            # from, which is the one thing this whole class may not do.
            added, removed = [], []
            for sign, text in lines:
                if not text.strip().upper().startswith("FROM"):
                    refuse("a Dockerfile line changed that is not a base image pin",
                           path, text.strip())
                match = FROM_PIN.match(text)
                if not match:
                    refuse("a base image is not pinned by digest", path, text.strip())
                (added if sign == "+" else removed).append(match)
            was = {m["image"] for m in removed}
            for match in added:
                if match["image"] not in was:
                    refuse("the base image comes from a different image than the one "
                           "it replaces", path, match.string.strip())
                # same_tag: the image kept its tag and only the digest moved.
                # A Dependabot digest bump carries no semver class, and this
                # is the shape `maintainer deps` lets through without one.
                images.append({"image": match["image"], "tag": match["tag"],
                               "digest": match["digest"],
                               "same_tag": any(m["image"] == match["image"] and m["tag"] == match["tag"]
                                               for m in removed)})

        elif kind == "pip-requirements":
            # Each added hash belongs to the requirement above it. A hash with no
            # requirement in the diff changed under a pin the diff does not show,
            # so the version it belongs to is unknown here and nothing could
            # check it against the release it claims to be.
            current, hashed, added = None, False, []
            for sign, text in lines:
                req, digest = PIP_REQ.match(text), PIP_HASH.match(text)
                if not (req or digest or PIP_INERT.match(text)):
                    refuse("a requirements line is not a pinned requirement, a hash or a comment",
                           path, text.strip())
                # pip splits a requirement line on single spaces and reads
                # everything from the first token starting with `-` as options
                # (req_file.break_args_options), inside quotes or not. The
                # marker's character set holds `-`, `=` and quotes, so
                # `--config-settings=...` would otherwise ride in as a marker.
                if req and any(tok.startswith("-") for tok in text.split(" ")):
                    refuse("a requirement line carries a pip option after its pin",
                           path, text.strip())
                hashed = hashed or bool(digest)
                if sign != "+":
                    continue
                if req:
                    package = {"name": req["name"], "version": req["version"], "hashes": []}
                    added.append(package)
                    current = package if req["cont"] else None
                elif digest:
                    if current is None:
                        refuse("a hash changed without the requirement it belongs to",
                               path, text.strip())
                    current["hashes"].append(digest["digest"])
                    if not digest["cont"]:
                        current = None
                else:
                    current = None
            # Once either side of the diff shows a hash, the file is hash-pinned,
            # and a requirement that arrives without one has given up the check
            # --require-hashes makes. pip would refuse to install it; this says
            # why before CI does.
            for package in added:
                if hashed and not package["hashes"]:
                    refuse(f"the bump drops hash pinning for {package['name']}", path,
                           f"{package['name']}=={package['version']}")
            packages.extend(added)

        elif kind == "workflow":
            for sign, text in lines:
                match = PIN.match(text)
                if not match:
                    refuse("a workflow line changed that is not an action pin", path,
                           text.strip())
                if sign == "+":
                    action = match["action"]
                    if len(action.split("/")) < 2 or not _plain_path(action, ACTION_SEGMENT):
                        refuse("an action path is not plain owner/repo[/dir] segments, and the gate "
                               "would put it in a GitHub API path", path, text.strip())
                    if not _plain_path(match["tag"], REF_SEGMENT):
                        refuse("a pin comment is not a plain tag or branch name: GitHub normalises "
                               "`..`, `/` and escapes in the API path the gate would ask, so it could "
                               "resolve to a ref that is not a tag", path, text.strip())
                    pins.append({"action": match["action"], "sha": match["sha"],
                                 "tag": match["tag"], "branch": bool(match["branch"])})

    json.dump({
        "verdict": "dependency-bump",
        "files": kinds,
        "changed_lines": changed_lines,
        # The caller verifies these against GitHub: a comment naming a tag the
        # SHA is not on is the whole reason to pin by SHA in the first place.
        "pins": pins,
        # And these against the registry, for the same reason: a digest that is
        # not the one its tag resolves to is a pin whose comment is false.
        "images": images,
        # And these against PyPI: a hash that is not one of the files the
        # release publishes pins bytes the version number does not name.
        "pip": packages,
    }, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
