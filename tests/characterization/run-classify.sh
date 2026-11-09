#!/usr/bin/env bash
# Characterization: the failure classifier, maintainer_classify_failure in
# lib/profile.sh, on the shipped table lib/failure-shapes.json. One case per
# shape, then the table's order, the "last match" rule, the unclassified
# fallback, every way the classifier says it could not ask, and the two
# predicates run.sh uses. Each case checks the triple "class TAB id TAB matched
# text" and the exit status by value (0 matched, 1 unclassified, 2 could not ask).
#
# Pins current behaviour. Plan decision F8 (two classifiers, bash and Python)
# starts from the output pinned here.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib-run.sh"
cz_init
rz_init

TAB="$(printf '\t')"

# classify LOGTEXT: runs the classifier on a log holding LOGTEXT; leaves the
# triple and the status in two lines of stdout: the triple, then rc=N.
classify() {
    rz_setup
    printf '%s\n' "$1" > "$CZ_CASE/x.log"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/x.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
}

SHAPE_IDS_TESTED=""
shape_case() {  # $1 id, $2 class, $3 log text, $4 matched text
    SH_ID="$1"; SH_CLASS="$2"; SH_LOG="$3"; SH_HIT="$4"
    SHAPE_IDS_TESTED="$SHAPE_IDS_TESTED $1"
    cz_case "classify: shape $1 matches '$3' as $2" case_shape
}
case_shape() {
    classify "$SH_LOG"
    cz_expect_stderr_empty
    cz_expect_stdout "$SH_CLASS${TAB}$SH_ID${TAB}$SH_HIT" "rc=0"
}

shape_case session-limit        transient   "You've hit your session limit, resets 10:10pm" "You've hit your session limit, resets 10:10pm"
shape_case usage-limit-reached  transient   "Usage limit reached. Try again later" "Usage limit reached. Try again later"
shape_case upstream-overloaded  transient   'API Error: {"type":"overloaded_error"}' "overloaded_error"
shape_case rate-limited         transient   "API Error: 429 Too Many Requests" "API Error: 429"
shape_case upstream-5xx         transient   "API Error: 503 Service Unavailable" "API Error: 503"
shape_case connection-error     transient   "read ECONNRESET" "ECONNRESET"
shape_case api-unreachable      transient   "Can't reach the API server. Check your network" "Can't reach the API server. Check your network"
shape_case dns-failure          transient   "getaddrinfo EAI_AGAIN api.example.test" "EAI_AGAIN"
shape_case gh-unreachable       transient   "error connecting to api.github.com" "error connecting to api.github.com"
shape_case oauth-expired        needs_human "OAuth session expired. Please log in again" "OAuth session expired. Please log in again"
shape_case invalid-key          needs_human "Invalid API key. Fix external API key" "Invalid API key. Fix external API key"
shape_case out-of-credit        needs_human "Your credit balance is too low to access the API" "Your credit balance is too low to access the API"
shape_case login-required       needs_human "Please run /login" "Please run /login"
shape_case backend-unconfigured needs_human "backend claude unusable: missing /x/settings.json" "backend claude unusable: missing /x/settings.json"
shape_case wrong-gh-account     needs_human "gh is authenticated as 'someone', not fxacct; refusing" "gh is authenticated as 'someone', not fxacct"
shape_case token-unpinnable     needs_human "could not pin a token for fxacct, so" "could not pin a token for fxacct"
shape_case checkout-refresh-failed transient "refresh failed, no agent run started. See x" "refresh failed, no agent run started"
shape_case lock-held            transient   "another run held the lock for over 3600s, so" "another run held the lock for over 3600s"
shape_case killed-silently      needs_human "Killed" "Killed"
shape_case no-doctrine          needs_human "preamble-core.md is missing; refusing" "preamble-core.md is missing"

# died-without-saying has the pattern (?!x)x, a lookahead that extended regular
# expressions do not have. grep rejects it, the classifier hides grep's error, and
# the shape never matches. The table's own note says it is never matched by pattern.
case_died_never_matches_rc() {
    classify "died-without-saying (?!x)x"
    cz_expect_stderr_empty
    cz_expect_stdout "unclassified${TAB}${TAB}died-without-saying (?!x)x" "rc=1"
}
cz_case "classify: shape died-without-saying never matches, even on its own id and pattern text, and grep's error stays hidden" case_died_never_matches_rc
SHAPE_IDS_TESTED="$SHAPE_IDS_TESTED died-without-saying"

