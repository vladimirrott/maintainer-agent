#!/usr/bin/env python3
"""Compare two whole requirements files the way pip reads them.

Why this exists. The classifier sees a diff, and pip sees a file. A diff shows
three lines of context at most, and pip's reading depends on lines it does not
show: a trailing backslash joins the next line even when that line is
unchanged, a hash chain can start seventy lines above a hunk, and a `# coding:`
cookie on line 1 or 2 re-decodes every byte below it. A review of the
diff-only arm found each of those turning a non-bump into a bump. So
verify-deps also hands this script the file at the merge base and at the head,
and the receipt needs both readings to agree.

    verify_pip_files.py <base file> <head file>

Prints JSON: every requirement whose version moved, with its hashes. Exits 1
with a reason on stderr when either file holds anything outside the allowlist,
or the change is anything but existing pins moving up.

The reading follows pip's req_file.py: lines are split as Python splits them,
a line ending in a backslash joins the next unless it is a comment, comments
are stripped, and the first space-separated token starting with `-` starts the
options. Everything that would make that reading differ from this one (a BOM,
an encoding cookie, a byte outside printable ASCII, a line-break character
Python splits on and git does not) is refused instead of modelled.
"""

import json
import re
import sys
import typing

COMMENT_RE = re.compile(r"(^|\s+)#.*$")
PIN = re.compile(r"(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)==(?P<version>[A-Za-z0-9][A-Za-z0-9.+!_-]*)")
MARKER = re.compile(r"[A-Za-z0-9_.<>=!'\" ()~-]+")
HASH = re.compile(r"--hash=sha256:(?P<digest>[0-9a-f]{64})")
# pip's auto_decode looks for this in a comment on the first two lines.
COOKIE = re.compile(r"coding[:=]")


def die(reason) -> typing.NoReturn:
    print(f"verify_pip_files: {reason}", file=sys.stderr)
    raise SystemExit(1)


def logical_lines(raw, label):
    if raw.startswith((b"\xef\xbb\xbf", b"\xff\xfe", b"\xfe\xff")):
        die(f"the {label} file starts with a byte-order mark, which pip decodes by")
    for i, byte in enumerate(raw):
        if not (byte in (0x09, 0x0A) or 0x20 <= byte <= 0x7E):
            die(f"the {label} file holds byte 0x{byte:02x} at offset {i}; only printable "
                "ASCII, tab and newline are read the same by pip and by this check")
    text = raw.decode("ascii")
    for line in text.split("\n")[:2]:
        if line.lstrip().startswith("#") and COOKIE.search(line):
            die(f"the {label} file has an encoding cookie on line 1 or 2, which pip decodes by")
    # join_lines
    joined, pending = [], []
    for line in text.splitlines():
        if not line.endswith("\\") or COMMENT_RE.match(line):
            if COMMENT_RE.match(line):
                line = " " + line
            if pending:
                pending.append(line)
                joined.append("".join(pending))
                pending = []
            else:
                joined.append(line)
        else:
            pending.append(line.strip("\\"))
    if pending:
        joined.append("".join(pending))
    # ignore_comments
    for line in joined:
        line = COMMENT_RE.sub("", line).strip()
        if line:
            yield line


def requirements(raw, label):
    """{normalised name: (name, version, marker, frozenset of hashes)}"""
    out = {}
    for line in logical_lines(raw, label):
        tokens = line.split(" ")
        cut = next((i for i, t in enumerate(tokens) if t.startswith("-")), len(tokens))
        args, options = " ".join(tokens[:cut]).strip(), [t for t in tokens[cut:] if t]
        if not args:
            die(f"the {label} file has an option line, which can change where pip "
                f"downloads from: {line[:120]!r}")
        pin, sep, marker = args.partition(";")
        match = PIN.fullmatch(pin.strip())
        marker = marker.strip()
        if not match or (sep and not MARKER.fullmatch(marker)):
            die(f"the {label} file has a line that is not a pinned requirement: {line[:120]!r}")
        hashes = set()
        for option in options:
            found = HASH.fullmatch(option)
            if not found:
                die(f"the {label} file passes an option other than --hash=sha256: "
                    f"{option[:80]!r} on {match['name']}")
            hashes.add(found["digest"])
        key = re.sub(r"[-_.]+", "-", match["name"]).lower()
        if key in out:
            die(f"the {label} file pins {match['name']} twice")
        out[key] = (match["name"], match["version"], marker, frozenset(hashes))
    return out


def version_key(version):
    parts = version.split(".")
    return tuple(int(p) for p in parts) if all(p.isdigit() for p in parts) else None


def main():
    if len(sys.argv) != 3:
        die("usage: verify_pip_files.py <base file> <head file>")
    base = requirements(open(sys.argv[1], "rb").read(), "base")
    head = requirements(open(sys.argv[2], "rb").read(), "head")
    if set(base) != set(head):
        die("the files pin different packages: " + ", ".join(sorted(set(base) ^ set(head))))
    hashed = any(r[3] for r in base.values())
    changed = []
    for key in sorted(head):
        name, version, marker, hashes = head[key]
        _, old_version, old_marker, old_hashes = base[key]
        if hashed and not hashes:
            die(f"{name} lost its hashes, and the base file is hash-pinned")
        if marker != old_marker:
            die(f"{name}'s marker changed: {old_marker!r} -> {marker!r}")
        if version == old_version:
            if hashes != old_hashes:
                die(f"{name} stays at {version} and its hashes changed")
            continue
        old_k, new_k = version_key(old_version), version_key(version)
        if old_k is None or new_k is None or new_k <= old_k:
            die(f"{name} moves {old_version} -> {version}, which is not shown to be an upgrade")
        changed.append({"name": name, "version": version, "hashes": sorted(hashes)})
    if not changed:
        die("no pinned version moved between the two files")
    json.dump({"changed": changed}, sys.stdout)
    print()


if __name__ == "__main__":
    main()
