#!/usr/bin/env bash
# Hold the README's numbers to what the tree actually contains.
#
# Same idea as the target repository's evidence artifact: a published figure
# must be derived, never typed. A README that claims 42 tests while the suite
# has 30 is the shape of defect this whole project exists to catch, and it
# would be embarrassing to ship it here.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
note() { printf '  %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

# Measured, not asserted.
tests_actual=$(bash "$root/tests/run-tests.sh" 2>/dev/null | sed -n 's/^ *\([0-9]\+\) passed.*/\1/p' | tail -1)
[ -n "$tests_actual" ] || { bad "could not measure the test count; refusing to pass over nothing"; exit 1; }
evals_actual=$(find "$root/evals/scenarios" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
backends_actual=$(find "$root/lib/backends" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
# Generated, then counted. Counting the spec would let a generator bug that
# drops every absolute spelling pass unnoticed.
gen_dir="$(mktemp -d)"; trap 'rm -rf "$gen_dir"' EXIT
cp "$root/profiles/sysknife/deny.json" "$gen_dir/" 2>/dev/null
python3 "$root/scripts/render-settings.py" "$gen_dir" /home/claimcheck >/dev/null 2>&1
deny_actual=$(python3 -c "
import json
print(len(json.load(open('$gen_dir/settings.json'))['permissions']['deny']))" 2>/dev/null)
rehearsal_actual=$(python3 -c "
import json
print(len(json.load(open('$gen_dir/settings-rehearsal.json'))['permissions']['deny']))" 2>/dev/null)
[ -n "$deny_actual" ] || { bad "could not generate the deny wall; refusing to pass over nothing"; exit 1; }

note "measured: $tests_actual tests, $evals_actual eval scenarios, $backends_actual backends, $deny_actual deny rules, $rehearsal_actual in rehearsal"

claim() {  # $1 = regex capturing a number in README, $2 = actual, $3 = label
    local claimed
    claimed=$(grep -oE "$1" "$root/README.md" | grep -oE '[0-9]+' | head -1)
    if [ -z "$claimed" ]; then
        bad "README no longer states $3; the claim check now inspects nothing"
        return
    fi
    if [ "$claimed" != "$2" ]; then
        bad "README says $claimed $3, the tree has $2"
    else
        note "ok: $3 = $2"
    fi
}
claim '[0-9]+ (offline )?tests'     "$tests_actual"    "tests"
claim '[0-9]+ (adversarial )?eval'  "$evals_actual"    "eval scenarios"
claim '[0-9]+ deny rules'           "$deny_actual"     "deny rules"
claim '[0-9]+ in rehearsal'        "$rehearsal_actual" "rehearsal rules"

exit "$fail"
