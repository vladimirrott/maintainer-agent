#!/usr/bin/env bash
# Characterization: `maintainer-merge show`, with and without a pull request
# number, including numbers that are not numbers.
#
# `show` is the one subcommand that does not pass its argument through
# pr_or_die. It builds "$RECEIPTS/<arg>.json" from the text as given, so a
# hostile argument walks out of the receipts directory. The two traversal cases
# pin that as it is today, see plan decision F2: a later port will refuse such
# an argument.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cz_init

# --- show with no argument ----------------------------------------------------------

case_show_empty() {
    cz_mm show
    cz_expect_rc 0
    cz_expect_stdout "  no receipts recorded"
    cz_expect_stderr_empty
    cz_expect_file "$CZ_RECEIPTS"
}
cz_case "show: with no receipts it prints 'no receipts recorded' on stdout and exits 0" case_show_empty

case_show_list() {
    cz_repo_basic
    cz_receipt 7 "$CZ_C0" observed
    cz_receipt 12 "0123456789abcdef0123456789abcdef01234567" observed
    : > "$CZ_RECEIPTS/.merge-7.lock"
    cz_mm show
    cz_expect_rc 0
    # Files are listed in glob order, which sorts 12 before 7. One line each:
    # the number, the first eight characters of the head, and the proof cut at 60.
    cz_expect_stdout \
        "  12: 01234567 characterization fixture" \
        "  7: ${CZ_C0:0:8} characterization fixture"
    cz_expect_stderr_empty
}
cz_case "show: lists each receipt as '<pr>: <head, 8 chars> <proof>' in glob order and skips the lock files" case_show_list

case_show_list_truncates_proof() {
    cz_repo_init
    cz_mm receipt 7 abcdef0123 "$(printf 'p%.0s' $(seq 1 80))"
    cz_mm show
    cz_expect_rc 0
    cz_expect_stdout "  7: abcdef01 $(printf 'p%.0s' $(seq 1 60))"
}
cz_case "show: the proof is cut at 60 characters in the list" case_show_list_truncates_proof

# --- show with a number ----------------------------------------------------------------

case_show_one() {
    cz_repo_basic
    cz_receipt 7 "$CZ_C0" observed
    cz_mm show 7
    cz_expect_rc 0
    cz_expect_stderr_empty
    cmp -s "$CZ_RECEIPTS/7.json" "$CZ_CASE/stdout" || cz_note_fail "stdout is not the receipt file byte for byte"
}
cz_case "show 7: prints the receipt file byte for byte on stdout and exits 0" case_show_one

case_show_missing() {
    cz_mm show 99
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-merge: no receipt for #99"
}
cz_case "show 99: no such receipt exits 1 with the message on stderr" case_show_missing

# Pins current behaviour. The argument is not validated, so a word is looked up
# as a file name.
case_show_word() {
    cz_mm show abc
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-merge: no receipt for #abc"
}
cz_case "show abc: a non-number is looked up as a name and reported as missing (pins current behaviour)" case_show_word

# --- a hostile pull request number --------------------------------------------------------

# Pins current behaviour, see plan decision F2. `../x` resolves to
# $STATE/x.json, one level above the receipts directory, and `show` prints it.
case_show_dotdot() {
    printf '{"outside": "the receipts directory"}\n' > "$CZ_STATE/x.json"
    cz_mm show ../x
    cz_expect_rc 0
    cz_expect_stderr_empty
    cz_expect_stdout '{"outside": "the receipts directory"}'
}
cz_case "show ../x: reads \$STATE/x.json outside the receipts directory and prints it (pins current behaviour, see plan decision F2)" case_show_dotdot

# Pins current behaviour, see plan decision F2. With a directory named 1 inside
# the receipts directory, `1/../../y` resolves to $STATE/y.json.
case_show_nested_dotdot() {
    mkdir -p "$CZ_RECEIPTS/1"
    printf '{"outside": "two levels up the path"}\n' > "$CZ_STATE/y.json"
    cz_mm show 1/../../y
    cz_expect_rc 0
    cz_expect_stderr_empty
    cz_expect_stdout '{"outside": "two levels up the path"}'
}
cz_case "show 1/../../y: reads \$STATE/y.json when receipts/1 exists (pins current behaviour, see plan decision F2)" case_show_nested_dotdot

# Without the directory the kernel cannot resolve the path, so the read fails
# and the ordinary "no receipt" message appears. Nothing in the program decides
# that. It is an accident of the file system.
case_show_nested_dotdot_no_dir() {
    printf '{"outside": "two levels up the path"}\n' > "$CZ_STATE/y.json"
    cz_mm show 1/../../y
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-merge: no receipt for #1/../../y"
}
cz_case "show 1/../../y: without receipts/1 the path does not resolve and it reports a missing receipt (pins current behaviour, see plan decision F2)" case_show_nested_dotdot_no_dir

# The same walk out of the directory reaches a file that is not a receipt at
# all, because only ".json" is appended.
case_show_dotdot_not_a_receipt() {
    printf 'plain text, not a receipt\n' > "$CZ_STATE/notes.json"
    cz_mm show ../notes
    cz_expect_rc 0
    cz_expect_stdout "plain text, not a receipt"
}
cz_case "show ../notes: prints any .json file one level up, receipt or not (pins current behaviour, see plan decision F2)" case_show_dotdot_not_a_receipt

# A traversal that ends outside the state directory but cannot name a file
# without the suffix.
case_show_dotdot_needs_suffix() {
    printf 'no suffix here\n' > "$CZ_STATE/plain"
    cz_mm show ../plain
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer-merge: no receipt for #../plain"
}
cz_case "show ../plain: a file without the .json suffix is not reached" case_show_dotdot_needs_suffix

cz_finish
