#!/usr/bin/env bash
# Every `uses:` in .github/workflows must be pinned to a SHA, and the version
# comment beside it must be the tag that SHA actually is.
#
# A tag is mutable and a SHA is not, so a pin is only auditable if the comment
# is true. "A comment that names a version the SHA is not on is the tell."
#
# Annotated tags point at a tag OBJECT, not at a commit, so a naive comparison
# of refs/tags/*.object.sha against the pin fails for every repository that
# signs its tags. The first version of this script did exactly that and reported
# four of five pins as wrong, which is a flag rate that means the checker is
# broken rather than the tree.
set -uo pipefail
# Takes an optional repository root, so the check can be pointed at any
# checkout rather than only the one it lives in. sysknife has no pin verifier of
# its own and carries the same stale actions/deploy-pages pin this repository
# copied from it.
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -d "$root/.github/workflows" ] || { echo "verify-action-pins: no .github/workflows under $root" >&2; exit 2; }
fail=0

# A loop cannot fail on a line it never saw.
#
# The extraction at the bottom of this file requires a line to be pinned
# ALREADY: `uses: <action>@<40 hex> # <tag>`. A floating tag, a short SHA, or a
# SHA with no version comment produced no row, `fail` stayed 0, and the
# all-clear printed over the exact defect line 2 says this script forbids.
# Measured: replacing the actions/deploy-pages pin with `@v5` left the run at
# `RC=0  every pin is the tag it claims`.
#
# So count the other side first. Every `uses:` line has to match the strict
# pattern, and the ones that do not are named rather than skipped. This runs
# before any network call, so a tree whose only defect is an unparseable line
# fails without asking GitHub anything.
# `- uses:` is as valid as `uses:`, and anchoring to the second form alone
# reproduced the defect being fixed: the probe line was never seen either.
# A leading `#` is excluded so a commented-out example is not flagged.
unparsed="$(grep -hE '^[[:space:]]*(-[[:space:]]*)?uses:' \
                "$root"/.github/workflows/*.yml "$root"/examples/*.yml 2>/dev/null \
            | grep -oE 'uses:.*' | sed 's/[[:space:]]*$//' | sort -u \
            | grep -vE '^uses: [^@ ]+@[0-9a-f]{40} *# *\S+$' || true)"
if [ -n "$unparsed" ]; then
    echo "  FAIL    not SHA-pinned with a version comment, so nothing below checks them:" >&2
    printf '%s\n' "$unparsed" | sed 's/^/            /' >&2
    fail=1
fi

deref() {  # $1 repo, $2 tag -> the commit that tag names
    local obj type
    obj="$(gh api "repos/$1/git/ref/tags/$2" --jq '.object.sha' 2>/dev/null)" || return 1
    type="$(gh api "repos/$1/git/ref/tags/$2" --jq '.object.type' 2>/dev/null)"
    if [ "$type" = tag ]; then
        gh api "repos/$1/git/tags/$obj" --jq '.object.sha' 2>/dev/null
    else
        printf '%s' "$obj"
    fi
}

while IFS= read -r line; do
    action="${line%%@*}"; rest="${line#*@}"
    sha="${rest%% *}"; claim="$(printf '%s' "$rest" | sed 's/.*# *//')"
    repo="$(printf '%s' "$action" | cut -d/ -f1,2)"
    if [ "$claim" = main ] || [ "$claim" = master ]; then
        printf '  branch  %-46s tracks %s by design\n' "$action" "$claim"
        continue
    fi
    real="$(deref "$repo" "$claim")"
    if [ -z "$real" ]; then
        printf '  FAIL    %-46s claims %s, which is not a tag in %s\n' "$action" "$claim" "$repo"; fail=1
    elif [ "$real" = "$sha" ]; then
        printf '  ok      %-46s %s is %s\n' "$action" "${sha:0:8}" "$claim"
    else
        printf '  FAIL    %-46s pinned %s but %s is %s\n' "$action" "${sha:0:8}" "$claim" "${real:0:8}"; fail=1
    fi
# examples/ too: a pin somebody copies out of an example is the one most worth
# being true.
done < <(grep -hoE 'uses: [^@ ]+@[0-9a-f]{40} *# *\S+' \
             "$root"/.github/workflows/*.yml "$root"/examples/*.yml 2>/dev/null \
         | sed 's/^uses: //' | sort -u)

[ "$fail" = 0 ] && echo "  every pin is the tag it claims" || echo "  a pin does not match its comment" >&2
exit "$fail"
