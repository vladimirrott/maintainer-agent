#!/usr/bin/env bash
# Shows the recorder bites. Written for the bash tree, whose source lines the
# mutants edit; a mutant whose line is missing stops the script before any edit.
#
#   prove.sh [tree]
#
# Part 1: four one-behaviour mutants in a COPY of the tree (a usage line, an exit
#   code, a gh argv order, a stderr word). compare.sh must exit 1 and name the
#   scenario and field. The copy is then restored from a pristine copy and must
#   compare equal again, with the sha256 of each mutated file checked.
# Part 2: remove one normaliser rule from a COPY of this harness. Two recordings
#   of the same content must then differ, which shows the rule was needed.
set -uo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
tree="$(cd "${1:-$here/../..}" && pwd)"
die() { printf 'prove.sh: %s\n' "$1" >&2; exit 2; }
failures=0
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$1" >&2; }
pass() { printf '  PASS  %s\n' "$1"; }

base="${MX_SCRATCH:-${XDG_CACHE_HOME:-$HOME/.cache}/magent-diff-scratch}"
mkdir -p "$base" || die "cannot create $base"
T="$(mktemp -d "$base/prove.XXXXXX")" || die "cannot create scratch"
trap 'rm -rf "$T"' EXIT

copy_tree() { mkdir -p "$2" && tar -C "$1" --exclude=./.git -cf - . | tar -C "$2" -xf -; }
copy_tree "$tree" "$T/pristine" || die "cannot copy the tree"
copy_tree "$tree" "$T/work" || die "cannot copy the tree"
touch_all() { find "$1" -type f -exec touch {} +; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }

echo "== part 1: a one-line behaviour change in a copy of the tree is detected =="
touch_all "$T/work"
out="$(bash "$here/record.sh" "$T/work" "$here/scenarios" "$T/base" 2>&1)" || die "baseline recording failed: $out"
n_scen="$(sed -n 's/^recorded \([0-9]*\) scenarios.*/\1/p' <<<"$out")"
[ "${n_scen:-0}" -gt 0 ] || die "baseline ran no scenarios: $out"
printf '  baseline: %s scenarios recorded from the copy\n' "$n_scen"

# file | needle | replacement | scenario that must differ | field that must differ
mutants=(
'bin/maintainer-merge|usage: maintainer-merge {verify <pr>|usage: maintainer-merge {verfy <pr>|merge-usage-no-args|stderr'
'bin/maintainer-merge|exit 64 ;;|exit 65 ;;|merge-usage-no-args|rc'
'bin/maintainer-merge|gh auth switch --hostname github.com --user "$ACCOUNT"|gh auth switch --user "$ACCOUNT" --hostname github.com|merge-refused-no-receipt|argv.gh.log'
'bin/maintainer-merge|no verification receipt for|no verification certificate for|merge-refused-no-receipt|stderr'
)
caught=0; i=0
for m in "${mutants[@]}"; do
    i=$((i + 1))
    IFS='|' read -r file needle repl want_scn want_field <<<"$m"
    # Every assertion comes before the first edit.
    hits="$(grep -cF -- "$needle" "$T/work/$file")"
    [ "$hits" = 1 ] || die "mutant $i: '$needle' occurs $hits times in $file, not once"
    [ -z "$(grep -F -- "$repl" "$T/work/$file" | head -1)" ] || die "mutant $i: replacement text already present"
    before_sha="$(sha "$T/work/$file")"
    [ "$before_sha" = "$(sha "$T/pristine/$file")" ] || die "mutant $i: the copy is not pristine"
    NEEDLE="$needle" REPL="$repl" python3 -I - "$T/work/$file" <<'PYEOF' || die "mutant $i: the edit script failed"
import os, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle, repl = os.environ["NEEDLE"], os.environ["REPL"]
assert s.count(needle) == 1
open(p, "w", encoding="utf-8").write(s.replace(needle, repl))
PYEOF
    # Read it back: the mutation must be there and the original line gone.
    [ "$(grep -cF -- "$repl" "$T/work/$file")" = 1 ] || die "mutant $i did not land"
    [ "$(grep -cF -- "$needle" "$T/work/$file")" = 0 ] || die "mutant $i left the original line"
    [ "$(sha "$T/work/$file")" != "$before_sha" ] || die "mutant $i did not change the file"
    touch_all "$T/work"
    out="$(bash "$here/record.sh" "$T/work" "$here/scenarios" "$T/m$i" 2>&1)" || die "mutant $i recording failed: $out"
    rep="$(bash "$here/compare.sh" "$T/base" "$T/m$i" 2>&1)"; rc=$?
    if [ "$rc" = 1 ] && grep -q "^DIFF scenario=$want_scn field=$want_field\$" <<<"$rep"; then
        caught=$((caught + 1))
        pass "mutant $i detected: $(grep -c '^DIFF scenario=' <<<"$rep") differing field(s), including scenario=$want_scn field=$want_field"
        grep '^DIFF scenario=' <<<"$rep" | sed 's/^/          /'
    else
        fail "mutant $i ($want_scn/$want_field) not detected (compare exit $rc)"
    fi
    cp "$T/pristine/$file" "$T/work/$file" || die "cannot restore $file"
    [ "$(sha "$T/work/$file")" = "$before_sha" ] || die "restore of $file does not match the pristine sha256"
