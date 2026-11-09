#!/usr/bin/env bash
# Characterization: the command line of bin/maintainer-merge. The usage line
# and its exit code, what a missing argument does for each subcommand, what a
# non-integer pull request number does, and what happens when the profile
# cannot be loaded.
#
# The missing-argument cases pin current behaviour. The bash program does not
# print the usage line for them. Each subcommand reads its arguments with
# ${N:?name}, so bash itself writes "line N: <position>: <name>" and exits 1,
# where the usage path exits 64. No plan decision covers that difference yet.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cz_init

USAGE='usage: maintainer-merge {verify <pr> <sha> <test-filter> <sed-mutation> [suite]|verify-deps <pr> <sha>|verify-part <pr> <sha> <test-filter> <sed-mutation> <suite>|receipt <pr> <sha> <proof>|merge <pr>|update <pr>|show [pr]}'

# --- the usage line -------------------------------------------------------------

case_usage() {
    cz_mm "$@"
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "$USAGE"
    cz_expect_gh_log
}

case_usage_no_args() { case_usage; }
cz_case "usage: no arguments print the usage line on stderr and exit 64" case_usage_no_args

case_usage_unknown() { case_usage frobnicate; }
cz_case "usage: an unknown subcommand prints the usage line on stderr and exit 64" case_usage_unknown

case_usage_empty_word() { case_usage ""; }
cz_case "usage: an empty subcommand prints the usage line on stderr and exit 64" case_usage_empty_word

# Pins current behaviour. There is no help text: --help is an unknown subcommand.
case_usage_help() { case_usage --help; }
cz_case "usage: --help is an unknown subcommand and exits 64 (pins current behaviour)" case_usage_help

case_usage_wrong_case() { case_usage Merge 7; }
cz_case "usage: subcommand names are case sensitive" case_usage_wrong_case

case_usage_names_every_subcommand() {
    local word
    for word in "verify <pr>" "verify-deps <pr>" "verify-part <pr>" "receipt <pr>" "merge <pr>" "update <pr>" "show [pr]"; do
        grep -qF -- "$word" <<<"$USAGE" || cz_note_fail "the usage line in this test lacks '$word'"
    done
    cz_mm
    for word in "verify <pr>" "verify-deps <pr>" "verify-part <pr>" "receipt <pr>" "merge <pr>" "update <pr>" "show [pr]"; do
        cz_expect_stderr_has "$word"
    done
}
cz_case "usage: the line names verify, verify-deps, verify-part, receipt, merge, update and show" case_usage_names_every_subcommand

# --- a missing argument, subcommand by subcommand --------------------------------

# $MA_ARGS is the argument list given, $MA_WANT the "<position>: <name>" that
# bash reports for the first argument left out.
case_missing_arg() {
    # shellcheck disable=SC2086  # the words are plain tokens chosen below
    cz_mm $MA_ARGS
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_check "stderr is one line" "$(wc -l < "$CZ_CASE/stderr" | tr -d ' ')" "1"
    cz_expect_matches stderr "maintainer-merge: line [0-9]+: $MA_WANT\$"
    cz_expect_gh_log
}
missing() {  # $1 = subcommand with the arguments given, $2 = "<position>: <name>"
    MA_ARGS="$1"; MA_WANT="$2"
    cz_case "missing argument: '$1' exits 1 on stderr and names '$2'" case_missing_arg
}
missing "verify"                        "1: pr"
missing "verify 7"                      "2: head sha"
missing "verify 7 1234567"              "3: test filter"
missing "verify 7 1234567 t"            "4: sed expression"
missing "verify-part"                   "1: pr"
missing "verify-part 7"                 "2: head sha"
missing "verify-part 7 1234567"         "3: test filter"
missing "verify-part 7 1234567 t"       "4: sed expression"
missing "verify-deps"                   "1: pr"
missing "verify-deps 7"                 "2: head sha"
missing "receipt"                       "1: pr"
missing "receipt 7"                     "2: head sha"
missing "receipt 7 1234567"             "3: what was proved"
missing "merge"                         "1: pr"
missing "update"                        "1: pr"

# --- a pull request number that is not an integer --------------------------------

NOT_INT="maintainer-merge: pull request must be a positive integer, not"

