#!/usr/bin/env python3
"""Ask a container registry what digest a tag resolves to, right now.

Why this exists. A Dockerfile that pins `rust:1-bookworm@sha256:...` makes two
claims: the build uses that exact image, and that image is what the tag names.
The first is enforced by the daemon at build time. Nothing enforces the second,
so a bump whose digest belongs to some other image is a pin that reads correctly
and points somewhere else. That is the same defect `verify-action-pins.sh`
catches for GitHub Actions, one registry over.

Prints the digest and exits 0. Any other outcome exits non-zero with a reason on
stderr, because a resolver that cannot reach the registry and a tag that does
not exist must not look like agreement.

    resolve_image_digest.py docker.io/library/rust 1-bookworm
"""

import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

# The two media types a tag may answer with. Asking for only the older one makes
# a multi-arch image answer with a per-architecture manifest, whose digest is
# not the one the Dockerfile pins.
ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))

TIMEOUT = 30
CHALLENGE = re.compile(r'(\w+)="([^"]*)"')


def die(reason):
    print(f"resolve_image_digest: {reason}", file=sys.stderr)
    raise SystemExit(1)


def split_ref(image):
    """`docker.io/library/rust` -> ("registry-1.docker.io", "library/rust").

    A first component with a dot or a colon is a registry; anything else is a
    Docker Hub repository, and a single bare name lives under `library/`.
    """
    head, _, rest = image.partition("/")
    if not rest or ("." not in head and ":" not in head and head != "localhost"):
        repo = image if "/" in image else f"library/{image}"
        return "registry-1.docker.io", repo
    if head in ("docker.io", "index.docker.io"):
        return "registry-1.docker.io", rest if "/" in rest else f"library/{rest}"
    return head, rest


def head_manifest(registry, repo, tag, token):
    url = f"https://{registry}/v2/{repo}/manifests/{tag}"
    request = urllib.request.Request(url, method="HEAD")
    request.add_header("Accept", ACCEPT)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    return urllib.request.urlopen(request, timeout=TIMEOUT)


def bearer_token(challenge):
    fields = dict(CHALLENGE.findall(challenge))
    realm = fields.get("realm")
    if not realm:
        die(f"the registry asked for auth without naming a realm: {challenge}")
    query = "&".join(f"{k}={urllib.parse.quote(v, safe='')}"
                     for k, v in fields.items() if k in ("service", "scope"))
    url = f"{realm}?{query}" if query else realm
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as answer:
            body = json.load(answer)
    except (urllib.error.URLError, ValueError, OSError) as err:
        die(f"could not get a token from {realm}: {err}")
    token = body.get("token") or body.get("access_token")
    if not token:
        die(f"{realm} answered without a token")
    return token


def main():
    if len(sys.argv) != 3:
        die("usage: resolve_image_digest.py <image> <tag>")
    image, tag = sys.argv[1], sys.argv[2]
    registry, repo = split_ref(image)

    token = None
    for attempt in (1, 2):
        try:
            answer = head_manifest(registry, repo, tag, token)
        except urllib.error.HTTPError as err:
            if err.code == 401 and attempt == 1:
                token = bearer_token(err.headers.get("WWW-Authenticate", ""))
                continue
            die(f"{registry}/{repo}:{tag} answered HTTP {err.code}")
        except (urllib.error.URLError, OSError) as err:
            die(f"could not reach {registry}: {err}")
        digest = answer.headers.get("Docker-Content-Digest")
        if not digest:
            die(f"{registry} answered for {repo}:{tag} without a content digest")
        print(digest)
        return
    die("the registry asked for authentication twice")


if __name__ == "__main__":
    main()
