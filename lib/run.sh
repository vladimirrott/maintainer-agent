#!/usr/bin/env bash
# Run one unattended maintenance pass and leave an auditable trail.
#
# Usage: run.sh <profile> <task>
#
# Refuses to start as the wrong GitHub account, refuses to start on a failed
# refresh, refuses to finish without a report, and notifies the desktop on any
# failure so a broken timer cannot fail quietly for a week.
set -uo pipefail

# Wrapped in a function on purpose: bash reads a script incrementally by byte
# offset, so editing this file while a run is in flight corrupts the running
# copy. That happened on 2026-09-02 and killed a finished run with
# "unexpected EOF" after 17 minutes of real work, having already posted three
# comments. A function is parsed whole before it executes, so an edit can no
# longer reach a live run.
main() {

# Resolve the tree we were installed into. In the repository this file is
# lib/run.sh, so profiles live one level up; installed, it sits beside them.
# Checking both is what makes `./install.sh` and a git checkout behave the same.
# Getting this wrong is silent: the unit exits 64 and the timer logs nothing.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if   [ -d "$here/profiles" ];    then local_root="$here"
elif [ -d "$here/../profiles" ]; then local_root="$(cd "$here/.." && pwd)"
else echo "run.sh: cannot find a profiles/ directory beside or above $here" >&2; exit 64
fi
# Backends move with the same ambiguity: lib/backends in the repository,
# backends/ beside run.sh once installed.
if   [ -d "$local_root/backends" ];     then BACKEND_DIR="$local_root/backends"
elif [ -d "$local_root/lib/backends" ]; then BACKEND_DIR="$local_root/lib/backends"
else echo "run.sh: cannot find a backends/ directory under $local_root" >&2; exit 64
fi
# --show-prompt assembles the prompt and prints it, touching nothing. It is the
# answer to "what exactly does this thing tell an agent to do in my name", and
# it must stay the SAME assembly the run uses, not a copy: a preview that
# reassembles the prompt its own way is a preview of a different agent.
show=0
if [ "${1:-}" = "--show-prompt" ]; then show=1; shift; fi
profile="${1:?usage: run.sh [--show-prompt] <profile> <task>}"
task="${2:?usage: run.sh [--show-prompt] <profile> <task>}"

# A run must not start inside another run.
#
# The agent inherits this process's environment, so `run.sh` is reachable from
# inside a pass: nothing stopped one profile's rehearsal from launching a full
# run of another. That it stayed a rehearsal was luck, because MAINTAINER_POST
# happened to be inherited too. Refuse instead of relying on that.
#
# A preview is exempt: reading the prompt from inside a run is harmless.
if [ -n "${MAINTAINER_IN_RUN:-}" ] && [ "$show" = 0 ]; then
    echo "run.sh: already inside the run '$MAINTAINER_IN_RUN'; refusing to start" \
         "'$profile/$task' from within it" >&2
    exit 78
fi

PROFILE_DIR="$local_root/profiles/$profile"
[ -f "$PROFILE_DIR/profile.env" ] || { echo "run.sh: no profile '$profile'" >&2; exit 64; }
# shellcheck disable=SC1091
. "$PROFILE_DIR/profile.env"
export PROFILE_DIR REPO_PATH
# ACCOUNT and PROD_GLOBS travel too: maintainer-merge reads both, and a tool
# called from inside a run must not have to re-derive what the run already knows.
export MAINTAINER_REPO="$REPO_PATH" MAINTAINER_SLUG="$REPO_SLUG" MAINTAINER_STATE="$STATE_DIR"
export MAINTAINER_ACCOUNT="$GH_ACCOUNT" PROD_GLOBS="${PROD_GLOBS:-}"
export CLAIM_LABEL="${CLAIM_LABEL:-}"
# And the profile name itself. bin/maintainer stopped defaulting to a hardcoded
# profile in v0.2.0 and now enumerates the deployed ones and refuses when two
# are present, which is right. But run.sh calls `maintainer start` without
# saying which profile it is running, so from 07:38 on the day v0.2.0 was
# deployed EVERY scheduled run died with "2 profiles are deployed; set
# MAINTAINER_PROFILE". It failed closed and alerted, which is the only reason
# this is a story about an hour rather than about a week.
#
# The test that should have caught it replaces `maintainer` with a stub that
# ignores its environment, so it measured run.sh talking to a helper that cannot
# fail this way.
export MAINTAINER_PROFILE="$profile"
# scripts/ sits under local_root in both layouts: repo/scripts, and $share/scripts
# once installed. local_root already accounts for the difference.
[ -d "$local_root/scripts" ] && export MAINTAINER_SCRIPTS="$local_root/scripts"

case " $TASKS " in *" $task "*) ;; *) echo "run.sh: unknown task '$task'" >&2; exit 64 ;; esac
model_var="MODEL_$task"; model="${!model_var:?no model configured for $task}"
# The helper takes its task list and skill label from the profile rather than
# from a dict in its own source, so a second repository needs no code change.
skill_var="SKILL_$task"
export MAINTAINER_TASKS="$TASKS" MAINTAINER_SKILL="${!skill_var:-}"
# The backend reads THINKING_<task> out of the profile.
export MAINTAINER_TASK="$task"

