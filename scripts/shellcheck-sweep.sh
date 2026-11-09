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

# Memory. One shellcheck over tests/run-tests.sh peaks near 8 GB (8.2 GB RSS,
# 21 s, measured 2026-11-09). Two sweeps at once, or one beside a build, took the
# laptop to a global OOM that killed the terminal. An address-space `ulimit -v`
# does not bound it: the linter exits 251 on that file at 6 GB and at 12 GB,
# because its runtime reserves more than it uses. So the sweep does three things:
#   1. waits until MemAvailable covers the job, and refuses (75) if it never does;
#   2. runs the linter in a systemd scope with MemoryMax and no swap, so an
#      overrun kills the linter and nothing else on the machine;
#   3. runs at low priority.
# CI skips all three: a runner is its own sandbox, and a gate that waits for free
# memory on a small runner would fail a job the runner could have run.
need_kb="${MAGENT_SWEEP_MIN_AVAIL_KB:-10485760}"
wait_s="${MAGENT_SWEEP_WAIT:-300}"
poll_s="${MAGENT_SWEEP_POLL:-10}"
cap="${MAGENT_SWEEP_MEM_MAX:-12G}"
meminfo="${MAGENT_MEMINFO:-/proc/meminfo}"

avail_kb() {
    local k v
    while read -r k v _; do
        if [ "$k" = "MemAvailable:" ]; then printf '%s' "$v"; return 0; fi
    done < "$meminfo"
    return 1
}

if [ -z "${CI:-}" ]; then
    if [ -r "$meminfo" ]; then
        waited=0
        while :; do
            have="$(avail_kb)"
            case "$have" in
                ''|*[!0-9]*)
                    printf 'sweep: no usable MemAvailable in %s; not starting a job that needs %s KB.\n' \
                        "$meminfo" "$need_kb" >&2
                    exit 75 ;;
            esac
            [ "$have" -ge "$need_kb" ] && break
            if [ "$waited" -ge "$wait_s" ]; then
                printf 'sweep: MemAvailable is %s KB and the linter needs %s KB; gave up after %ss.\n' \
                    "$have" "$need_kb" "$waited" >&2
                printf 'sweep: close something heavy and retry, or set MAGENT_SWEEP_MIN_AVAIL_KB.\n' >&2
                exit 75
            fi
            sleep "$poll_s"
            waited=$((waited + poll_s))
        done
    else
        printf 'sweep: %s is not readable here; not checking free memory.\n' "$meminfo" >&2
    fi
fi

runner=()
if [ -z "${CI:-}" ] && [ -z "${MAGENT_SWEEP_NO_CAP:-}" ]; then
    if command -v systemd-run >/dev/null 2>&1 \
        && systemd-run --user --scope --quiet -p "MemoryMax=$cap" -p MemorySwapMax=0 true >/dev/null 2>&1; then
        runner=(systemd-run --user --scope --quiet -p "MemoryMax=$cap" -p MemorySwapMax=0)
    else
        printf 'sweep: no memory cap (no systemd user scope on this host); relying on the free-memory check.\n' >&2
    fi
fi
if command -v nice >/dev/null 2>&1; then runner+=(nice -n 15); fi

${runner[@]+"${runner[@]}"} shellcheck --severity=warning "${files[@]}"
rc=$?
if [ "$rc" -eq 137 ]; then
    printf 'sweep: shellcheck was killed (rc=137), most likely by the MemoryMax=%s cap. Raise MAGENT_SWEEP_MEM_MAX.\n' "$cap" >&2
fi
exit "$rc"