done
printf '  %d of %d mutants detected\n' "$caught" "${#mutants[@]}"
touch_all "$T/work"
bash "$here/record.sh" "$T/work" "$here/scenarios" "$T/after" >/dev/null 2>&1 || die "recording after the restore failed"
rep="$(bash "$here/compare.sh" "$T/base" "$T/after" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then pass "after restoring from the pristine copy the recording compares equal: $rep"; else fail "restore left a difference (exit $rc): $rep"; fi

echo "== part 2: removing one normaliser rule makes two recordings of the same content differ =="
mkdir -p "$T/subset"
for s in run-show-prompt-magent-review verify-refused-unknown-suite doctor-broken-no-deny-json repo-prune-dry-run; do
    cp "$here/scenarios/$s.sh" "$T/subset/" || die "no scenario $s"
done
# rule | what to edit | tree for the second recording
bites=("iso-timestamp|rule|same" "mktemp-file|rule|same" "work-path|work|same" "tree-path|tree|other")
bit=0
for b in "${bites[@]}"; do
    IFS='|' read -r rule kind second <<<"$b"
    h="$T/harness-$rule"; mkdir -p "$h"; cp -a "$here/." "$h/"
    RULE="$rule" KIND="$kind" python3 -I - "$h/normalise.py" <<'PYEOF' || die "cannot edit the harness copy for $rule"
import os, re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
rule, kind = os.environ["RULE"], os.environ["KIND"]
if kind == "rule":
    m = re.search(r'    Rule\("%s",.*?(?=\n    Rule\(|\n\]\n)' % re.escape(rule), s, re.S)
    assert m, "rule %s not found" % rule
    s = s.replace(m.group(0) + "\n", "", 1)
else:
    token = {"work": "WORK_TOKEN", "tree": "TREE_TOKEN"}[kind]
    old = "        for path, token in self.paths:\n"
    new = "        for path, token in [x for x in self.paths if x[1] != %s]:\n" % token
    assert s.count(old) == 1
    s = s.replace(old, new)
open(p, "w", encoding="utf-8").write(s)
PYEOF
    if [ "$kind" = rule ]; then
        have="$(python3 -I "$h/normalise.py" rules | cut -f1 | grep -cx "$rule")"
        [ "$have" = 0 ] || die "rule $rule is still listed in the harness copy"
    fi
    src=0; python3 -I "$h/normalise.py" selftest >/dev/null 2>&1 || src=$?
    if [ "$kind" = rule ]; then
        [ "$src" = 0 ] || die "harness copy is broken: its selftest exits $src"
    elif [ "$src" != 0 ]; then
        pass "the path-map unit cases in normalise.py selftest also go red (exit $src)"
    else
        fail "removing the $rule path map left normalise.py selftest green"
    fi
    other_tree="$T/work"; [ "$second" = other ] && other_tree="$T/pristine"
    touch_all "$T/work"; touch_all "$T/pristine"
    o1="$T/b1-$rule"; o2="$T/b2-$rule"
    bash "$h/record.sh" "$T/work" "$T/subset" "$o1" >/dev/null 2>&1 || die "recording 1 with $rule removed failed"
    sleep 1
    bash "$h/record.sh" "$other_tree" "$T/subset" "$o2" >/dev/null 2>&1 || die "recording 2 with $rule removed failed"
    rep="$(bash "$h/compare.sh" "$o1" "$o2" 2>&1)"; rc=$?
    if [ "$rc" = 1 ]; then
        bit=$((bit + 1))
        pass "without rule $rule two recordings differ ($(grep -c '^DIFF scenario=' <<<"$rep") field(s)); the rule was needed"
        grep '^DIFF scenario=' <<<"$rep" | head -4 | sed 's/^/          /'
    else
        fail "removing rule $rule changed nothing (compare exit $rc): the rule is not needed by any scenario"
    fi
    # Control: the unmodified harness over the same two trees must be equal.
    bash "$here/record.sh" "$T/work" "$T/subset" "$T/c1-$rule" >/dev/null 2>&1 || die "control recording 1 failed"
    bash "$here/record.sh" "$other_tree" "$T/subset" "$T/c2-$rule" >/dev/null 2>&1 || die "control recording 2 failed"
    rep="$(bash "$here/compare.sh" "$T/c1-$rule" "$T/c2-$rule" 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then pass "with the rule in place the same two recordings compare equal"; else fail "control differs (exit $rc): $rep"; fi
done
printf '  %d of %d tested rules proved needed\n' "$bit" "${#bites[@]}"
python3 -I "$here/normalise.py" rules | cut -f1 | while read -r r; do
    case "$r" in
        iso-timestamp|mktemp-file|work-path|tree-path) ;;
        *) printf '  note: rule %s is checked by its unit examples only; no current scenario needs it\n' "$r" ;;
    esac
done

[ "$failures" -eq 0 ] && echo "prove.sh: every proof holds" || echo "prove.sh: $failures proof(s) failed" >&2
[ "$failures" -eq 0 ]