# The scheduler is not the only thing that decides cadence, because not every
# scheduler can express one. systemd says "every 5 days" and means it; launchd's
# StartCalendarInterval cannot say it at all, so the macOS agents fire daily,
# and cron's day-of-month stepping runs on the 31st and again on the 1st. Until
# this gate existed, the macOS installer claimed the since-last-run state
# enforced the cadence. Nothing did: `audit` would have run five times a week.
#
# The baseline is promoted by `finish` only on success, so a run that failed
# does not lock out its own retry.
# $1, when given, says where this call happened, so a run superseded while it
# queued does not read like a run the scheduler suppressed.
min_gate() {
    [ "${forced:-0}" = 1 ] && return 0
    # Two statements, not one. `local a=X b=${!a}` expands every word before the
    # builtin assigns any of them, so the indirect reference sees an unset name
    # and bash reports "invalid indirect expansion". The gate then fell through
    # and every task ran regardless of its interval.
    local var min
    var="MIN_HOURS_$task"
    min="${!var:-0}"
    [ "$min" = 0 ] && return 0
    local f="$STATE_DIR/state/last-$task.json"
    [ -f "$f" ] || return 0
    local last now age
    last="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$(( (now - last) / 3600 ))
    if [ "$age" -lt "$min" ]; then
        printf 'skipped: %s last ran %dh ago, minimum is %dh%s (MAINTAINER_FORCE=1 overrides)\n' \
            "$task" "$age" "$min" "${1:+, $1}"
        exit 0
    fi
}
# Read once into a shell variable, because the gate is consulted a second time
# after the lock and MAINTAINER_FORCE is unset before then.
forced=0
[ "${MAINTAINER_FORCE:-0}" = 1 ] && forced=1
[ "$show" = 1 ] || min_gate
# The override is consumed here and must not travel any further. It reached the
# agent's environment, so every `run.sh` the agent invoked skipped its cadence
# gate: a repro that should have printed "skipped" started a real pass instead.
unset MAINTAINER_FORCE
# And mark this process, so anything started from inside it can tell.
export MAINTAINER_IN_RUN="$profile/$task"

stamp="$(date +%Y-%m-%dT%H-%M)"
if [ "$show" = 1 ]; then
    # A preview leaves no trace. Without this the suite's --show-prompt calls
    # opened a log file per task in the live state directory, and 22 empty logs
    # landed in the real audit trail during a single test run.
    log=/dev/null
else
    logs="$STATE_DIR/logs"; mkdir -p "$logs"
    log="$logs/$stamp-$task.log"
