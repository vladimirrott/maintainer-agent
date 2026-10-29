#!/usr/bin/env python3
"""Ask PyPI whether every pinned hash is a file the release publishes.

Why this exists. A hash-pinned requirement makes two claims: pip installs these
exact files, and these files are the release the version names. pip enforces
the first with --require-hashes. Nothing enforces the second, so a bump whose
hashes belong to some other upload is a pin that reads correctly and installs
something else. Same defect as an action pin whose comment names the wrong tag,
one registry over.

Prints how many of the release's files the hashes matched and exits 0. Any
other outcome exits non-zero with a reason on stderr, because a release PyPI
could not be asked about, one with no files, and one that does not match must
none of them look like agreement.

    verify_pypi_release.py PyYAML 6.0.3 <sha256>,<sha256>,...

MAINTAINER_PYPI_URL replaces https://pypi.org/pypi, so the suite can serve the
JSON from a file:// tree and stay offline.
"""

import json
import os
import re
import sys
import typing
import urllib.error
import urllib.request

TIMEOUT = 30

# Both end up in the URL path. PyPI normalises that path before it looks
# anything up, so a `/` or a `..` here could ask about some other project and
# report its answer as this one's. PEP 508 names, and the characters a PEP 440
# version may hold, with no separator in either.
NAME = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?")
VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9.+!_-]*")
SHA256 = re.compile(r"[0-9a-f]{64}")


def die(reason) -> typing.NoReturn:
    print(f"verify_pypi_release: {reason}", file=sys.stderr)
    raise SystemExit(1)


def main():
    if len(sys.argv) != 4:
        die("usage: verify_pypi_release.py <name> <version> <sha256>[,<sha256>...]")
    name, version, joined = sys.argv[1:4]
    if not NAME.fullmatch(name):
        die(f"{name!r} is not a plain package name, so it is not put in a URL")
    if not VERSION.fullmatch(version):
        die(f"{version!r} is not a plain version, so it is not put in a URL")
    hashes = [h for h in joined.split(",") if h]
    for h in hashes:
        if not SHA256.fullmatch(h):
            die(f"{h!r} is not a sha256 digest")

    base = os.environ.get("MAINTAINER_PYPI_URL", "https://pypi.org/pypi").rstrip("/")
    url = f"{base}/{name}/{version}/json"
    request = urllib.request.Request(url, headers={"User-Agent": "maintainer-agent verify-deps"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as answer:
            doc = json.load(answer)
    except urllib.error.HTTPError as err:
        die(f"could not ask PyPI about {name} {version}: HTTP {err.code}")
    except (urllib.error.URLError, OSError) as err:
        die(f"could not ask PyPI about {name} {version}: {err}")
    except ValueError as err:
        die(f"PyPI answered for {name} {version} with something that is not JSON: {err}")

    files = doc.get("urls") or []
    if doc.get("info", {}).get("yanked") or any(f.get("yanked") for f in files):
        die(f"PyPI has yanked {name} {version}")
    published = {f.get("digests", {}).get("sha256") for f in files} - {None}
    if not published:
        # A release with nothing to match and a release every hash matched would
        # both leave the loop below silent.
        die(f"PyPI lists no files for {name} {version}, so there is nothing a hash could match")
    for h in hashes:
        if h not in published:
            die(f"sha256:{h[:12]} is not a file PyPI publishes for {name} {version}")
    print(f"{len(hashes)} of {len(published)} files")


if __name__ == "__main__":
    main()
