#!/usr/bin/env bash
# Hold the documents' numbers to what the tree actually contains.
#
# Same idea as the target repository's evidence artifact: a published figure
# must be derived, never typed. A README that claims 42 tests while the suite
# has 30 is the shape of defect this whole project exists to catch, and it
# would be embarrassing to ship it here. Every figure in the prose is a marker
# that scripts/render_figures.py renders from its source; this script runs the
# suite once, measures the test count, and hands that count to the renderer's
# check. It compares nothing itself, so there is one counting code path.
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
# The README states the VERB count, not the rule count: the generator resolves
# each verb with `which` and spells it from wherever the binary actually lives,
# so the number of rules depends on what is installed on the machine generating
# them (this check read 998 and then 1030 on the same tree). The verb count is
# derived by render_figures.py; the rule count is printed as an observation.
rules_here=$(python3 -c "
import json
print(len(json.load(open('$gen_dir/settings.json'))['permissions']['deny']))" 2>/dev/null)
note "those verbs generate $rules_here rules on this machine"

# Every figure, in every document, through the one renderer. It is handed the
# count measured above instead of running the suite a second time.
figs_out="$(python3 "$root/scripts/render_figures.py" --root "$root" --check --tests "$tests_actual" 2>&1)"; figs_rc=$?
if [ "$figs_rc" != 0 ]; then
    printf '%s\n' "$figs_out" >&2
    bad "a figure in the documents is stale, typed outside a marker, or unreadable; run scripts/render_figures.py --write"
else
    note "$figs_out"
    vals="$(python3 "$root/scripts/render_figures.py" --root "$root" --values --tests "$tests_actual" 2>&1)" \
        && note "measured: $(paste -sd, <<<"$vals" | sed 's/,/, /g')" \
        || { printf '%s\n' "$vals" >&2; bad "could not print the measured figures"; }
fi

exit "$fail"