fi
# ~/.cargo/bin too: rustup puts the toolchain there and a systemd user unit
# does not read the shell profile that adds it. An unattended ci run on
# 2026-09-07 hit `cargo: command not found` (rc=127) on its first command and
# prefixed PATH by hand for every Rust gate after it.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# One notification shape, for the failure and the success alike.
#
# The old one passed the raw error string straight to notify-send, so what
# reached the desktop was
#
#   maintainer: sysknife/review failed
#   backend claude unusable: missing /home/<user>/<a long absolute path>/settings.json
#
# which is a shell message, not a message to a person. It said what broke in the
# vocabulary of the thing that broke, gave no next step, and spent two thirds of
# its width on an absolute path. And there was no notification at all for a run
# that SUCCEEDED, so the only time this agent spoke to its owner was to complain.
notify() {  # $1 = urgency, $2 = title, $3.. = body lines
    local urgency="$1" title="$2"; shift 2
    local body; body="$(printf '%s\n' "$@")"
    DISPLAY="$(session_display)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
        notify-send -u "$urgency" -a maintainer "$title" "$body" 2>/dev/null || true
}

# Turn what broke into what to do about it. Anything unmatched falls through
# verbatim, because a wrong translation is worse than an untranslated string.
humanise() {  # $1 = raw message -> "sentence\nfix: command"
    case "$1" in
        *"unusable: missing"*settings*|*"unusable: missing"*opencode*)
            printf 'Claude Code has no settings file for this profile.\nfix  ./install.sh' ;;
        *"not on PATH"*)
            printf '%s\nfix  install it, then: maintainer-doctor' "$1" ;;
        *"refresh failed"*)
            printf 'The checkout could not be refreshed, so no agent ran.\nfix  maintainer-doctor' ;;
        *"held the lock"*)
            printf 'Another run held the shared tree for over %ss.\nfix  maintainer status, then wait or kill it' "$LOCK_WAIT" ;;
        *"authenticated as"*)
            printf '%s\nfix  gh auth switch --user %s' "$1" "$GH_ACCOUNT" ;;
        *"produced no report"*)
            printf 'The run ended without writing a report, so it is not auditable.\nfix  read the log below' ;;
        *"cannot enforce POST=off"*)
            printf '%s\nfix  set BACKEND=claude or BACKEND=opencode in profile.env' "$1" ;;
        *"no rehearsal wall"*)
            printf 'POST=off, but no rehearsal deny wall is deployed for this profile.\nfix  ./install.sh' ;;
        *) printf '%s' "$1" ;;
    esac
}

# The display, asked for rather than assumed.
#
# This hardcoded DISPLAY=:1, which is right on one machine and wrong on a
# session that is :0, on Wayland with no XWayland, on a headless box, and while
# nobody is logged in, which is exactly the state `loginctl enable-linger`
# creates. Combined with the trailing `|| true` on notify-send, a nightly
# failure could reach nobody and say nothing about it.
session_display() {
    local d
    d="$(loginctl show-session "$(loginctl show-user "$USER" -p Display --value 2>/dev/null)" \
         -p Display --value 2>/dev/null)"
    printf '%s' "${d:-${DISPLAY:-:0}}"
}

# A failure that retries itself, reported without interrupting anybody.
#
# 2026-09-08 produced six unit failures and up to twelve critical desktop
# popups, because each one alerts twice: this file calls `alert`, then exits
# non-zero and systemd's OnFailure fires platform/linux/alert.sh for a second.
# All six were `gh could not reach GitHub` or a lock wait expiring. Both are
# already in failed-<task>.json, already reported by maintainer-doctor, and
# already retried by the catch-up slot every timer carries.
#
# The record is unchanged. Only the urgency drops, because a critical popup six
# times a day for a condition that heals itself teaches you to dismiss the one
# that matters.
alert_transient() {
    printf '%s\n' "$1" | tee -a "$log" >&2
    "$HELPER" failed "$task" "$1" "$log" >/dev/null 2>&1 || \
        printf 'run.sh: could not even record the failure marker\n' >&2
    notify low "maintainer · $profile $task · will retry" \
        "$(humanise "$1")" "log  $log"
}