# Every id in the shipped table has a case above, and no case names an id the
# table lacks, so a shape added to the table without a case fails here.
case_every_shape_has_a_case() {
    rz_setup
    local ids
    ids="$(python3 - "$RZ_TREE/lib/failure-shapes.json" <<'PYEOF'
import json, sys
print(" ".join(sorted(s["id"] for s in json.load(open(sys.argv[1]))["shapes"])))
PYEOF
    )" || { cz_note_fail "could not read the shipped table"; return 0; }
    local have; have="$(printf '%s\n' $SHAPE_IDS_TESTED | sort | tr '\n' ' ' | sed 's/ $//')"
    cz_check "shape ids in the table versus shape ids tested" "$have" "$ids"
    cz_check "number of shapes" "$(wc -w <<<"$ids" | tr -d ' ')" 21
}
cz_case "classify: the shipped table holds exactly the 21 shapes these cases cover" case_every_shape_has_a_case

# --- order, last match, case ----------------------------------------------------------

case_table_order_beats_log_order() {
    classify "OAuth session expired
API Error: {\"type\":\"overloaded_error\"}"
    cz_expect_stdout "transient${TAB}upstream-overloaded${TAB}overloaded_error" "rc=0"
}
cz_case "classify: the first shape in the table wins, whichever line of the log came first" case_table_order_beats_log_order

case_table_order_needs_human_first_in_table() {
    classify "Invalid API key. Fix external API key
connection error while reading"
    cz_expect_stdout "transient${TAB}connection-error${TAB}connection error" "rc=0"
}
cz_case "classify: a transient shape listed before a needs-human one wins over it (the table decides, not severity)" case_table_order_needs_human_first_in_table

case_last_match_of_shape() {
    classify "You've hit your session limit, resets 8am
other line
You've hit your session limit, resets 10pm"
    cz_expect_stdout "transient${TAB}session-limit${TAB}You've hit your session limit, resets 10pm" "rc=0"
}
cz_case "classify: within one shape the last matching text in the log is reported" case_last_match_of_shape

case_ignore_case() {
    classify "USAGE LIMIT REACHED NOW"
    cz_expect_stdout "transient${TAB}usage-limit-reached${TAB}USAGE LIMIT REACHED NOW" "rc=0"
}
cz_case "classify: matching ignores case and reports the text as written" case_ignore_case

case_bounded_tail() {
    local pad; pad="$(printf 'x%.0s' $(seq 1 80))"
    classify "usage limit reached ${pad}"
    cz_expect_stdout "transient${TAB}usage-limit-reached${TAB}usage limit reached $(printf 'x%.0s' $(seq 1 59))" "rc=0"
}
cz_case "classify: the trailing {0,60} of a shape cuts the matched text at 60 characters after the phrase" case_bounded_tail

case_binary_log() {
    rz_setup
    printf 'binary\0prefix\nKilled\n' > "$CZ_CASE/x.log"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/x.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "needs_human${TAB}killed-silently${TAB}Killed" "rc=0"
}
cz_case "classify: a log with a NUL byte is still read as text" case_binary_log

# --- unclassified ---------------------------------------------------------------------

case_unclassified_error_line() {
    classify "all fine
something failed here
the last line"
    cz_expect_stdout "unclassified${TAB}${TAB}something failed here" "rc=1"
}
cz_case "classify: no shape matching gives 'unclassified' with the last line holding error, fail, panic, refus, denied, cannot or could not; status 1" case_unclassified_error_line

case_unclassified_last_line() {
    classify "all fine
the last line"
    cz_expect_stdout "unclassified${TAB}${TAB}the last line" "rc=1"
}
cz_case "classify: with no error-shaped line the evidence is the last line of the log" case_unclassified_last_line

case_unclassified_empty() {
    rz_setup
    : > "$CZ_CASE/x.log"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/x.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "unclassified${TAB}${TAB}the log says nothing" "rc=1"
}
cz_case "classify: an empty log is 'unclassified' with 'the log says nothing', status 1" case_unclassified_empty

# --- could not ask ---------------------------------------------------------------------

case_unreadable_missing_log() {
    rz_setup
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/nope.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "unreadable${TAB}${TAB}no readable log at '$CZ_CASE/nope.log'" "rc=2"
}
cz_case "classify: a log that does not exist is 'unreadable', status 2" case_unreadable_missing_log

case_unreadable_no_argument() {
    rz_setup
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure)"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "unreadable${TAB}${TAB}no readable log at ''" "rc=2"
}
cz_case "classify: no argument is 'unreadable' with an empty path, status 2" case_unreadable_no_argument

case_unreadable_no_table() {
    rz_setup
    rm "$RZ_TREE/lib/failure-shapes.json"
    printf 'Killed\n' > "$CZ_CASE/x.log"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/x.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "unreadable${TAB}${TAB}no failure-shapes table on this host" "rc=2"
}
cz_case "classify: no failure-shapes.json anywhere is 'unreadable', status 2, never 'nothing matched'" case_unreadable_no_table

