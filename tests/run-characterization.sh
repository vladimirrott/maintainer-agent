#!/usr/bin/env bash
# Runs the characterization tests of the merge gate (tests/characterization/gate-*.sh)
# and prints "N cases, P passed, F failed".
#
# These cases record what the bash bin/maintainer-merge does today, odd
# behaviour included, so a later port can be held to it. MX_TREE names the tree
# under test and defaults to this checkout:
#
#   bash tests/run-characterization.sh                  # this checkout
#   MX_TREE=/path/to/other/tree bash tests/run-characterization.sh
#   bash tests/run-characterization.sh gate-usage.sh    # one gate file
#
# It exits non-zero when a case fails, when no case ran, when a gate file ends
# without its summary line, or when the cases a file printed do not add up to
# the total its summary reports. A file that crashes half way therefore cannot
# read as a pass.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MX_TREE="${MX_TREE:-$(cd "$here/.." && pwd)}"
if [ ! -f "$MX_TREE/bin/maintainer-merge" ]; then
    printf 'run-characterization: no bin/maintainer-merge under MX_TREE=%s\n' "$MX_TREE" >&2
    exit 2
fi
printf 'tree under test: %s\n' "$MX_TREE"

# Arguments name gate files to run (gate-usage.sh, ...). With none, every
# gate-*.sh runs. A name that matches no file is an error, not an empty run.
shopt -s nullglob
files=()
if [ "$#" -gt 0 ]; then
    for want in "$@"; do
        if [ ! -f "$here/characterization/$want" ]; then
            printf 'run-characterization: no such gate file: %s\n' "$want" >&2
            exit 2
        fi
        files+=("$here/characterization/$want")
    done
else
    files=("$here"/characterization/gate-*.sh)
fi
if [ "${#files[@]}" -eq 0 ]; then
    echo "run-characterization: no gate-*.sh files found; this run inspected nothing" >&2
    exit 1
fi

total=0; passed=0; failed=0; bad_files=0
for f in "${files[@]}"; do
    name="$(basename "$f")"
    out="$(bash "$f" 2>&1)"; rc=$?
    summary="$(grep -E '^SUMMARY cases=[0-9]+ pass=[0-9]+ fail=[0-9]+$' <<<"$out" | tail -1)"
    if [ -z "$summary" ]; then
        printf '== %s: no summary line (exit %s). Output follows.\n%s\n' "$name" "$rc" "$out" >&2
        bad_files=$((bad_files + 1)); continue
    fi
    n="${summary#SUMMARY cases=}"; n="${n%% *}"
    p="${summary#*pass=}"; p="${p%% *}"
    f_="${summary#*fail=}"
    seen=$(( $(grep -cE '^(PASS|FAIL)  ' <<<"$out") ))
    if [ "$seen" != "$n" ] || [ "$((p + f_))" != "$n" ]; then
        printf '== %s: summary says %s cases (%s pass, %s fail) but %s case lines were printed\n' "$name" "$n" "$p" "$f_" "$seen" >&2
        bad_files=$((bad_files + 1))
    fi
    printf '== %s: %s cases\n' "$name" "$n"
    grep -vE '^SUMMARY ' <<<"$out"
    total=$((total + n)); passed=$((passed + p)); failed=$((failed + f_))
done

printf '%d cases, %d passed, %d failed\n' "$total" "$passed" "$failed"
printf 'files run: %d\n' "${#files[@]}"
[ "$bad_files" -eq 0 ] || { printf 'run-characterization: %d gate file(s) did not print a summary\n' "$bad_files" >&2; exit 1; }
[ "$total" -gt 0 ] || { echo "run-characterization: zero cases ran" >&2; exit 1; }
[ "$failed" -eq 0 ]