alert() {
    printf '%s\n' "$1" | tee -a "$log" >&2
    # 1. Disk first. No display, no bus, no network, no way for this to be
    #    swallowed. `maintainer status` prints it in red at the top until a
    #    successful run of the same task clears it.
    "$HELPER" failed "$task" "$1" "$log" >/dev/null 2>&1 || \
        printf 'run.sh: could not even record the failure marker\n' >&2
    # 2. Desktop, best effort.
    notify critical "maintainer · $profile $task · FAILED" \
        "$(humanise "$1")" "log  $log"
    # 3. Whatever the site uses. ntfy, mail, a webhook: the profile names it,
    #    because a notification channel is site-specific and this file is not.
    #    Failure here is reported and never fatal; an alert path that can abort
    #    a run is worse than no alert path.
    if [ -n "${MAINTAINER_ALERT_CMD:-}" ]; then
        if ! MAINTAINER_ALERT_TASK="$profile/$task" MAINTAINER_ALERT_LOG="$log" \
             sh -c "$MAINTAINER_ALERT_CMD" "$0" "$1" >>"$log" 2>&1; then
            printf 'run.sh: MAINTAINER_ALERT_CMD failed; the marker and the log still stand\n' \
                >>"$log"
        fi
    fi
}

# Rehearsal: the agent does the whole run and reaches nobody.
#
# A first run that posts is the reason people do not try an unattended
# maintainer at all. With POST=off the backend gets a deny wall that also blocks
# every verb that writes to GitHub, and the prompt says so, so the agent stops
# rather than retrying around a refusal it does not expect. Both, because the
# prompt alone is a request and the wall alone produces a confused run.
POST="${POST:-on}"
# Exported, because the wall governs what the AGENT types and not what the
# tools it may call then do. `maintainer-repo prune` pushes branch deletions
# from inside a script, which no Bash deny rule can see, so a rehearsal would
# have deleted remote branches while reporting that it reached nobody.
export MAINTAINER_POST="$POST"
# The backend is sourced BEFORE the rehearsal wall is chosen, because it is the
# thing that knows where its own wall is and which variable it reads to find it.
# shellcheck disable=SC1090
. "$BACKEND_DIR/$BACKEND.sh" || { alert "no backend '$BACKEND'"; exit 64; }

# A backend with no per-command control cannot honour POST=off. Saying so is the
# only honest option: a rehearsal that silently posts is worse than no rehearsal.
if [ "$show" = 0 ] && [ "$POST" = off ] && ! declare -F backend_rehearsal >/dev/null; then
    alert "backend '$BACKEND' cannot enforce POST=off (no per-command deny list); use claude or opencode"
    exit 78
fi

if [ "$POST" = off ]; then
    # Asked, not guessed. This used to test for two filenames,
    # settings-rehearsal.json and opencode-rehearsal.json, and pick the first
    # that existed. The cursor backend reads CURSOR_CONFIG_DIR through
    # MAINTAINER_CURSOR_DIR, which nothing in the tree ever set, so a POST=off
    # run there was handed profiles/<p>/cursor, the LIVE wall, while
    # cursor-rehearsal sat rendered and unread beside it. An enumeration that
    # has to be updated for every backend is an enumeration that goes stale
    # silently, and this one did.
    if declare -F backend_rehearsal_wall >/dev/null && backend_rehearsal_wall; then
        :
    elif [ "$show" = 1 ]; then
        echo "run.sh: (preview) no rehearsal wall is rendered in this tree; a real" >&2
        echo "        run would refuse here. ./install.sh renders it." >&2
    else
        echo "run.sh: POST=off but backend '$BACKEND' has no rehearsal wall rendered for '$profile'" >&2
        echo "        re-run ./install.sh, which renders it beside the live wall" >&2
        exit 78
    fi
fi