case_unreadable_bad_table() {
    rz_setup
    printf 'this is not json\n' > "$CZ_CASE/bad.json"
    printf 'Killed\n' > "$CZ_CASE/x.log"
    cz_set MAINTAINER_FAILURE_SHAPES "$CZ_CASE/bad.json"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/x.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "unreadable${TAB}${TAB}failure-shapes table at $CZ_CASE/bad.json could not be parsed" "rc=2"
}
cz_case "classify: a table that is not JSON is 'unreadable', status 2" case_unreadable_bad_table

case_unreadable_missing_override() {
    rz_setup
    printf 'Killed\n' > "$CZ_CASE/x.log"
    cz_set MAINTAINER_FAILURE_SHAPES "$CZ_CASE/gone.json"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/x.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "unreadable${TAB}${TAB}failure-shapes table at $CZ_CASE/gone.json could not be parsed" "rc=2"
}
cz_case "classify: MAINTAINER_FAILURE_SHAPES naming a missing file is used as given and reads as unparsable, status 2" case_unreadable_missing_override

case_unreadable_no_shapes() {
    rz_setup
    printf '{"shapes": []}\n' > "$CZ_CASE/empty.json"
    printf 'Killed\n' > "$CZ_CASE/x.log"
    cz_set MAINTAINER_FAILURE_SHAPES "$CZ_CASE/empty.json"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/x.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "unreadable${TAB}${TAB}failure-shapes table at $CZ_CASE/empty.json lists no shapes" "rc=2"
}
cz_case "classify: a table with no shapes is 'unreadable', status 2" case_unreadable_no_shapes

case_override_table() {
    rz_setup
    printf '{"shapes": [{"id": "my-shape", "class": "needs_human", "pattern": "boom [0-9]+"}]}\n' > "$CZ_CASE/mine.json"
    printf 'it went boom 42 today\nKilled\n' > "$CZ_CASE/x.log"
    cz_set MAINTAINER_FAILURE_SHAPES "$CZ_CASE/mine.json"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; out="$(maintainer_classify_failure "$CZ_CASE_DIR/x.log")"; rc=$?; printf "%s\nrc=%s\n" "$out" "$rc"'
    cz_expect_stdout "needs_human${TAB}my-shape${TAB}boom 42" "rc=0"
}
cz_case "classify: MAINTAINER_FAILURE_SHAPES replaces the shipped table whole" case_override_table

# --- the two predicates run.sh asks -------------------------------------------------------

predicates() {  # $1 = log text; prints "transient=<text|-> rc" and "human=<text|-> rc"
    rz_setup
    printf '%s\n' "$1" > "$CZ_CASE/x.log"
    rz_drive '. "$RZ_TREE/lib/profile.sh"; t="$(backend_transient_reason "$CZ_CASE_DIR/x.log")"; trc=$?; h="$(backend_needs_human_reason "$CZ_CASE_DIR/x.log")"; hrc=$?; printf "transient=%s rc=%s\nhuman=%s rc=%s\n" "$t" "$trc" "$h" "$hrc"'
}

case_predicate_transient() {
    predicates "API Error: 503 Service Unavailable"
    cz_expect_stdout "transient=API Error: 503 rc=0" "human= rc=1"
}
cz_case "predicates: a transient shape answers backend_transient_reason with the matched text and not the other" case_predicate_transient

case_predicate_human() {
    predicates "Invalid API key. Fix external API key"
    cz_expect_stdout "transient= rc=1" "human=Invalid API key. Fix external API key rc=0"
}
cz_case "predicates: a needs-human shape answers backend_needs_human_reason and not the other" case_predicate_human

case_predicate_unclassified() {
    predicates "just a plain failure"
    cz_expect_stdout "transient= rc=1" "human= rc=1"
}
cz_case "predicates: an unclassified log answers neither" case_predicate_unclassified

case_predicate_unreadable() {
    rz_setup
    rz_drive '. "$RZ_TREE/lib/profile.sh"; t="$(backend_transient_reason "$CZ_CASE_DIR/none.log")"; trc=$?; h="$(backend_needs_human_reason "$CZ_CASE_DIR/none.log")"; hrc=$?; printf "transient=%s rc=%s\nhuman=%s rc=%s\n" "$t" "$trc" "$h" "$hrc"'
    cz_expect_stdout "transient= rc=1" "human= rc=1"
}
cz_case "predicates: an unreadable log answers neither, so it is never called transient" case_predicate_unreadable

cz_finish
