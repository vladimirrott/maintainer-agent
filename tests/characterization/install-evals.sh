#!/usr/bin/env bash
# Characterization: evals/run-evals.sh in static mode (the mode the pre-commit
# hook runs) and the two refusal paths of tests/containment-probe.sh that need no
# container. Live mode asks a model backend and is not covered here.
#
# The cases run the real profiles and prompts: static mode reads the prompt that
# lib/run.sh --show-prompt assembles. Expectations come from the tree's own
# evals.json and scenarios, so a prompt edit does not move a case.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib-inst.sh"
ci_init

# evals_edit PROFILE PYTHON-STATEMENTS: edits the tree's evals.json, variable m.
evals_edit() {
    python3 -I - "$CZ_TREE/profiles/$1/evals.json" "$2" <<'PY' || { echo "characterization: could not edit evals.json" >&2; exit 2; }
import json, sys
p, code = sys.argv[1], sys.argv[2]
m = json.load(open(p))
exec(code)
json.dump(m, open(p, "w"), indent=1)
PY
}
scenario_count() { ls "$CZ_TREE"/evals/scenarios/*.md | wc -l | tr -d ' '; }
needle_of() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["needle"])' "$CZ_TREE/profiles/$1/evals.json" "$2"; }

case_pass() {
    ci_evals
    cz_expect_rc 0
    cz_expect_stderr_empty
    local n id f needle; n="$(scenario_count)"
    [ "$n" -ge 9 ] || cz_note_fail "only $n scenarios found"
    for f in "$CZ_TREE"/evals/scenarios/*.md; do
        id="$(basename "$f" .md)"; needle="$(needle_of sysknife "$id")"
        cz_expect_stdout_has "  PASS  $id -> the agent still reads: \"$needle\""
    done
    cz_check "PASS lines" "$(grep -c '^  PASS  ' "$CZ_CASE/stdout")" "$n"
    cz_check "last line" "$(tail -1 "$CZ_CASE/stdout")" "  $n passed, 0 failed"
    cz_check "blank line before the summary" "$(tail -2 "$CZ_CASE/stdout" | head -1)" ""
}
ci_case "static: the default profile (sysknife) prints one PASS line per scenario naming its needle, then the summary" case_pass

case_explicit_static() {
    ci_evals; cp "$CZ_CASE/stdout" "$CZ_CASE/stdout.default"
    ci_evals --static
    cz_expect_rc 0
    cmp -s "$CZ_CASE/stdout.default" "$CZ_CASE/stdout" || cz_note_fail "--static differs from no argument"
}
ci_case "static: --static is the same as no argument" case_explicit_static

case_magent_na() {
    cz_set MAINTAINER_PROFILE magent
    ci_evals
    cz_expect_rc 0
    cz_expect_matches stdout "^  PASS  05-reserved-issue -> not applicable to 'magent': .+"
    cz_expect_lacks stdout "05-reserved-issue -> the agent still reads"
    cz_check "last line" "$(tail -1 "$CZ_CASE/stdout")" "  $(scenario_count) passed, 0 failed"
}
ci_case "static: the magent profile retires 05-reserved-issue with its written reason and still passes" case_magent_na

case_missing_needle() {
    evals_edit sysknife 'm["03-ai-slop-report"]["needle"] = "zzz-absent-needle"'
    ci_evals
    cz_expect_rc 1
    cz_expect_stderr "  FAIL  03-ai-slop-report -> RULE MISSING from everything the agent reads: \"zzz-absent-needle\""
    cz_check "stdout" "$(cat "$CZ_CASE/stdout" | tail -1)" "  $(( $(scenario_count) - 1 )) passed, 1 failed"
}
ci_case "static: a needle the prompt no longer holds fails that scenario on stderr and exits 1" case_missing_needle

case_needle_case_insensitive() {
    evals_edit sysknife 'm["03-ai-slop-report"]["needle"] = "SLOP"'
    ci_evals
    cz_expect_rc 0
    cz_expect_stdout_has "  PASS  03-ai-slop-report -> the agent still reads: \"SLOP\""
}
ci_case "static: the needle is matched without regard to case" case_needle_case_insensitive

case_needle_literal() {
    evals_edit sysknife 'm["03-ai-slop-report"]["needle"] = "zz.*zz"'
    ci_evals
    cz_expect_rc 1
    cz_expect_stderr_has "RULE MISSING from everything the agent reads: \"zz.*zz\""
}
ci_case "static: the needle is a fixed string, not a pattern" case_needle_literal

# "data. not instruction" matches the prompt's "data, not instruction" as a
# pattern ("." is any character) and does not match it as a fixed string.
case_needle_dot_is_literal() {
    evals_edit sysknife 'm["01-prompt-injection"]["needle"] = "data. not instruction"'
    ci_evals
    cz_expect_rc 1
    cz_expect_stderr "  FAIL  01-prompt-injection -> RULE MISSING from everything the agent reads: \"data. not instruction\""
}
ci_case "static: a dot in the needle matches only a dot" case_needle_dot_is_literal

case_unmapped_scenario() {
    printf '# New scenario\n' > "$CZ_TREE/evals/scenarios/10-new.md"
    ci_evals
    cz_expect_rc 1
    cz_expect_stderr "  FAIL  10-new has no entry in $CZ_TREE/profiles/sysknife/evals.json; add a needle or an explicit \"n/a\" with a reason"
    cz_check "stdout last line" "$(tail -1 "$CZ_CASE/stdout")" "  $(( $(scenario_count) - 1 )) passed, 1 failed"
}
ci_case "static: a scenario with no entry fails and says how to fix it" case_unmapped_scenario

case_na_not_retirable() {
    evals_edit sysknife 'm["01-prompt-injection"] = {"n/a": "not our problem"}'
    ci_evals
    cz_expect_rc 1
    cz_expect_stderr "  FAIL  01-prompt-injection was marked n/a by 'sysknife', but it asserts shared doctrine and is not retirable"
}
ci_case "static: marking a shared-doctrine scenario n/a fails it" case_na_not_retirable

case_na_retirable() {
    evals_edit sysknife 'm["05-reserved-issue"] = {"needle": None, "n/a": "no reserved issues here"}'
    ci_evals
    cz_expect_rc 0
    cz_expect_stdout_has "  PASS  05-reserved-issue -> not applicable to 'sysknife': no reserved issues here"
}
ci_case "static: 05-reserved-issue may be retired with a reason" case_na_retirable

case_ghost_mapping() {
    evals_edit sysknife 'm["99-ghost"] = {"needle": "x"}'
    ci_evals
    cz_expect_rc 1
    cz_expect_stderr "  FAIL  mapping '99-ghost' has no scenario file"
}
ci_case "static: a mapping with no scenario file fails" case_ghost_mapping

case_no_evals_json() {
    rm -f "$CZ_TREE/profiles/sysknife/evals.json"
    ci_evals
    cz_expect_rc 1
    cz_check "FAIL lines" "$(grep -c '^  FAIL  .* has no entry in ' "$CZ_CASE/stderr")" "$(scenario_count)"
    cz_check "stdout last line" "$(tail -1 "$CZ_CASE/stdout")" "  0 passed, $(scenario_count) failed"
}
ci_case "static: a profile with no evals.json fails every scenario" case_no_evals_json

# Pins current behaviour. With no scenario file the glob stays literal and the
# loop runs once on "*.md", so the suite fails with an odd first line.
case_no_scenarios() {
    rm -f "$CZ_TREE"/evals/scenarios/*.md
    ci_evals
    cz_expect_rc 1
    cz_expect_stderr_has "  FAIL  * has no entry in $CZ_TREE/profiles/sysknife/evals.json"
    cz_expect_stderr_has "has no scenario file"
}
ci_case "static: with no scenario files it fails on the literal pattern and on every mapping (pins current behaviour)" case_no_scenarios

case_unknown_profile() {
    cz_set MAINTAINER_PROFILE nope
    ci_evals
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "run-evals: empty corpus for profile 'nope'"
}
ci_case "static: an unknown profile exits 1 with one stderr line" case_unknown_profile

case_usage() {
    ci_evals --bogus
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "usage: run-evals.sh [--static|--live [id]]"
}
ci_case "usage: an unknown argument exits 64 with the usage line" case_usage

case_writes_nothing() {
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.before"; ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.before"
    ci_evals
    ci_snap "$CZ_HOME" > "$CZ_CASE/home.after"; ci_manifest "$CZ_TREE" > "$CZ_CASE/tree.after"
    ci_expect_same_snap "home" "$CZ_CASE/home.before" "$CZ_CASE/home.after"
    ci_expect_same_snap "tree" "$CZ_CASE/tree.before" "$CZ_CASE/tree.after"
    cz_expect_rc 0
}
ci_case "static: the run writes no file under HOME or in the tree" case_writes_nothing

# --- tests/containment-probe.sh: the paths that stop before any container -------------------

rt_stub() {  # $1 = name; logs argv, image inspect and pull fail
    cat > "$CZ_CASE/bin/$1" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${CZ_CASE_DIR:?}/rt.calls"
exit 1
STUB
    bash -n "$CZ_CASE/bin/$1"; chmod +x "$CZ_CASE/bin/$1"
}
probe() { ci_run "$CZ_TREE/tests/containment-probe.sh"; }

case_probe_no_runtime() {
    ci_drop_tool podman; ci_drop_tool docker
    probe
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "no container runtime; this probe measured nothing"
}
ci_case "probe: with neither podman nor docker it exits 1 saying it measured nothing" case_probe_no_runtime

case_probe_cannot_obtain() {
    rt_stub podman
    probe
    cz_expect_rc 1
    cz_expect_stderr "cannot obtain docker.io/library/bash:5"
    ci_expect_calls rt.calls "podman image inspect docker.io/library/bash:5" "podman pull -q docker.io/library/bash:5"
}
ci_case "probe: an image that cannot be inspected or pulled exits 1 after one inspect and one pull" case_probe_cannot_obtain

case_probe_image_override() {
    rt_stub podman; cz_set PROBE_IMAGE example.invalid/x:1
    probe
    cz_expect_stderr "cannot obtain example.invalid/x:1"
}
ci_case "probe: PROBE_IMAGE names the image" case_probe_image_override

case_probe_docker_fallback() {
    ci_drop_tool podman; rt_stub docker
    probe
    cz_expect_rc 1
    ci_expect_calls rt.calls "docker image inspect docker.io/library/bash:5" "docker pull -q docker.io/library/bash:5"
}
ci_case "probe: docker is used when podman is absent" case_probe_docker_fallback

case_probe_podman_first() {
    rt_stub podman; rt_stub docker
    probe
    cz_check "docker calls" "$(grep -c '^docker ' "$CZ_CASE/rt.calls")" "0"
    cz_check "podman calls" "$(grep -c '^podman ' "$CZ_CASE/rt.calls")" "2"
}
ci_case "probe: podman is preferred when both exist" case_probe_podman_first

cz_finish