# The deployed tree stamps itself at install time. A run report that does not
# say which build produced it is a report you cannot act on six weeks later.
MAINTAINER_VERSION="$(sed -n 's/^version=//p' "$local_root/VERSION" 2>/dev/null || true)"
MAINTAINER_VERSION="${MAINTAINER_VERSION:-unstamped}"
MAINTAINER_COMMIT="$(sed -n 's/^commit=//p' "$local_root/VERSION" 2>/dev/null || true)"
MAINTAINER_COMMIT="${MAINTAINER_COMMIT:-unknown}"
export MAINTAINER_VERSION MAINTAINER_COMMIT
{
    echo "=== run.sh $profile/$task $(date -Is) ==="
    echo "maintainer=$MAINTAINER_VERSION backend=$(backend_name) model=$model log=$log"
} >>"$log"

if [ "$show" = 0 ] && ! msg="$(backend_check)"; then
    alert "backend $BACKEND unusable: $msg"
    exit 1
fi

# A backend may declare the only tasks it is fit for. Cursor does, because its
# non-interactive mode has full write access and no per-command deny list, so it
# must never be handed a task that can post, publish or merge. Enforced here
# rather than trusted to a comment in the backend file.
if declare -F backend_allowed_tasks >/dev/null; then
    allowed="$(backend_allowed_tasks)"
    case " $allowed " in
        *" $task "*) ;;
        *) alert "backend '$BACKEND' may only run: $allowed (refused '$task')"; exit 78 ;;
    esac
fi

if [ "$show" = 0 ]; then

# Every task shares one working tree and `maintainer start` checks out main.
# Two at once would fight over HEAD and over target/, and the loser would review
# a tree it did not create. Wait rather than fail: a skipped run is a silent gap
# in the audit trail.
exec 9>"$STATE_DIR/run.lock"
if ! flock -w "$LOCK_WAIT" 9; then
    # 75, not 1. Another run of this profile is still working; this one is
    # superseded rather than broken, and the next catch-up slot picks it up.
    alert_transient "another run held the lock for over ${LOCK_WAIT}s, so this one never started"
    exit 75
fi

# And read the cadence gate again, now that we hold the lock.
#
# The gate above ran before the wait. On 2026-09-07 `install.sh --timers` fired a
# Persistent=true catch-up for `issues` at 20:09; a second run launched at 20:23
# passed the gate against a stamp two days old, blocked here for eleven minutes,
# took the lock one second after the first run promoted that stamp, and began a
# full duplicate pass. It stopped only because the backend hit a session limit.
# Every run that queues decides its cadence on a stamp the run ahead of it is
# about to replace, and giving each timer a catch-up slot makes queueing more
# likely rather than less.
min_gate "after waiting for the lock"

# 0. Pin the GitHub identity and refuse to run without it.
#
# `gh`'s active account has been observed flipping back to a different account
# on its own, rewriting the `user:` key in ~/.config/gh/hosts.yml. Unattended
# that is worse than a 403: a merge would fail loudly, but reviews and issue
# comments would post successfully under the wrong identity.
gh auth switch --hostname github.com --user "$GH_ACCOUNT" >>"$log" 2>&1 || true
# Two different emergencies, and this used to report both as the second one.
# On 2026-09-05 the 09:15 sysknife review and the 09:20 magent review both died
# on `error connecting to api.github.com`, and the alert that woke the human
# read "gh is authenticated as 'unknown', not vladimirrott", which sends you
# hunting for a revoked token in the middle of a network outage.
#
# An outage is transient, so it is retried. A wrong account is not, so it is
# refused on the first answer and never retried into: retrying that would be
# waiting for a different identity to show up, which is the one thing this gate
# exists to prevent.
gh_tries="${MAINTAINER_GH_TRIES:-3}"
gh_backoff="${MAINTAINER_GH_BACKOFF:-20}"
gh_login=""
attempt=1
while :; do
    gh_login="$(gh api user --jq .login 2>>"$log" || true)"
    [ -n "$gh_login" ] && break
    [ "$attempt" -ge "$gh_tries" ] && break
    printf 'gh api user gave no answer (try %s of %s); retrying\n' "$attempt" "$gh_tries" >>"$log"
    [ "$gh_backoff" -gt 0 ] && sleep "$((attempt * gh_backoff))"
    attempt=$((attempt + 1))
