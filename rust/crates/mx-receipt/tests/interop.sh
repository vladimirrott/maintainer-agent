#!/usr/bin/env bash
# Interop between the bash merge gate and the Rust receipt crate, both ways.
#
#   (a) The bash gate writes receipts. mx-receipt-interop must verify each one,
#       and write it back to the same bytes.
#   (b) mx-receipt-interop writes receipts. The gate's own `receipt_check`
#       (sourced from bin/maintainer-merge) must accept each one, `show` must
#       print the same bytes, and `receipt_suites` and the `partial` field must
#       read what the crate reads.
#   (c) Controls: a receipt that was edited, reordered, unsigned, copied to the
#       wrong pull request, or asserted under an unattended run is refused by
#       BOTH sides. A check that cannot fail proves nothing, so these come with
#       the happy paths.
#
# The gate's `receipt` subcommand is run as a program (env -i, a scratch state
# directory, the real bin/maintainer-merge). Observed and dependency receipts
# need podman or the GitHub API to earn, so for those the bodies come from the
# gate's own writer snippets and the SIGNATURE is the gate's own `receipt_seal`
# function, sourced. The signing and the bytes are the gate's; the bodies are
# copies of its writers (the same snippets generated the fixtures under
# tests/fixtures).
#
# Usage: interop.sh            (builds the helper with cargo, runs everything)
# Env:   MX_TREE      tree whose bin/maintainer-merge is used (default: this checkout)
#        MX_SCRATCH   where the scratch directory goes (default: TMPDIR, then /tmp)
# Exit:  0 when every check passed and the expected number of checks ran.
# SC2015: ok and bad both return 0, so `A && ok || bad` is an if/else here.
# SC2016: the single-quoted bash -c programs expand their own $1 and $@.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ws="$(cd "$here/../../.." && pwd)"
root="$(cd "$ws/.." && pwd)"
MX_TREE="${MX_TREE:-$root}"
mm="$MX_TREE/bin/maintainer-merge"
EXPECTED_CHECKS=120

[ -f "$mm" ] || { echo "interop: no bin/maintainer-merge under MX_TREE=$MX_TREE" >&2; exit 2; }

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ws/target}"
built="$(cd "$ws" && cargo build --locked -q -p mx-receipt --bin mx-receipt-interop 2>&1)"; rc=$?
[ "$rc" = 0 ] || { printf '%s\ninterop: cargo build failed (exit %s)\n' "$built" "$rc" >&2; exit 2; }
bin="$CARGO_TARGET_DIR/debug/mx-receipt-interop"
[ -x "$bin" ] || { echo "interop: $bin was not built" >&2; exit 2; }

scratch="$(mktemp -d "${MX_SCRATCH:-${TMPDIR:-/tmp}}/mx-receipt-interop.XXXXXX")" || exit 2
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/repo"
key="$scratch/receipt.key"
printf '\n  interop-key-0001-not-a-secret  \n\n' > "$key"

