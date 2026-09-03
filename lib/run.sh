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
profile="${1:?usage: run.sh <profile> <task>}"
task="${2:?usage: run.sh <profile> <task>}"

PROFILE_DIR="$local_root/profiles/$profile"
[ -f "$PROFILE_DIR/profile.env" ] || { echo "run.sh: no profile '$profile'" >&2; exit 64; }
# shellcheck disable=SC1091
. "$PROFILE_DIR/profile.env"
export PROFILE_DIR REPO_PATH
export MAINTAINER_REPO="$REPO_PATH" MAINTAINER_SLUG="$REPO_SLUG" MAINTAINER_STATE="$STATE_DIR"

case " $TASKS " in *" $task "*) ;; *) echo "run.sh: unknown task '$task'" >&2; exit 64 ;; esac
model_var="MODEL_$task"; model="${!model_var:?no model configured for $task}"

logs="$STATE_DIR/logs"; mkdir -p "$logs"
stamp="$(date +%Y-%m-%dT%H-%M)"
log="$logs/$stamp-$task.log"
export PATH="$HOME/.local/bin:$PATH"

alert() {
    printf '%s\n' "$1" | tee -a "$log" >&2
    DISPLAY="${DISPLAY:-:1}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
        notify-send -u critical "maintainer: $profile/$task failed" "$1" 2>/dev/null || true
}

# shellcheck disable=SC1090
. "$BACKEND_DIR/$BACKEND.sh" || { alert "no backend '$BACKEND'"; exit 64; }

{
    echo "=== run.sh $profile/$task $(date -Is) ==="
    echo "backend=$(backend_name) model=$model log=$log"
} >>"$log"

if ! msg="$(backend_check)"; then
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

# Every task shares one working tree and `maintainer start` checks out main.
# Two at once would fight over HEAD and over target/, and the loser would review
# a tree it did not create. Wait rather than fail: a skipped run is a silent gap
# in the audit trail.
exec 9>"$STATE_DIR/run.lock"
if ! flock -w "$LOCK_WAIT" 9; then
    alert "another run held the lock for over ${LOCK_WAIT}s"
    exit 1
fi

# 0. Pin the GitHub identity and refuse to run without it.
#
# `gh`'s active account has been observed flipping back to a different account
# on its own, rewriting the `user:` key in ~/.config/gh/hosts.yml. Unattended
# that is worse than a 403: a merge would fail loudly, but reviews and issue
# comments would post successfully under the wrong identity.
gh auth switch --hostname github.com --user "$GH_ACCOUNT" >>"$log" 2>&1 || true
gh_login="$(gh api user --jq .login 2>>"$log" || true)"
if [ "$gh_login" != "$GH_ACCOUNT" ]; then
    alert "gh is authenticated as '${gh_login:-unknown}', not $GH_ACCOUNT; refusing to run. See $log"
    exit 1
fi
printf 'gh identity: %s\n' "$gh_login" >>"$log"

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

# 2. preamble + task prompt + freshly computed context, in that order. Written
#    to a file rather than piped from a variable so the backend can choose
#    stdin or an argument without the caller caring.
prompt_file="$(mktemp)"
trap 'rm -f "$prompt_file"' RETURN
{
    cat "$PROFILE_DIR/prompts/common-preamble.md"
    printf '\n\n'
    # Opt-out, not opt-in: anything other than an explicit "raw" gets the
    # prose discipline. A missing or misspelled value must still write well.
    if [ "${PROSE_STYLE:-stop-slop}" != "raw" ]; then
        cat "$local_root/lib/prose-style.md" 2>/dev/null || cat "$local_root/prose-style.md"
        printf '\n\n'
    fi
    cat "$PROFILE_DIR/prompts/$task.md"
    printf '\n\n## Context for this run, computed just now\n\n```\n%s\n```\n' "$context"
} > "$prompt_file"

# 3. Hand it to the backend. Wall-clock is bounded by systemd, not here.
cd "$REPO_PATH" || { alert "cannot cd to $REPO_PATH"; exit 1; }
if ! backend_run "$prompt_file" "$model" "$log" "$STATE_DIR"; then
    alert "$BACKEND exited non-zero for $run_id. See $log"
    # Fall through: a partial report is better than none.
fi

# 4. Close the run. `finish` refuses an empty report, which is the point.
if ! "$HELPER" finish "$run_id" >>"$log" 2>&1; then
    alert "$run_id produced no report; the run is not auditable. See $log"
    exit 1
fi

echo "=== done $(date -Is) ===" >>"$log"

}

main "$@"