done
if [ -z "$gh_login" ]; then
    # 75 is EX_TEMPFAIL: nothing is wrong with the credentials, the run could
    # not ask. The next timer tick is the fix, so this must not read as a
    # refusal in the journal.
    alert_transient "gh could not reach GitHub in $gh_tries tries, so the identity was never verified and nothing ran. Check the network, not the token. See $log"
    exit 75
fi
if [ "$gh_login" != "$GH_ACCOUNT" ]; then
    alert "gh is authenticated as '$gh_login', not $GH_ACCOUNT; refusing to run. See $log"
    exit 1
fi
printf 'gh identity: %s\n' "$gh_login" >>"$log"

# Pin the run to THIS account's token, not just to the active-account switch
# above. The keyring on this machine holds more than one account, and the active
# one has flipped on its own mid-run and posted to a personal repository under
# the wrong identity. The switch and the check above run once, at the start; a
# flip after them still posts as somebody else.
#
# With GH_TOKEN exported for the whole run, every gh call, the agent's included,
# authenticates with this token and no `gh auth switch` can select another
# account (measured: a switch to a different user is ignored while GH_TOKEN is
# set). The token stays in this process's environment and is never written to
# disk. A run that cannot pin its identity refuses rather than risk the flip.
pinned_token="$(gh auth token --user "$GH_ACCOUNT" 2>>"$log" || true)"
if [ -z "$pinned_token" ]; then
    alert "could not pin a token for $GH_ACCOUNT, so this run's identity is not guaranteed for the whole pass; refusing rather than risk posting as another account. See $log"
    exit 1
fi
export GH_TOKEN="$pinned_token"
unset GITHUB_TOKEN
# `|| true` here turned "the token could not be resolved" into "the token
# resolved to nothing", and the empty string then passed the `-n` test below and
# fell through to a log line announcing the identity as pinned. The log recorded
# a verification that had not happened, which is worse than not checking: it
# reads as evidence afterwards.
pinned_rc=0
pinned_login="$(gh api user --jq .login 2>>"$log")" || pinned_rc=$?
if [ "$pinned_rc" -ne 0 ] || [ -z "$pinned_login" ]; then
    # 75, not 1: nothing is wrong with the credentials, the run could not ask.
    alert_transient "the pinned token could not be resolved to an account (gh exited $pinned_rc), so this run's identity was never confirmed and nothing ran. See $log"
    exit 75
fi
if [ "$pinned_login" != "$GH_ACCOUNT" ]; then
    alert "the pinned token resolves to '$pinned_login', not $GH_ACCOUNT; refusing to run. See $log"
    exit 1
fi
printf 'gh identity pinned by token for the whole run: %s\n' "$GH_ACCOUNT" >>"$log"

# 0b. Provision a dedicated review checkout, isolated from any dev tree.
#
# A review bot must own the tree it reviews. When REPO_PATH was a working copy a
# human also edits, two things broke: a run fired while the tree was dirty and
# `refresh` aborted, leaving a silent gap; and a run reviewed whatever branch the
# tree happened to be on rather than main. With POST=on and issue-filing, a run
# against a half-edited tree could file issues about uncommitted experiments.
#
# So REPO_PATH points at a checkout this profile owns, and if it is missing this
# clones it from REPO_ORIGIN. The clone tracks origin/main and nothing else
# touches it, so `refresh` always finds a clean tree on main.
if [ ! -d "$REPO_PATH/.git" ]; then
    if [ -n "${REPO_ORIGIN:-}" ]; then
        printf 'provisioning review checkout: %s -> %s\n' "$REPO_ORIGIN" "$REPO_PATH" >>"$log"
        if ! git clone --quiet "$REPO_ORIGIN" "$REPO_PATH" >>"$log" 2>&1; then
            alert "could not clone $REPO_ORIGIN into $REPO_PATH; no review checkout, nothing ran. See $log"
            exit 1
        fi
    else
        alert "$REPO_PATH is not a git checkout and the profile sets no REPO_ORIGIN to clone from; refusing to run. See $log"
        exit 1
    fi
