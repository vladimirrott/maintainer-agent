#!/usr/bin/env bash
# Tests of the differential recorder itself: the normaliser, compare.sh's exit
# codes, record.sh's refusals, and determinism over the real scenarios.
#
#   selftest.sh [--only SECTION[,SECTION]] [tree]
#
# tree defaults to the checkout this file sits in. Sections: normaliser, state,
# compare, record, gitenv, determinism. With no --only every section runs.
# Prints the number of checks that ran and exits non-zero on any failure, and on
# a full run that executed fewer checks than it should.
set -uo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
only=""
if [ "${1:-}" = "--only" ]; then only="${2:?--only needs a section list}"; shift 2; fi
tree="$(cd "${1:-$here/../..}" && pwd)"
want() { [ -z "$only" ] || case ",$only," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
# says LABEL OUTPUT TEXT: the refusal must name its own reason, because two
# different guards that both exit 2 would otherwise hide each other.
says() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 (no '$3' in: $2)"; fi; }

base="${MX_SCRATCH:-${XDG_CACHE_HOME:-$HOME/.cache}/magent-diff-scratch}"
mkdir -p "$base" || { echo "cannot create $base" >&2; exit 2; }
T="$(mktemp -d "$base/selftest.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
rec() { bash "$here/record.sh" "$@"; }
cmp_() { bash "$here/compare.sh" "$@"; }
tab=$'\t'

sec_normaliser() {
    echo "== normaliser rules =="
    local out rc rules name reason
    out="$(python3 -I "$here/normalise.py" selftest 2>&1)"; rc=$?
    check "every rule's own examples pass" "$rc" "0"
    if grep -q 'normalise selftest: [1-9][0-9]* rules, [1-9][0-9]* checks passed' <<<"$out"; then
        ok "and the count of checks is not zero ($out)"
    else bad "normaliser selftest ran no checks: $out"; fi
    rules="$(python3 -I "$here/normalise.py" rules)"; rc=$?
    check "rules lists every rule with a reason" "$rc" "0"
    while IFS=$'\t' read -r name reason; do
        if [ -n "$reason" ]; then ok "rule $name has a reason"; else bad "rule $name has no reason"; fi
    done <<<"$rules"
    out="$(printf 'tree /t/old/bin at 2026-11-09T01:02:03+00:00 in /w/x1/home pid 41\n' \
           | python3 -I "$here/normalise.py" filter --tree /t/old --work /w/x1)"
    check "filter applies paths and rules together" "$out" "tree <TREE>/bin at <TS> in <W>/home pid <PID>"
}

mkw() {  # $1 = work dir, $2 = tree path, $3 = one digit that differs between scenarios
    mkdir -p "$1"/{raw,stubs,home,state,tmp} "$1/repo"
    printf 'tree is %s at 2026-11-09T01:0%s:00+00:00\n' "$2" "$3" > "$1/raw/stdout"
    : > "$1/raw/stderr"; printf '0\n' > "$1/raw/rc"
    : > "$1/stubs/gh"
    printf 'prompt for %s\n' "$2" > "$1/tmp/tmp.aB3dE5gH7$3"
    printf '{"pid": 1%s, "started": 176269000%s}\n' "$3" "$3" > "$1/state/lease.json"
    ln -s "$2/bin/maintainer" "$1/home/link"
    mkfifo "$1/home/pipe"
    git -C "$1/repo" init -q -b main
    git -C "$1/repo" config user.email a@b; git -C "$1/repo" config user.name n
    printf 'x\n' > "$1/repo/f"; git -C "$1/repo" add f
    GIT_AUTHOR_DATE=2026-01-01T00:00:00+0000 GIT_COMMITTER_DATE=2026-01-01T00:00:00+0000 \
        git -C "$1/repo" commit -q -m one
}

sec_state() {
    echo "== the state writer is independent of where the scratch directory is =="
    local rc1 rc2 out rc
    mkw "$T/w1" /t/one/tree 1; mkw "$T/w2" /t/two/tree 2
    timeout 20 python3 -I "$here/normalise.py" finalise --work "$T/w1" --tree /t/one/tree --out "$T/f1"; rc1=$?
    timeout 20 python3 -I "$here/normalise.py" finalise --work "$T/w2" --tree /t/two/tree --out "$T/f2"; rc2=$?
    check "finalise runs on both synthetic scenarios" "$rc1$rc2" "00"
    mkdir -p "$T/cmp1/s" "$T/cmp2/s"; cp -a "$T/f1/." "$T/cmp1/s/"; cp -a "$T/f2/." "$T/cmp2/s/"
    echo 1 > "$T/cmp1/.complete"; echo 1 > "$T/cmp2/.complete"
    out="$(cmp_ "$T/cmp1" "$T/cmp2" 2>&1)"; rc=$?
    check "scenarios that differ only by path, time, pid and random names compare equal (rc)" "$rc" "0"
    if grep -q 'identical: 1 scenarios' <<<"$out"; then ok "and compare says so: $out"; else bad "unexpected compare output: $out"; fi
    if grep -q 'tmp/tmp.<RAND>' "$T/f1/state.tree"; then ok "the random temp name is a token in state.tree"; else bad "state.tree kept the random temp name"; fi
    if grep -q "^home/link${tab}l${tab}" "$T/f1/state.tree"; then ok "a symlink is recorded as kind l"; else bad "state.tree lost the symlink"; fi
    if grep -q "^home/pipe${tab}o${tab}" "$T/f1/state.tree"; then ok "a fifo is recorded without being read"; else bad "state.tree lost the fifo or hung on it"; fi
    if grep -q "^repo/@git-summary${tab}g${tab}" "$T/f1/state.tree"; then ok "a repository is recorded through git, not its raw .git files"; else bad "no git summary in state.tree"; fi
    if grep -qE '^(stubs|realbin|raw)' "$T/f1/state.tree"; then bad "harness directories leaked into state.tree"; else ok "stubs, realbin and raw are not part of the state tree"; fi
    if [ -f "$T/f1/argv.gh.log" ] && [ ! -s "$T/f1/argv.gh.log" ]; then ok "an unused stub still gets an empty argv log"; else bad "argv.gh.log missing"; fi
}

mk_res() {  # $1 = dir, $2 = scenario, $3 = stdout text
    mkdir -p "$1/$2/state.files"
    printf '0\n' > "$1/$2/rc"; printf '%s\n' "$3" > "$1/$2/stdout"; : > "$1/$2/stderr"; : > "$1/$2/state.tree"
    find "$1" -mindepth 1 -maxdepth 1 -type d | wc -l > "$1/.complete"
}

sec_compare() {
    echo "== compare.sh exit codes =="
    local out rc
    mk_res "$T/a" s1 hello; mk_res "$T/b" s1 hello
    out="$(cmp_ "$T/a" "$T/b" 2>&1)"; rc=$?
    check "identical results exit 0" "$rc" "0"
    mk_res "$T/c" s1 goodbye
    out="$(cmp_ "$T/a" "$T/c" 2>&1)"; rc=$?
    check "a differing field exits 1" "$rc" "1"
    if grep -q 'DIFF scenario=s1 field=stdout' <<<"$out" && grep -q '^-hello' <<<"$out" && grep -q '^+goodbye' <<<"$out"; then
        ok "and the report names the scenario and field and shows the unified diff"
    else bad "compare report is wrong: $out"; fi
    mk_res "$T/d" s1 hello; mk_res "$T/d" s2 extra
    out="$(cmp_ "$T/a" "$T/d" 2>&1)"; rc=$?
    check "a scenario present on one side only exits 1" "$rc" "1"
    if grep -q 'DIFF scenario=s2 field=<scenario> missing in old' <<<"$out"; then ok "and it says which side lacks it"; else bad "missing scenario not named: $out"; fi
    mk_res "$T/e" s1 hello; printf 'argv: pr view 1\n' > "$T/e/s1/argv.gh.log"
    out="$(cmp_ "$T/a" "$T/e" 2>&1)"; rc=$?
    check "an argv log present on one side only exits 1" "$rc" "1"
    if grep -q 'DIFF scenario=s1 field=argv.gh.log' <<<"$out"; then ok "and names the argv field"; else bad "argv field not named: $out"; fi
    mk_res "$T/h" s1 hello; mkdir -p "$T/h/s1/state.files/home"; printf 'one\n' > "$T/h/s1/state.files/home/f"
    mk_res "$T/i" s1 hello; mkdir -p "$T/i/s1/state.files/home"; printf 'two\n' > "$T/i/s1/state.files/home/f"
    out="$(cmp_ "$T/h" "$T/i" 2>&1)"; rc=$?
    check "a state file that differs exits 1" "$rc" "1"
    if grep -q 'DIFF scenario=s1 field=state.files/home/f' <<<"$out"; then ok "and names the state file"; else bad "state file not named: $out"; fi
    out="$(cmp_ "$T/does-not-exist" "$T/b" 2>&1)"; rc=$?
    check "a missing old directory exits 2" "$rc" "2"
    says "and says it does not exist" "$out" "does not exist"
    out="$(cmp_ "$T/a" "$T/does-not-exist" 2>&1)"; rc=$?
    check "a missing new directory exits 2" "$rc" "2"
    says "and names it as the new one" "$out" "new result directory"
    mkdir -p "$T/notdir"; : > "$T/notdir/file"
    out="$(cmp_ "$T/notdir/file" "$T/b" 2>&1)"; rc=$?
    check "a result that is a file exits 2" "$rc" "2"
    says "and says it is not a directory" "$out" "is not a directory"
    mkdir -p "$T/empty"; echo 0 > "$T/empty/.complete"
    out="$(cmp_ "$T/empty" "$T/empty" 2>&1)"; rc=$?
    check "an empty directory compared with itself exits 2, never 0" "$rc" "2"
    says "and says it holds no scenarios" "$out" "holds no scenario directories"
    mkdir -p "$T/bare"
    out="$(cmp_ "$T/bare" "$T/bare" 2>&1)"; rc=$?
    check "a directory with no .complete marker exits 2" "$rc" "2"
    says "and says the recording is unfinished" "$out" "no .complete marker"
    mk_res "$T/f" s1 hello; echo 5 > "$T/f/.complete"
    out="$(cmp_ "$T/f" "$T/b" 2>&1)"; rc=$?
    check "a marker count that does not match the scenarios exits 2" "$rc" "2"
    says "and says what the marker claims" "$out" "says 5 scenarios but holds 1"
    mk_res "$T/k" s1 hello; echo abc > "$T/k/.complete"
    out="$(cmp_ "$T/k" "$T/b" 2>&1)"; rc=$?
    check "a marker that is not a number exits 2" "$rc" "2"
    says "and calls the count bad" "$out" "bad .complete count"
    mk_res "$T/g" s1 hello; rm "$T/g/s1/rc"
    out="$(cmp_ "$T/g" "$T/b" 2>&1)"; rc=$?
    check "a scenario with no rc file exits 2" "$rc" "2"
    says "and names the scenario" "$out" "scenario 's1' has no rc file"
    mk_res "$T/j" s1 hello; : > "$T/j/s1/unreadable"; chmod 000 "$T/j/s1/unreadable"
    if [ "$(id -u)" = 0 ]; then
        printf '  SKIP  an unreadable field exits 2 (running as root, chmod does not block)\n'
    else
        out="$(cmp_ "$T/j" "$T/b" 2>&1)"; rc=$?
        check "a field diff cannot read exits 2, never 1" "$rc" "2"
        says "and says diff failed" "$out" "diff failed on s1/unreadable"
    fi
    chmod 644 "$T/j/s1/unreadable"
    out="$(cmp_ "$T/a" 2>&1)"; rc=$?
    check "the wrong number of arguments exits 2" "$rc" "2"
    says "and prints the usage" "$out" "usage: compare.sh"
}

sec_record() {
    echo "== record.sh refuses to produce a result that means nothing =="
    local out rc one="$T/one.sh"
    printf '#!/usr/bin/env bash\nmx_merge_env\nmx_run bin/maintainer-merge show 1\n' > "$one"
    out="$(rec "$tree" "$one" "$T/o-ok" 2>&1)"; rc=$?
    check "a one-scenario recording succeeds" "$rc" "0"
    if [ -f "$T/o-ok/.complete" ] && [ "$(cat "$T/o-ok/.complete")" = 1 ]; then ok "and writes the .complete marker with the count"; else bad "no .complete marker"; fi
    if grep -q 'recorded 1 scenarios' <<<"$out"; then ok "and prints how many scenarios ran"; else bad "no scenario count: $out"; fi
    out="$(rec "$tree" "$one" "$T/o-ok" 2>&1)"; rc=$?
    check "an out-dir that already holds a result exits 2" "$rc" "2"
    says "and says to remove it" "$out" "is not empty"
    printf '#!/usr/bin/env bash\nmx_merge_env\n' > "$T/none.sh"
    out="$(rec "$tree" "$T/none.sh" "$T/o-none" 2>&1)"; rc=$?
    check "a scenario that never runs a program exits 2" "$rc" "2"
    if grep -q 'no mx_run' <<<"$out"; then ok "and says why"; else bad "reason missing: $out"; fi
    printf '#!/usr/bin/env bash\nmx_run bin/maintainer-merge show 1\nmx_run bin/maintainer-merge show 2\n' > "$T/two.sh"
    out="$(rec "$tree" "$T/two.sh" "$T/o-two" 2>&1)"; rc=$?
    check "a scenario that runs two programs exits 2" "$rc" "2"
    says "and says only one is allowed" "$out" "exactly one program invocation"
    mkdir -p "$T/noscen"
    out="$(rec "$tree" "$T/noscen" "$T/o-noscen" 2>&1)"; rc=$?
    check "a scenario directory with no scenarios exits 2" "$rc" "2"
    says "and says there are none" "$out" "no scenarios"
    out="$(rec "$T/noscen" "$one" "$T/o-badtree" 2>&1)"; rc=$?
    check "a directory that is not a magent tree exits 2" "$rc" "2"
    says "and says so" "$out" "is not a magent tree"
    printf '#!/usr/bin/env bash\nmx_run bin/does-not-exist\n' > "$T/missing.sh"
    out="$(rec "$tree" "$T/missing.sh" "$T/o-missing" 2>&1)"; rc=$?
    check "a program that is not in the tree exits 2" "$rc" "2"
    says "and names it" "$out" "bin/does-not-exist is not an executable file"
    printf '#!/usr/bin/env bash\nfalse\nmx_run bin/maintainer-merge show 1\n' > "$T/setupfail.sh"
    out="$(rec "$tree" "$T/setupfail.sh" "$T/o-setupfail" 2>&1)"; rc=$?
    check "a failing setup command exits 2 instead of recording a half-built scenario" "$rc" "2"
    says "and reports the failure as a setup failure" "$out" "failed in setup or harness"
    if [ -e "$T/o-setupfail/setupfail" ]; then bad "a half-built scenario left a result directory"; else ok "and leaves no result directory for it"; fi
    mkdir -p "$T/hangtree/bin" "$T/hangtree/lib" "$T/hangtree/profiles"
    printf '#!/usr/bin/env bash\nsleep 30\n' > "$T/hangtree/bin/slow"; chmod +x "$T/hangtree/bin/slow"
    printf '#!/usr/bin/env bash\nmx_run bin/slow\n' > "$T/slow.sh"
    out="$(MX_TIMEOUT=1 rec "$T/hangtree" "$T/slow.sh" "$T/o-slow" 2>&1)"; rc=$?
    check "a program that hangs past the timeout exits 2, not a recorded 124" "$rc" "2"
    if grep -q 'timed out' <<<"$out"; then ok "and the message says it timed out"; else bad "timeout not named: $out"; fi
    mkdir -p "$T/modtree/bin" "$T/modtree/lib" "$T/modtree/profiles"
    printf '#!/usr/bin/env bash\necho changed >> "$(dirname "$(readlink -f "$0")")/../lib/touched"\n' > "$T/modtree/bin/writer"
    chmod +x "$T/modtree/bin/writer"
    printf '#!/usr/bin/env bash\nmx_run bin/writer\n' > "$T/writer.sh"
    out="$(rec "$T/modtree" "$T/writer.sh" "$T/o-writer" 2>&1)"; rc=$?
    check "a program that writes into the tree under test exits 2" "$rc" "2"
    if grep -q 'changed files under the tree' <<<"$out"; then ok "and the message names the tree"; else bad "tree change not named: $out"; fi
    mkdir -p "$T/rc3tree/bin" "$T/rc3tree/lib" "$T/rc3tree/profiles"
    printf '#!/usr/bin/env bash\necho out; echo err >&2; exit 3\n' > "$T/rc3tree/bin/rc3"; chmod +x "$T/rc3tree/bin/rc3"
    printf '#!/usr/bin/env bash\nmx_run bin/rc3\n' > "$T/rc3run.sh"
    out="$(rec "$T/rc3tree" "$T/rc3run.sh" "$T/o-rc3" 2>&1)"; rc=$?
    check "a program that exits 3 is data: the recording succeeds" "$rc" "0"
    check "and rc holds 3" "$(cat "$T/o-rc3/rc3run/rc")" "3"
    check "and stdout and stderr are kept apart" "$(cat "$T/o-rc3/rc3run/stdout")|$(cat "$T/o-rc3/rc3run/stderr")" "out|err"
}

sec_gitenv() {
    echo "== the scenarios are not influenced by the caller's git variables =="
    local decoy="$T/decoy.git" before out rc
    git init -q --bare "$decoy"
    snap() { { cat "$decoy/config" "$decoy/HEAD"; find "$decoy" -type f -printf '%P\n' | LC_ALL=C sort; } | sha256sum; }
    before="$(snap)"
    out="$(GIT_DIR="$decoy" GIT_INDEX_FILE="$decoy/index" GIT_WORK_TREE="$T" \
           rec "$tree" "$here/scenarios/repo-prune-dry-run.sh" "$T/o-decoy" 2>&1)"; rc=$?
    check "a recording under a decoy GIT_DIR succeeds" "$rc" "0"
    check "and leaves the decoy repository byte for byte as it was" "$(snap)" "$before"
    if grep -q 'would delete feature-done' "$T/o-decoy/repo-prune-dry-run/stdout"; then
        ok "and the scenario still ran against its own repository"
    else bad "the decoy changed what the scenario saw"; fi
}

sec_determinism() {
    echo "== determinism: two recordings of the same tree compare equal =="
    local n out rc
    n="$(find "$here/scenarios" -maxdepth 1 -type f -name '*.sh' | wc -l)"
    if [ "$n" -ge 14 ]; then ok "there are $n scenarios (at least 14)"; else bad "only $n scenarios"; fi
    out="$(rec "$tree" "$here/scenarios" "$T/r1" 2>&1)"; rc=$?
    check "first full recording succeeds" "$rc" "0"
    if grep -q "recorded $n scenarios" <<<"$out"; then ok "and it ran all $n scenarios"; else bad "scenario count mismatch: $out"; fi
    out="$(rec "$tree" "$here/scenarios" "$T/r2" 2>&1)"; rc=$?
    check "second full recording succeeds" "$rc" "0"
    out="$(cmp_ "$T/r1" "$T/r2" 2>&1)"; rc=$?
    check "the two recordings have zero differences" "$rc" "0"
    if grep -q "identical: $n scenarios" <<<"$out"; then ok "$out"; else bad "compare summary wrong: $out"; fi
}

for s in normaliser state compare record gitenv determinism; do
    if want "$s"; then "sec_$s"; fi
done
echo
printf '%d checks passed, %d failed\n' "$pass" "$fail"
if [ -z "$only" ] && [ "$pass" -lt 85 ]; then echo "only $pass checks ran; a full run has at least 85" >&2; exit 1; fi
[ "$pass" -gt 0 ] || { echo "no check ran" >&2; exit 1; }
[ "$fail" -eq 0 ]
