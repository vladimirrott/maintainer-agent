#!/usr/bin/env bash
# The shellcheck sweep, in one place.
#
# It used to exist only inside .github/workflows/ci.yml, so the local gate could
# not run it and a push discovered SC1090 on four lines that had already passed
# every check this laptop knows how to run. A local-first project whose linter
# lives only in CI is not local-first.
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1

mapfile -t files < <(
    for f in $(git ls-files); do
        [ -f "$f" ] || continue
        # tr -d '\0': a binary file in the tree made bash print
        # "command substitution: ignored null byte in input" on every run.
        case "$(head -c 80 "$f" 2>/dev/null | tr -d '\0')" in
            *"#!/usr/bin/env bash"*|*"#!/bin/bash"*|*"#!/bin/sh"*) printf '%s\n' "$f" ;;
        esac
        # Sourced fragments carry no shebang and are still shell. The verify
        # suites decide what a receipt is worth, so they are the last place to
        # skip a linter.
        case "$f" in profiles/*/verify.d/*.sh) printf '%s\n' "$f" ;; esac
    done | sort -u
)
printf 'checking %d scripts\n' "${#files[@]}"
[ "${#files[@]}" -gt 0 ] || { echo "no scripts found; this gate inspected nothing" >&2; exit 1; }

if ! command -v shellcheck >/dev/null 2>&1; then
    # Loudly, and non-zero. A missing linter that reports success is how a gate
    # goes green over code nothing inspected.
    # printf, a builtin, rather than `cat`: the whole point of this branch is
    # that the environment is missing something, and it printed nothing at all
    # under a PATH that also lacked cat.
    printf '%s\n' \
      'shellcheck is not installed, so this gate inspected nothing.' \
      '' \
      '  Debian/Ubuntu:  sudo apt-get install -y shellcheck' \
      '  No sudo:        install the static binary from' \
      '                  https://github.com/koalaman/shellcheck/releases into ~/.local/bin' \
      '' \
      'CI runs it either way, so a push will find what this did not.' >&2
    exit 127
fi
shellcheck --severity=warning "${files[@]}"