fi

# 1. Refresh the checkout and compute what moved since the last run of this task.
if ! context="$("$HELPER" start "$task" 2>&1)"; then
    printf '%s\n' "$context" >>"$log"
    alert "refresh failed, no agent run started. See $log"
    exit 1
fi
printf '%s\n' "$context" >>"$log"

run_id="$(printf '%s\n' "$context" | sed -n 's/^=== [a-z-]* \(.*\) ===$/\1/p' | head -1)"
if [ -z "$run_id" ]; then
    alert "could not parse a run id from '$HELPER start'. See $log"
    exit 1
fi

# The log was named from this script's start time, minutes before the lock was
# taken; the run id is minted by `maintainer start`, after it. With no
# contention both land in the same minute and the difference is invisible. On
# 2026-09-05 a review waited nine minutes behind an issues sweep and wrote
# logs/...10-47-review.log beside runs/...10-56-review.md, which `maintainer
# audit` read as two broken runs: one that started and never reported, and one
# whose report quotes no executed command, because its transcript was filed
# under the other name. Reconciled here, keeping everything the pre-lock log
# already recorded (the wait itself is in there).
log_by_id="$logs/$run_id.log"
if [ "$log" != "$log_by_id" ]; then
    if [ -e "$log_by_id" ]; then
        # Never clobber an existing run's transcript; fold into it instead.
        cat "$log" >>"$log_by_id" && rm -f "$log"
    else
        mv "$log" "$log_by_id"
    fi
    log="$log_by_id"
    printf 'log renamed to match run id %s\n' "$run_id" >>"$log"
fi

else
    context="(preview only: no refresh ran, so nothing here reflects the tracker)"
    run_id="preview"
fi

# 2. preamble + task prompt + freshly computed context, in that order. Written
#    to a file rather than piped from a variable so the backend can choose
#    stdin or an argument without the caller caring.
prompt_file="$(mktemp)"
trap 'rm -f "$prompt_file"' RETURN

# lib/ files sit under lib/ in the repository and beside run.sh once installed.
libfile() {
    if   [ -f "$local_root/lib/$1" ]; then printf '%s' "$local_root/lib/$1"
    elif [ -f "$local_root/$1" ];     then printf '%s' "$local_root/$1"
    else return 1; fi
}
# The core preamble carries the injection rule, the screen rule and the evidence
# rule. A run without it is an unattended agent with no doctrine, so this fails
# closed rather than continuing with a shorter prompt.
core="$(libfile preamble-core.md)" || {
    alert "preamble-core.md is missing; refusing to run without the doctrine"
    exit 1
}
prose="$(libfile prose-style.md || true)"