case_not_integer() {
    cz_mm "${NI_ARGS[@]}"
    cz_expect_rc 1
    cz_expect_stdout_empty
    cz_expect_stderr "$NOT_INT '$NI_BAD'"
    cz_expect_gh_log
}
not_integer() {  # $1 = the bad number, then the subcommand and the rest of its arguments
    NI_BAD="$1"; shift
    NI_ARGS=("$@")
    cz_case "pr number: '$NI_BAD' to '${NI_ARGS[0]}' exits 1 on stderr before any gh call" case_not_integer
}
not_integer abc merge abc
not_integer 7x merge 7x
not_integer -1 merge -1
not_integer "7 8" merge "7 8"
not_integer "../x" merge "../x"
not_integer abc update abc
not_integer abc receipt abc 1234567 proof
not_integer abc verify-deps abc 1234567
not_integer abc verify abc 1234567 t 's/a/b/'
not_integer abc verify-part abc 1234567 t 's/a/b/' suite

# Pins current behaviour. The check is "digits only", so zero and numbers with
# leading zeros pass it and reach GitHub.
case_pr_zero() {
    cz_gh_baseline 0000000
    cz_mm merge 0
    cz_expect_refusal 1 "maintainer-merge: no verification receipt for #0. Prove the guard bites, then: maintainer-merge receipt 0 <sha> '<proof>'"
}
cz_case "pr number: 0 passes the integer check (pins current behaviour)" case_pr_zero

case_pr_leading_zeros() {
    cz_gh_baseline 0000000
    cz_mm merge 007
    cz_expect_refusal 1 "maintainer-merge: no verification receipt for #007. Prove the guard bites, then: maintainer-merge receipt 007 <sha> '<proof>'"
}
cz_case "pr number: 007 passes the integer check and is used as written (pins current behaviour)" case_pr_leading_zeros

# --- the profile cannot be loaded: exit 64 ---------------------------------------

case_profile_none() {
    cz_unset MAINTAINER_SLUG; cz_unset MAINTAINER_REPO
    cz_mm merge 7
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr \
        "maintainer: no profile is deployed. Run ./install.sh, or set" \
        "            MAINTAINER_PROFILE, MAINTAINER_SLUG and MAINTAINER_REPO."
    cz_expect_gh_log
}
cz_case "profile: none deployed and none named: exit 64, two lines on stderr" case_profile_none

case_profile_two() {
    local base="$CZ_CASE/home/.local/share/maintainer/profiles"
    mkdir -p "$base/alpha" "$base/beta"; : > "$base/alpha/profile.env"; : > "$base/beta/profile.env"
    cz_unset MAINTAINER_SLUG; cz_unset MAINTAINER_REPO
    cz_mm merge 7
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr \
        "maintainer: 2 profiles are deployed (alpha beta)." \
        "            Set MAINTAINER_PROFILE to say which one you mean."
}
cz_case "profile: two deployed and none named: exit 64, both names listed on stderr" case_profile_two

case_profile_missing_name() {
    cz_unset MAINTAINER_SLUG; cz_unset MAINTAINER_REPO
    cz_set MAINTAINER_PROFILE nosuch
    cz_mm merge 7
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr "maintainer: no deployed profile named nosuch (looked in $CZ_CASE/home/.local/share/maintainer/profiles)"
}
cz_case "profile: a named profile that is not deployed: exit 64 on stderr" case_profile_missing_name

# The profile loads before the subcommand is read, so a bad profile hides the
# usage line.
case_profile_before_usage() {
    cz_unset MAINTAINER_SLUG; cz_unset MAINTAINER_REPO
    cz_mm
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer: no profile is deployed."
    cz_expect_lacks stderr "usage:"
}
cz_case "profile: is loaded before the subcommand is read, so no arguments with no profile prints no usage line" case_profile_before_usage

# One field missing from a complete environment: the loader falls through to
# the deployed profiles even though three of the four variables are set.
case_profile_account_missing() {
    cz_unset MAINTAINER_ACCOUNT
    cz_mm merge 7
    cz_expect_rc 64
    cz_expect_stdout_empty
    cz_expect_stderr_has "maintainer: no profile is deployed."
}
cz_case "profile: three of the four MAINTAINER_* variables are not enough: exit 64" case_profile_account_missing

cz_finish
