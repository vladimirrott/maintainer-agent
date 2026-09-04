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

# Measured, not asserted. The suite's STATUS is read before its output: this
# check once parsed "236 passed" out of a red suite and reported
# "README says 242 tests, the tree has 236", sending a reader to the README
# instead of to the six failures. It caught the problem by arithmetic accident.
suite_out="$(mktemp)"; trap 'rm -f "$suite_out"' EXIT
if ! bash "$root/tests/run-tests.sh" >"$suite_out" 2>&1; then
    bad "the test suite is RED; fix that before believing any number here"
    grep -E '^  FAIL' "$suite_out" | head -10 >&2
    exit 1
fi
# Passed PLUS skipped. The README claims a suite size, and a case skipped for a
# missing container runtime is still a case in the suite. Counting only passes
# meant a contributor with no podman measured one fewer test than the README
# says and was sent to edit the README.
tests_pass=$(sed -n 's/^ *\([0-9]\+\) passed.*/\1/p' "$suite_out" | tail -1)
tests_skip=$(sed -n 's/.*, \([0-9]\+\) skipped.*/\1/p' "$suite_out" | tail -1)
[ -n "$tests_pass" ] || { bad "could not measure the test count; refusing to pass over nothing"; exit 1; }
tests_actual=$(( tests_pass + ${tests_skip:-0} ))
[ -n "${tests_skip:-}" ] && note "counting $tests_pass passed + $tests_skip skipped as the suite size"
evals_actual=$(find "$root/evals/scenarios" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
backends_actual=$(find "$root/lib/backends" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
# Generated, then counted. Counting the spec would let a generator bug that
# drops every absolute spelling pass unnoticed.
#
# Every profile generates, not only the one the README quotes: a profile whose
# wall fails to render is a profile with no containment, and this check used to
# name profiles/sysknife and look no further.
gen_dir="$(mktemp -d)"; trap 'rm -rf "$gen_dir"' EXIT
for pdj in "$root"/profiles/*/deny.json; do
    pn="$(basename "$(dirname "$pdj")")"
    mkdir -p "$gen_dir/$pn"; cp "$pdj" "$gen_dir/$pn/"
    python3 "$root/scripts/render-settings.py" "$gen_dir/$pn" /home/claimcheck >/dev/null 2>&1 \
        || bad "profile '$pn' does not generate a deny wall"
    note "profile $pn: $(python3 -c "
import json;print(len(json.load(open('$gen_dir/$pn/settings.json'))['permissions']['deny']))" 2>/dev/null) rules"
done
cp "$root/profiles/sysknife/deny.json" "$gen_dir/" 2>/dev/null
python3 "$root/scripts/render-settings.py" "$gen_dir" /home/claimcheck >/dev/null 2>&1
# The VERB count, not the rule count. The generator resolves each verb with
# `which` and spells it from wherever the binary actually lives, so the number
# of rules depends on what is installed on the machine generating them: this
# check read 998 and then 1030 on the same tree, because installing the
# maintainer commands added a directory to spell from. A published number has to
# be derivable the same way twice, so the README pins the input a human writes
# and the rule count is printed as an observation.
deny_actual=$(python3 -c "
import json
d=json.load(open('$root/profiles/sysknife/deny.json'))
print(len(d.get('spelled_everywhere',[])) + len(d.get('bare_exact',[])))" 2>/dev/null)
[ -n "$deny_actual" ] || { bad "could not read the deny spec; refusing to pass over nothing"; exit 1; }
rules_here=$(python3 -c "
import json
print(len(json.load(open('$gen_dir/settings.json'))['permissions']['deny']))" 2>/dev/null)
note "those verbs generate $rules_here rules on this machine"

note "measured: $tests_actual tests, $evals_actual eval scenarios, $backends_actual backends, $deny_actual denied verbs"

# Every occurrence, not the first one, and the number may not be the tail of a
# longer token. The first-match version read "388 tests" out of the commit SHA
# in `maintainer-merge verify 365 7c6ed388 tests/e2e/...` and failed a commit
# over a number nobody had written. Taking only the first match also means a
# second, stale copy of a figure lower down is never checked at all.
claim() {  # $1 = regex capturing a number in README, $2 = actual, $3 = label
    local found seen uniq
    found=$(grep -oE "(^|[^0-9A-Za-z])$1" "$root/README.md" | grep -oE '[0-9]+' | sort -u)
    seen=$(printf '%s' "$found" | grep -c . || true)
    if [ "$seen" = 0 ]; then
        bad "README no longer states $3; the claim check now inspects nothing"
        return
    fi
    if [ "$seen" -gt 1 ]; then
        bad "README states $3 more than one way ($(printf '%s' "$found" | tr '\n' ' ')); they cannot all be right"
        return
    fi
    uniq="$found"
    if [ "$uniq" != "$2" ]; then
        bad "README says $uniq $3, the tree has $2"
    else
        note "ok: $3 = $2 (every mention agrees)"
    fi
}
claim '[0-9]+ (offline )?tests'     "$tests_actual"    "tests"
claim '[0-9]+ (adversarial )?eval'  "$evals_actual"    "eval scenarios"
claim '[0-9]+ denied verbs'         "$deny_actual"     "denied verbs"

exit "$fail"