{
    # 0. Provenance, first, because the doctrine tells the agent to open its
    #    report with the build that wrote it and this is the only place that
    #    build appears. Without these lines the instruction pointed at nothing,
    #    and 2026-09-04T21-17-review stamped itself v0.3.0/10a7e79 while running
    #    v0.4.0/111592c: the only version anywhere in reach was the one in the
    #    previous report, so it copied that. A wrong stamp sends an audit to
    #    code that never ran, which is worse than no stamp at all.
    printf 'Provenance for this run: maintainer %s (commit %s), profile %s, task %s, backend %s, started %s.\n' \
        "$MAINTAINER_VERSION" "$MAINTAINER_COMMIT" "$profile" "$task" "$(backend_name)" "$(date -Is)"
    printf 'Open your run report with that version and that commit, copied from this line. Do not copy them from an earlier report; an earlier report was written by an earlier build.\n\n'
    # 1. Who this profile is, and what it is authorised to do.
    cat "$PROFILE_DIR/prompts/common-preamble.md"
    printf '\n\n'
    # 2. The doctrine, shared by every profile so it cannot drift between repos.
    sed -e "s|__MAINTAINER__|${MAINTAINER_NAME:-the maintainer}|g" \
        -e "s|__SLUG__|$REPO_SLUG|g" "$core"
    printf '\n\n'
    # 3. Prose discipline. Opt-OUT, not opt-in: anything other than an explicit
    #    "raw" gets it, so a missing or misspelled value still writes well.
    if [ "${PROSE_STYLE:-stop-slop}" != "raw" ] && [ -n "$prose" ]; then
        cat "$prose"
        printf '\n\n'
    fi
    # 4. Rehearsal, last before the task so it overrides anything above it.
    if [ "$POST" = off ]; then
        cat <<'REHEARSAL'
## This run is a REHEARSAL. Post nothing.

Do the whole pass: read, verify, recount, form the conclusions you would
publish. Then write them into the run report and the drafts directory instead
of into GitHub. Every posting command is blocked by the settings file, so a
refusal here is the rehearsal working. Do not look for another way to send it.

In the report, list what you WOULD have posted and where, so the maintainer can
read it and decide whether to turn posting on.
REHEARSAL
        printf '\n\n'
    else
        # The other direction, which used to be silent. A prompt that says
        # nothing about posting leaves whatever a profile's own preamble happens
        # to claim as the only statement on it, and on 2026-09-07 that claim was
        # a stale POST=off in front of a run that posted five issues. The state
        # is the environment's to declare, so it is declared here, from the
        # value actually in force.
        cat <<POSTING
## This run POSTS. Say it once, in public, under a real name.

Writes go to $REPO_SLUG as $GH_ACCOUNT, immediately and for real. There is no
rehearsal in front of you: a comment is delivered as you send it, an edit keeps
its history, and a notification cannot be recalled. \`MAINTAINER_POST\` is
\`$POST\` in your environment, and that variable is the answer, not any
sentence you read in a prompt.

Verify before you write, and read back what you wrote.
POSTING
        printf '\n\n'
    fi
    # 5. The task, then what changed since this task last ran.
    cat "$PROFILE_DIR/prompts/$task.md"
    printf '\n\n## Context for this run, computed just now\n\n```\n%s\n```\n' "$context"
} > "$prompt_file"

if [ "$show" = 1 ]; then
    cat "$prompt_file"
    exit 0
fi

# 3. Hand it to the backend. Wall-clock is bounded by systemd, not here.
cd "$REPO_PATH" || { alert "cannot cd to $REPO_PATH"; exit 1; }
if ! backend_run "$prompt_file" "$model" "$log" "$STATE_DIR"; then
    alert "$BACKEND exited non-zero for $run_id. See $log"
    # Fall through: a partial report is better than none.
fi

# 4. Close the run. `finish` refuses an empty report, which is the point.
if ! "$HELPER" finish "$run_id" >>"$log" 2>&1; then
    # Write the absence into the index BEFORE alerting, so the record exists
    # whatever happens to the alert. A gap in the index is indistinguishable
    # from a run that never started, and this run demonstrably started: it has
    # a log, and it may already have posted.
    "$HELPER" abort "$run_id" "the run wrote no usable report" >>"$log" 2>&1 || true
    alert "$run_id produced no report; the run is not auditable. See $log"
    exit 1
fi

# 5. Say what happened, to a person. An unattended agent that only ever speaks
#    when it fails trains its owner to read every notification as bad news, and
#    leaves the ordinary question -- did it run, what did it cost -- answerable
#    only by opening a log. The digest is built from what the run MEASURED: its
#    own line count, its own command record, and the usage the model reported.
digest="$("$HELPER" digest "$run_id" --compact 2>/dev/null)" || digest=""
if [ -n "$digest" ]; then
    printf '\n=== digest ===\n%s\n' "$digest" >>"$log"
    notify normal "maintainer · $profile $task" "$digest"
fi

echo "=== done $(date -Is) ===" >>"$log"

}

main "$@"