N=0; F=0
ok()   { N=$((N + 1)); printf 'ok    %s\n' "$1"; }
bad()  { N=$((N + 1)); F=$((F + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '      %s\n' "$2" | sed -n '1,6p'; }
# expect_rc NAME WANT GOT [DETAIL]
expect_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: exit $3, wanted $2" "${4:-}"; fi; }

# The gate, as a program, for one state directory.
gate() {  # $1 = state dir, then the arguments
    local state="$1"; shift
    env -i PATH="$PATH" HOME="$scratch/home" LC_ALL=C TZ=UTC LOGNAME=interop-user USER=interop-user \
        MAINTAINER_STATE="$state" MAINTAINER_ACCOUNT=testuser MAINTAINER_SLUG=o/r \
        MAINTAINER_REPO="$scratch/repo" MAINTAINER_RECEIPT_KEY="$key" PROD_GLOBS='crates/*/src/*' \
        timeout 120 bash "$mm" "$@"
}
# One function of the gate, sourced, for one state directory. A `die` exits 1.
gate_fn() {  # $1 = state dir, $2 = extra env (NAME=VALUE or -), then the function and its arguments
    local state="$1" extra="$2"; shift 2
    local -a more=(); [ "$extra" = "-" ] || more=("$extra")
    env -i PATH="$PATH" HOME="$scratch/home" LC_ALL=C TZ=UTC \
        MAINTAINER_STATE="$state" MAINTAINER_RECEIPT_KEY="$key" "${more[@]}" \
        timeout 120 bash -c 'source "$1"; shift; "$@"' bash "$mm" "$@"
}

HEAD40=cc5e01302bbd828fbf516fca54e1a6e12738de7c
STAMP_AT=2026-01-01T00:00:00+00:00
STAMP_BY=interop-user

# Five proofs that differ in what json.dump has to escape.
P1='plain ascii proof'
P2=$'caf\xc3\xa9 \xe2\x82\xac \xc3\xbf'
P3=$'emoji \xf0\x9f\x98\x80 and \xf0\x9d\x94\x98 beyond the BMP'
P4=$'q"uote \\ back\ttab\nnewline\x01\x1f\x7f end'
P5="$(printf 'long %.0s' $(seq 1 120))"
PROOFS=("$P1" "$P2" "$P3" "$P4" "$P5")
PRS=(7 8 9 10 12345)
HEADS=("$HEAD40" "$HEAD40" "$HEAD40" "$HEAD40" abcdef0)

# ---------------------------------------------------------------- (a) bash writes
sa="$scratch/state-a"; mkdir -p "$sa/receipts"
for i in 0 1 2 3 4; do
    pr="${PRS[$i]}"
    out="$(gate "$sa" receipt "$pr" "${HEADS[$i]}" "${PROOFS[$i]}" 2>&1)"; rc=$?
    expect_rc "a: bash wrote the asserted receipt $((i + 1)) (#$pr)" 0 "$rc" "$out"
    out="$("$bin" verify "$key" "$sa/receipts/$pr.json" "$pr" 2>&1)"; rc=$?
    expect_rc "a: rust verifies bash's asserted receipt $((i + 1)) and writes it back to the same bytes" 0 "$rc" "$out"
    grep -q '^verified ' <<<"$out" && ok "a: rust printed the verdict line for receipt $((i + 1))" || bad "a: no verdict line for receipt $((i + 1))" "$out"
    out="$("$bin" verify "$key" "$sa/receipts/$pr.json" "$pr" --unattended 2>&1)"; rc=$?
    expect_rc "a: rust refuses bash's asserted receipt $((i + 1)) for an unattended run" 1 "$rc" "$out"
    grep -q "not 'observed'" <<<"$out" && ok "a: rust gives the unattended reason for receipt $((i + 1))" || bad "a: rust gave another reason for receipt $((i + 1))" "$out"
    out="$(gate_fn "$sa" MAINTAINER_IN_RUN=review receipt_check "$pr" 2>&1)"; rc=$?
    expect_rc "a: bash refuses its own asserted receipt $((i + 1)) for an unattended run" 1 "$rc" "$out"
    grep -q "not 'observed'" <<<"$out" && ok "a: bash gives the unattended reason for receipt $((i + 1))" || bad "a: bash gave another reason for receipt $((i + 1))" "$out"
done

# Observed (two suites folded) and dependency receipts: bodies from the gate's
# writer snippets, signed by the gate's receipt_seal.
python3 - "$sa/receipts/20.json" "$sa/receipts/21.json" "$HEAD40" "$STAMP_AT" "$STAMP_BY" <<'PYEOF' || { echo "interop: could not write the bodies" >&2; exit 2; }
import json, sys
out_o, out_d, head, at, by = sys.argv[1:6]
parts = [("rust", "12", "gate::refuses", "s/>=/>/", "101", "assertion failed → café"),
         ("python", "3", "test_gate", "s/a/b/", "1", "FAILED tests/test_gate.py::test_x")]
proofs = []
for suite, ran, filt, mut, rc, msg in parts:
    proofs = [p for p in proofs if p.get("suite") != suite]
    proofs.append({"suite": suite, "units_run": ran, "filter": filt, "mutation": mut,
                   "proof": f"`{filt}` passes clean and fails under `{mut}` (rc={rc})", "observed_failure": msg})
    proofs.sort(key=lambda p: p["suite"])
suite, ran, filt, mut, rc, msg = parts[-1]
json.dump({"pr": 20, "head": head, "kind": "observed", "partial": True,
           "suite": " ".join(p["suite"] for p in proofs),
           "units_run": ", ".join(f'{p["suite"]}:{p["units_run"]}' for p in proofs),
           "proof": " AND ".join(p["proof"] for p in proofs),
           "mutation": mut, "filter": filt, "observed_failure": msg, "proofs": proofs,
           "recorded_at": at, "recorded_by": by}, open(out_o, "w"), indent=2)
json.dump({"pr": 21, "head": head, "kind": "dependency",
           "proof": "pure dependency bump: 4 changed line(s) in Cargo.lock (2); no source outside crates.io/registry.npmjs.org/PyPI, no new install script, 2 action pin(s) verified against their tags, 1 base image(s) verified against their registry, 0 pip package(s) verified against PyPI",
           "files": "Cargo.lock (2)", "changed_lines": 4, "pins_verified": 2, "images_verified": 1, "pip_verified": 0,
           "recorded_at": at, "recorded_by": by}, open(out_d, "w"), indent=2)
PYEOF
for pr in 20 21; do
    out="$(gate_fn "$sa" - receipt_seal "$sa/receipts/$pr.json" 2>&1)"; rc=$?
    expect_rc "a: the gate's receipt_seal signed the body for #$pr" 0 "$rc" "$out"
    out="$("$bin" verify "$key" "$sa/receipts/$pr.json" "$pr" --unattended 2>&1)"; rc=$?
    expect_rc "a: rust verifies the gate-signed receipt #$pr, even unattended (observed or dependency)" 0 "$rc" "$out"
    out="$(gate_fn "$sa" MAINTAINER_IN_RUN=review receipt_check "$pr" 2>&1)"; rc=$?
    expect_rc "a: bash agrees on the gate-signed receipt #$pr, unattended" 0 "$rc" "$out"
done
want="$(gate_fn "$sa" - receipt_suites "$sa/receipts/20.json" 2>&1)"
got="$("$bin" suites "$sa/receipts/20.json" 2>&1)"
[ "$want" = "$got" ] && [ "$got" = "python rust" ] && ok "a: rust reads the suites 'python rust' as bash does" || bad "a: suites differ" "bash '$want' rust '$got'"
want="$(gate_fn "$sa" - receipt_field "$sa/receipts/20.json" partial false 2>&1)"
got="$("$bin" partial "$sa/receipts/20.json" 2>&1)"
[ "${want,,}" = "${got,,}" ] && [ "$got" = "True" ] && ok "a: rust reads partial=True as bash does" || bad "a: partial differs" "bash '$want' rust '$got'"
want="$(gate_fn "$sa" - receipt_field "$sa/receipts/7.json" partial false 2>&1)"
got="$("$bin" partial "$sa/receipts/7.json" 2>&1)"
# bash prints its own default, the lower-case text 'false', for a missing field.
[ "${want,,}" = "${got,,}" ] && [ "$got" = "False" ] && ok "a: rust reads a missing partial as False as bash does" || bad "a: missing partial differs" "bash '$want' rust '$got'"

# ---------------------------------------------------------------- (b) rust writes
sb="$scratch/state-b"; mkdir -p "$sb/receipts"
for i in 0 1 2 3 4; do
    pr="${PRS[$i]}"
    out="$("$bin" write-asserted "$key" "$sb/receipts/$pr.json" "$pr" "${HEADS[$i]}" "${PROOFS[$i]}" "$STAMP_AT" "$STAMP_BY" 2>&1)"; rc=$?
    expect_rc "b: rust wrote the asserted receipt $((i + 1)) (#$pr)" 0 "$rc" "$out"
    out="$(gate_fn "$sb" - receipt_check "$pr" 2>&1)"; rc=$?
    expect_rc "b: bash receipt_check accepts rust's asserted receipt $((i + 1))" 0 "$rc" "$out"
    grep -q 'ASSERTED, not observed' <<<"$out" && ok "b: bash says ASSERTED for rust's receipt $((i + 1))" || bad "b: no ASSERTED notice for receipt $((i + 1))" "$out"
    gate "$sb" show "$pr" > "$scratch/shown" 2>&1; rc=$?
    expect_rc "b: bash show $pr exits 0 on rust's receipt" 0 "$rc"
    cmp -s "$scratch/shown" "$sb/receipts/$pr.json" && ok "b: bash show $pr prints the file's exact bytes" || bad "b: bash show $pr differs from the file"
    out="$("$bin" show "$sb/receipts" "$pr" 2>&1)"; rc=$?
    expect_rc "b: rust show $pr exits 0" 0 "$rc" "$out"
    gate_fn "$sb" MAINTAINER_IN_RUN=review receipt_check "$pr" >/dev/null 2>&1; rc=$?
    expect_rc "b: bash refuses rust's asserted receipt $((i + 1)) when unattended" 1 "$rc"
done
ob="$sb/receipts/20.json"
out="$("$bin" write-observed "$key" "$ob" 20 "$HEAD40" 1 rust 12 gate::refuses 's/>=/>/' 101 $'assertion failed \xe2\x86\x92 caf\xc3\xa9' "$STAMP_AT" "$STAMP_BY" 2>&1)"; rc=$?
expect_rc "b: rust wrote the first part of an observed receipt (#20)" 0 "$rc" "$out"
out="$("$bin" write-observed "$key" "$ob" 20 "$HEAD40" 1 python 3 test_gate 's/a/b/' 1 'FAILED tests/test_gate.py::test_x' "$STAMP_AT" "$STAMP_BY" 2>&1)"; rc=$?
expect_rc "b: rust folded a second suite into it" 0 "$rc" "$out"
cmp -s "$ob" "$sa/receipts/20.json" && ok "b: rust's folded receipt is byte for byte the receipt the gate-signed body gave (#20)" || bad "b: folded receipt differs from the gate-signed one" "$(diff <(cat "$ob") <(cat "$sa/receipts/20.json") | head -4)"
out="$(gate_fn "$sb" MAINTAINER_IN_RUN=review receipt_check 20 2>&1)"; rc=$?
expect_rc "b: bash receipt_check accepts rust's folded observed receipt, unattended" 0 "$rc" "$out"
want="$(gate_fn "$sb" - receipt_suites "$ob" 2>&1)"; got="$("$bin" suites "$ob" 2>&1)"
[ "$want" = "$got" ] && [ "$got" = "python rust" ] && ok "b: bash receipt_suites reads rust's folded receipt as 'python rust'" || bad "b: suites differ" "bash '$want' rust '$got'"
want="$(gate_fn "$sb" - receipt_field "$ob" partial false 2>&1)"
[ "$want" = "True" ] && ok "b: bash reads partial=True from rust's folded receipt" || bad "b: partial is '$want'"
db="$sb/receipts/21.json"
out="$("$bin" write-dependency "$key" "$db" 21 "$HEAD40" 'Cargo.lock (2)' 4 2 1 0 "$STAMP_AT" "$STAMP_BY" 2>&1)"; rc=$?
expect_rc "b: rust wrote a dependency receipt (#21)" 0 "$rc" "$out"
cmp -s "$db" "$sa/receipts/21.json" && ok "b: rust's dependency receipt is byte for byte the gate-signed one (#21)" || bad "b: dependency receipt differs from the gate-signed one"
out="$(gate_fn "$sb" MAINTAINER_IN_RUN=review receipt_check 21 2>&1)"; rc=$?
expect_rc "b: bash receipt_check accepts rust's dependency receipt, unattended" 0 "$rc" "$out"
grep -q 'DEPENDENCY receipt' <<<"$out" && ok "b: bash says DEPENDENCY for rust's receipt" || bad "b: no DEPENDENCY notice" "$out"

# The listings: both sides print the same lines for both directories.
for label in a b; do
    dir="$scratch/state-$label"
    gate "$dir" show > "$scratch/list.bash" 2>&1; rc=$?
    expect_rc "$label: bash show (list) exits 0" 0 "$rc"
    "$bin" show-list "$dir/receipts" > "$scratch/list.rust" 2>&1; rc=$?
    expect_rc "$label: rust show-list exits 0" 0 "$rc"
    # Bash prints every line with two leading spaces; a proof with newlines continues on bare lines.
    cmp -s "$scratch/list.bash" "$scratch/list.rust" && ok "$label: the two listings are byte for byte equal" || bad "$label: the listings differ" "$(diff "$scratch/list.bash" "$scratch/list.rust" | head -6)"
    [ "$(wc -l < "$scratch/list.rust")" -ge 7 ] && ok "$label: the listing holds at least 7 lines (7 receipts)" || bad "$label: the listing is too short ($(wc -l < "$scratch/list.rust") lines)"
done
mkdir -p "$scratch/state-empty/receipts"
gate "$scratch/state-empty" show > "$scratch/list.bash" 2>&1
"$bin" show-list "$scratch/state-empty/receipts" > "$scratch/list.rust" 2>&1
cmp -s "$scratch/list.bash" "$scratch/list.rust" && ok "listing of an empty directory is equal ('no receipts recorded')" || bad "empty listings differ" "$(cat "$scratch/list.bash") | $(cat "$scratch/list.rust")"

# ---------------------------------------------------------------- (c) controls
sc="$scratch/state-c"; mkdir -p "$sc/receipts"
cp "$sb/receipts/7.json" "$sc/receipts/7.json"

# edited after signing
sed 's/plain ascii proof/plain ascii PROOF/' "$sb/receipts/7.json" > "$sc/receipts/7.json"
cmp -s "$sc/receipts/7.json" "$sb/receipts/7.json" && bad "c: the edit did not change the file (vacuous control)"
out="$(gate_fn "$sc" - receipt_check 7 2>&1)"; rc=$?
expect_rc "c: bash refuses an edited receipt" 1 "$rc" "$out"
grep -q 'does not match its signature' <<<"$out" && ok "c: bash names the signature" || bad "c: bash did not name the signature" "$out"
out="$("$bin" verify "$key" "$sc/receipts/7.json" 7 2>&1)"; rc=$?
expect_rc "c: rust refuses an edited receipt" 1 "$rc" "$out"
grep -q 'does not match its signature' <<<"$out" && ok "c: rust names the signature" || bad "c: rust did not name the signature" "$out"

# keys reordered
python3 - "$sb/receipts/7.json" "$sc/receipts/7.json" <<'PYEOF' || exit 2
import json, sys
d = json.load(open(sys.argv[1])); kind = d.pop("kind")
json.dump({"kind": kind, **d}, open(sys.argv[2], "w"), indent=2)
PYEOF
out="$(gate_fn "$sc" - receipt_check 7 2>&1)"; rc=$?
expect_rc "c: bash refuses reordered keys" 1 "$rc" "$out"
out="$("$bin" verify "$key" "$sc/receipts/7.json" 7 2>&1)"; rc=$?
expect_rc "c: rust refuses reordered keys" 1 "$rc" "$out"

# no signature
python3 - "$sb/receipts/7.json" "$sc/receipts/7.json" <<'PYEOF' || exit 2
import json, sys
d = json.load(open(sys.argv[1])); d.pop("signature")
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYEOF
out="$(gate_fn "$sc" - receipt_check 7 2>&1)"; rc=$?
expect_rc "c: bash refuses an unsigned receipt" 1 "$rc" "$out"
grep -q 'carries no signature' <<<"$out" && ok "c: bash says unsigned" || bad "c: bash did not say unsigned" "$out"
out="$("$bin" verify "$key" "$sc/receipts/7.json" 7 2>&1)"; rc=$?
expect_rc "c: rust refuses an unsigned receipt" 1 "$rc" "$out"
grep -q 'no signature' <<<"$out" && ok "c: rust says unsigned" || bad "c: rust did not say unsigned" "$out"

# a valid receipt copied to the wrong pull request
cp "$sb/receipts/7.json" "$sc/receipts/8.json"
out="$(gate_fn "$sc" - receipt_check 8 2>&1)"; rc=$?
expect_rc "c: bash refuses a receipt copied to #8" 1 "$rc" "$out"
grep -q 'was earned for #7, not #8' <<<"$out" && ok "c: bash names #7" || bad "c: bash did not name #7" "$out"
out="$("$bin" verify "$key" "$sc/receipts/8.json" 8 2>&1)"; rc=$?
expect_rc "c: rust refuses a receipt copied to #8" 1 "$rc" "$out"
grep -q 'earned for #7, not #8' <<<"$out" && ok "c: rust names #7" || bad "c: rust did not name #7" "$out"

# wrong key
printf 'a different key\n' > "$scratch/other.key"
out="$("$bin" verify "$scratch/other.key" "$sb/receipts/7.json" 7 2>&1)"; rc=$?
expect_rc "c: rust refuses a receipt signed with another key" 1 "$rc" "$out"
out="$(env -i PATH="$PATH" HOME="$scratch/home" LC_ALL=C MAINTAINER_STATE="$sb" MAINTAINER_RECEIPT_KEY="$scratch/other.key" bash -c 'source "$1"; receipt_check 7' bash "$mm" 2>&1)"; rc=$?
expect_rc "c: bash refuses a receipt signed with another key" 1 "$rc" "$out"

# the helper itself reports a missing receipt and a missing key
out="$("$bin" verify "$key" "$sc/receipts/99.json" 99 2>&1)"; rc=$?
expect_rc "c: rust refuses a pull request with no receipt" 1 "$rc" "$out"
out="$("$bin" verify "$scratch/no-such.key" "$sb/receipts/7.json" 7 2>&1)"; rc=$?
expect_rc "c: rust refuses a missing key file" 1 "$rc" "$out"

# a short head and a bad show argument
out="$("$bin" write-asserted "$key" "$scratch/short.json" 7 abcdef p "$STAMP_AT" "$STAMP_BY" 2>&1)"; rc=$?
expect_rc "c: rust refuses a six-character head" 1 "$rc" "$out"
[ ! -e "$scratch/short.json" ] && ok "c: the refused write left no file" || bad "c: a file was left behind"
out="$("$bin" show "$sb/receipts" ../../state-a/receipts/7 2>&1)"; rc=$?
expect_rc "c: rust show refuses a path in place of a number (decision F2)" 1 "$rc" "$out"
out="$(gate "$sb" show ../../state-a/receipts/7 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "c: bash show still reads outside the directory (the behaviour F2 fixes)" || bad "c: bash show refused ../ (the control changed)" "$out"

printf 'interop: %d checks, %d failed\n' "$N" "$F"
if [ "$N" != "$EXPECTED_CHECKS" ]; then
    printf 'interop: expected %d checks and ran %d, so some did not run\n' "$EXPECTED_CHECKS" "$N" >&2
    exit 1
fi
[ "$F" = 0 ]
