#!/usr/bin/env bash
# Characterization: the bytes of a receipt and the signature over them.
#
# A later Rust writer must produce these bytes and a later Rust verifier must
# accept them, so this file holds a known-answer vector: golden/receipt.key (the
# signing key, a test value) and golden/receipt-asserted.json (the receipt).
#
# How the golden receipt was produced. It is the program's own output, reviewed
# by eye, with one change that makes it repeatable:
#   1. `maintainer-merge receipt 7 cc5e01302bbd828fbf516fca54e1a6e12738de7c
#      'mutation "proved" é<newline>second line'` ran in a scratch state
#      directory with LOGNAME=fixture-user, TZ=UTC and golden/receipt.key.
#   2. recorded_at, the one field the program takes from the clock, was
#      replaced with 2026-01-01T00:00:00+00:00 and the signature field removed.
#   3. The program's own receipt_seal function (the bash file, sourced) signed
#      the result again.
# It shows what the writer does: json.dump(indent=2) of seven keys in insertion
# order (pr, head, kind, proof, recorded_at, recorded_by, signature),
# ASCII only (é is \u00e9, the quote is \", the newline is \n), two-space
# indent, no newline at the end, and a lower-case hex HMAC-SHA256 over the
# bytes without the signature field.
#
# The cc5e0130... head is the commit cz_repo_basic creates: the fixture dates
# and identities are fixed, so the commit id repeats. A case below fails
# if that ever stops being true.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cz_init

GOLDEN="$CZ_GOLDEN/receipt-asserted.json"
GOLDEN_HEAD=cc5e01302bbd828fbf516fca54e1a6e12738de7c
PROOF=$'mutation "proved" \xc3\xa9\nsecond line'

# receipt_check MODE FILE: independent checks, in python, of a receipt the
# program wrote. Prints the reason when it fails.
receipt_check() {
    python3 - "$1" "$2" "$GOLDEN" "$CZ_CASE/receipt.key" <<'PYEOF'
import hashlib, hmac, json, re, sys
mode, actual_p, golden_p, key_p = sys.argv[1:5]
actual = open(actual_p, "rb").read()
golden = open(golden_p, "rb").read()
def fail(msg):
    print(msg)
    sys.exit(1)
text = actual.decode("ascii")      # raises if the writer put a non-ASCII byte in the file
d = json.loads(text)
if mode == "bytes":
    norm = re.sub(r'("recorded_at": )"[^"]*"', r'\1"2026-01-01T00:00:00+00:00"', text, count=1)
    norm = re.sub(r'("signature": )"[0-9a-f]{64}"',
                  lambda m: m.group(1) + '"' + json.loads(golden)["signature"] + '"', norm, count=1)
    if norm.encode("ascii") != golden:
        fail("bytes differ from the golden after normalising recorded_at and signature:\n" + norm)
elif mode == "signature":
    # The key text is stripped, as the program strips it, then used as UTF-8.
    key = open(key_p, "rb").read().decode().strip().encode()
    sig = d.pop("signature", None)
    if sig is None:
        fail("the receipt has no signature field")
    want = hmac.new(key, json.dumps(d, indent=2).encode(), hashlib.sha256).hexdigest()
    if sig != want:
        fail("signature is %s, an independent HMAC-SHA256 gives %s" % (sig, want))
elif mode.startswith("recorded_at:"):
    m = re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{6})?([+-]\d\d:\d\d)", d["recorded_at"])
    if not m:
        fail("recorded_at %r is not an ISO timestamp with an offset" % d["recorded_at"])
    if m.group(2) != mode.split(":", 1)[1]:
        fail("recorded_at offset is %s, wanted %s" % (m.group(2), mode.split(":", 1)[1]))
elif mode.startswith("field:"):
    k, v = mode[6:].split("=", 1)
    if d.get(k) != v:
        fail("%s is %r, wanted %r" % (k, d.get(k), v))
elif mode == "no-final-newline":
    if actual.endswith(b"\n"):
        fail("the file ends with a newline")
else:
    fail("unknown mode " + mode)
PYEOF
}

expect_check() {  # $1 = mode, $2 = file
    local out rc
    out="$(receipt_check "$1" "$2" 2>&1)"; rc=$?
    [ "$rc" = 0 ] || cz_note_fail "independent check '$1' failed: $out"
}

# --- the writer: `maintainer-merge receipt` ---------------------------------------

write_receipt() {  # runs the writer with the golden inputs
    cz_repo_basic
    cz_mm receipt 7 "$CZ_C0" "$PROOF"
}

case_fixture_commit() {
    cz_repo_basic
    cz_check "the fixture commit" "$CZ_C0" "$GOLDEN_HEAD"
}
cz_case "golden: the fixture repository's first commit is the head the golden receipt names" case_fixture_commit

case_writer_output() {
    write_receipt
    cz_expect_rc 0
    cz_expect_stdout "  receipt recorded for #7 at $CZ_C0 (asserted, not observed)"
    cz_expect_stderr_empty
    cz_expect_file "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: exit 0, one stdout line naming the head and 'asserted, not observed', empty stderr" case_writer_output

case_writer_bytes() {
    write_receipt
    cz_expect_rc 0
    expect_check bytes "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: the file bytes match the golden (key order, escapes, indent) once recorded_at and the signature are normalised" case_writer_bytes

case_writer_signature() {
    write_receipt
    cz_expect_rc 0
    expect_check signature "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: the signature is HMAC-SHA256 in lower-case hex over the unsigned bytes, checked by separate code" case_writer_signature

case_writer_no_final_newline() {
    write_receipt
    expect_check no-final-newline "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: the file has no newline at the end" case_writer_no_final_newline

case_writer_recorded_at_utc() {
    write_receipt
    expect_check "recorded_at:+00:00" "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: recorded_at is an ISO timestamp with the local offset (TZ=UTC gives +00:00)" case_writer_recorded_at_utc

case_writer_recorded_at_offset() {
    cz_set TZ "XXX-3"
    write_receipt
    expect_check "recorded_at:+03:00" "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: recorded_at follows the TZ of the caller (XXX-3 gives +03:00)" case_writer_recorded_at_offset

case_writer_recorded_by() {
    cz_set LOGNAME some-other-user
    write_receipt
    expect_check "field:recorded_by=some-other-user" "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: recorded_by is the login name from the environment" case_writer_recorded_by

# The key is read as text and stripped, so the whitespace around it does not
# change the signature.
case_writer_key_stripped() {
    printf '\n  characterization-key-0001-not-a-secret  \n\n' > "$CZ_CASE/receipt.key"
    write_receipt
    cz_expect_rc 0
    expect_check signature "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: whitespace around the key text is stripped before signing" case_writer_key_stripped

case_writer_kind() {
    write_receipt
    expect_check "field:kind=asserted" "$CZ_RECEIPTS/7.json"
    expect_check "field:head=$CZ_C0" "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: a hand-recorded receipt has kind 'asserted'" case_writer_kind

# Pins current behaviour. Nothing but the length is checked, so a head that is
# not a hash is recorded as typed.
case_writer_any_head() {
    cz_repo_init
    cz_mm receipt 7 "not a sha at all" "p"
    cz_expect_rc 0
    expect_check "field:head=not a sha at all" "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: any head of seven or more characters is recorded as typed (pins current behaviour)" case_writer_any_head

case_writer_seven_chars() {
    cz_repo_init
    cz_mm receipt 7 abcdef0 "p"
    cz_expect_rc 0
    cz_expect_stdout "  receipt recorded for #7 at abcdef0 (asserted, not observed)"
}
cz_case "receipt: a head of seven characters is accepted" case_writer_seven_chars

case_writer_short_head() {
    cz_repo_init
    cz_mm receipt 7 abcdef "p"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-merge: head sha looks truncated: abcdef"
    cz_expect_no_file "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: a head of six characters exits 1 on stderr and writes nothing" case_writer_short_head

case_writer_in_run() {
    cz_repo_init
    cz_set MAINTAINER_IN_RUN review
    cz_mm receipt 7 abcdef0 "p"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr_first "maintainer-merge: an unattended run may not assert a receipt."
    cz_expect_no_file "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: an unattended run may not assert one: exit 1 on stderr, nothing written" case_writer_in_run

# Pins current behaviour. The receipt is written before it is signed, so a
# missing key leaves an unsigned receipt on disk and exits 1. `merge` then
# refuses it as unsigned.
case_writer_no_key() {
    cz_repo_basic
    cz_set MAINTAINER_RECEIPT_KEY "$CZ_CASE/missing.key"
    cz_mm receipt 7 "$CZ_C0" "p"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-merge: no receipt key at $CZ_CASE/missing.key; run ./install.sh"
    cz_expect_file "$CZ_RECEIPTS/7.json"
    if grep -q '"signature"' "$CZ_RECEIPTS/7.json"; then cz_note_fail "the receipt left behind carries a signature"; fi
}
cz_case "receipt: a missing key exits 1 and leaves the unsigned receipt on disk (pins current behaviour)" case_writer_no_key

# Pins current behaviour: a second receipt for the same pull request replaces
# the first without a word.
case_writer_overwrites() {
    cz_repo_init
    cz_mm receipt 7 abcdef0 "first"
    cz_mm receipt 7 abcdef1 "second"
    cz_expect_rc 0
    expect_check "field:proof=second" "$CZ_RECEIPTS/7.json"
    expect_check "field:head=abcdef1" "$CZ_RECEIPTS/7.json"
    expect_check signature "$CZ_RECEIPTS/7.json"
}
cz_case "receipt: a second receipt for the same pull request replaces the first (pins current behaviour)" case_writer_overwrites

# --- the verifier: `maintainer-merge merge` reading the golden receipt ---------------

# Plants the golden receipt, changed by a variant, for pull request 7
# at the fixture head, and runs the merge.
merge_with_golden() {  # $1 = variant name, or "" for the golden as it is
    cz_repo_basic
    cz_pr_ref 7 "$CZ_C0"
    cz_gh_baseline "$CZ_C0"
    mkdir -p "$CZ_RECEIPTS"
    if [ -z "$1" ]; then
        cp "$GOLDEN" "$CZ_RECEIPTS/7.json"
    else
        python3 - "$GOLDEN" "$CZ_RECEIPTS/7.json" "$1" <<'PYEOF' || { echo "characterization: variant $1 failed" >&2; exit 2; }
import json, sys
src, out, mode = sys.argv[1:4]
raw = open(src).read()
d = json.loads(raw)
if mode == "compact":
    text = json.dumps(d, separators=(",", ":"))
elif mode == "raw-utf8":
    text = json.dumps(d, indent=2, ensure_ascii=False)
elif mode == "four-space-indent":
    text = json.dumps(d, indent=4)
elif mode == "trailing-newline":
    text = raw + "\n"
elif mode == "reordered":
    kind = d.pop("kind")
    text = json.dumps({"kind": kind, **d}, indent=2)
elif mode == "signature-digit":
    sig = d["signature"]
    d["signature"] = ("0" if sig[0] != "0" else "1") + sig[1:]
    text = json.dumps(d, indent=2)
elif mode == "proof-edit":
    d["proof"] = d["proof"].replace("proved", "PROVED")
    text = json.dumps(d, indent=2)
elif mode == "pr-edit":
    d["pr"] = 8
    text = json.dumps(d, indent=2)
else:
    raise SystemExit("unknown variant " + mode)
open(out, "w", encoding="utf-8").write(text)
PYEOF
    fi
    cz_mm merge 7
}

case_golden_accepted() {
    merge_with_golden ""
    cz_expect_rc 0
    cz_expect_stdout_has "  the receipt is ASSERTED, not observed: it records a claim a"
    cz_expect_stdout_has "  merged #7"
    cz_expect_stderr_empty
}
cz_case "known answer: the program accepts the golden receipt and merges on it" case_golden_accepted

case_golden_refused() {
    merge_with_golden "$GV"
    cz_expect_refusal 1 "maintainer-merge: the receipt for #7 does not match its signature: it was edited"
}
for GV in signature-digit proof-edit reordered pr-edit; do
    cz_case "known answer: the golden receipt with variant '$GV' fails the signature check" case_golden_refused
done

# Pins current behaviour. The verifier parses the file and writes it out again
# with json.dump(indent=2) before computing the signature. Whitespace, a final
# newline and the choice between \u00e9 and a raw é therefore do not matter, and
# the order of the keys does. A port that hashed the file's own bytes would
# refuse receipts the bash gate accepts.
case_golden_reserialised() {
    merge_with_golden "$GV"
    cz_expect_rc 0
    cz_expect_stdout_has "  merged #7"
    cz_expect_stderr_empty
}
for GV in compact raw-utf8 four-space-indent trailing-newline; do
    cz_case "known answer: the golden receipt as '$GV' still verifies, because the verifier re-serialises (pins current behaviour)" case_golden_reserialised
done

# A receipt signed by the program that the test writer reproduces byte for byte.
case_writer_matches_fixture_writer() {
    cz_repo_basic
    cz_receipt 7 "$CZ_C0" asserted
    local fixture; fixture="$(cat "$CZ_RECEIPTS/7.json")"
    cz_mm receipt 7 "$CZ_C0" "characterization fixture"
    local program; program="$(cat "$CZ_RECEIPTS/7.json")"
    # Only the clock, the signature and the fixture's suite field may differ.
    local strip='/"recorded_at"/d; /"signature"/d; /"suite"/d'
    cz_check "program receipt minus clock and signature equals the fixture receipt's" \
        "$(sed "$strip" <<<"$program")" "$(sed "$strip" <<<"$fixture")"
}
cz_case "fixture writer: lib.sh's cz_receipt writes the same bytes as the program, apart from the clock, the signature and its suite field" case_writer_matches_fixture_writer

cz_finish
