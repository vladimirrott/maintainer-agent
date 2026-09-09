#!/usr/bin/env bash
# Resolve which repository and account a tool is acting on. Sourced, never run.
#
# Every tool here used to carry personal defaults: REPO_SLUG fell back to one
# person's repository, ACCOUNT to their GitHub login, REPO_PATH to a directory
# on their laptop. Harmless while this had one user, wrong the moment it has
# two: a stranger running `maintainer-repo prune` with no profile in the
# environment would have queried somebody else's repository.
#
# Order: what run.sh exported, then the deployed profile, then refuse. There is
# no fallback that names a person.
maintainer_load_profile() {
    # run.sh exports these, and they win: a tool called from inside a run acts
    # on that run's repository and nothing else.
    #
    # Every variable a tool reads has to be here, not just the two that name the
    # repository. This returned early on SLUG and REPO alone while
    # maintainer-merge reads MAINTAINER_ACCOUNT under `set -u`, so the merge
    # gate died with "MAINTAINER_ACCOUNT: unbound variable" on every call from
    # inside a run, which is the only way an agent ever calls it. The audited
    # merge path did not work when exercised. The tests missed it because they
    # set up a MORE complete environment than production provides.
    if [ -n "${MAINTAINER_SLUG:-}" ] && [ -n "${MAINTAINER_REPO:-}" ] \
       && [ -n "${MAINTAINER_ACCOUNT:-}" ] && [ -n "${MAINTAINER_STATE:-}" ]; then
        return 0
    fi

    local share="$HOME/.local/share/maintainer/profiles"
    local name="${MAINTAINER_PROFILE:-}"
    if [ -z "$name" ]; then
        # One deployed profile needs no naming. Several do, because guessing
        # which repository to act on is exactly the mistake this replaces.
        local found=() d
        for d in "$share"/*/profile.env; do
            [ -e "$d" ] || continue
            found+=("$(basename "$(dirname "$d")")")
        done
        case "${#found[@]}" in
            0) printf 'maintainer: no profile is deployed. Run ./install.sh, or set\n' >&2
               printf '            MAINTAINER_PROFILE, MAINTAINER_SLUG and MAINTAINER_REPO.\n' >&2
               return 1 ;;
            1) name="${found[0]}" ;;
            *) printf 'maintainer: %d profiles are deployed (%s).\n' "${#found[@]}" "${found[*]}" >&2
               printf '            Set MAINTAINER_PROFILE to say which one you mean.\n' >&2
               return 1 ;;
        esac
    fi

    local env_file="$share/$name/profile.env"
    if [ ! -f "$env_file" ]; then
        printf 'maintainer: no deployed profile named %s (looked in %s)\n' "$name" "$share" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    . "$env_file"
    MAINTAINER_SLUG="${MAINTAINER_SLUG:-$REPO_SLUG}"
    MAINTAINER_REPO="${MAINTAINER_REPO:-$REPO_PATH}"
    MAINTAINER_STATE="${MAINTAINER_STATE:-$STATE_DIR}"
    MAINTAINER_ACCOUNT="${MAINTAINER_ACCOUNT:-$GH_ACCOUNT}"
    MAINTAINER_POST="${MAINTAINER_POST:-$POST}"
    export MAINTAINER_SLUG MAINTAINER_REPO MAINTAINER_STATE MAINTAINER_ACCOUNT MAINTAINER_POST
}

# Find lib/profile.sh from a tool in bin/, whether running from a checkout or
# from the deployed tree.
# Remove a literal secret from every text file under the given paths.
#
# run.sh exports the pinned token for the whole run on purpose: it is what makes
# every gh call in the run, the agent's included, act as one account. The token
# being REACHABLE is the design. The token OUTLIVING the run is the defect, and
# on 2026-09-09 it did, twice. The magent issues run wrote
#
#     echo "GH_TOKEN set? ${GH_TOKEN:+yes}${GH_TOKEN:-no}"
#
# and the `:-` arm expands to the value when the variable is set, so the live
# PAT printed into the session transcript and stayed on disk. Its own report
# caught it. No deny rule can enumerate the commands that print an environment
# variable, so the guard is on the way out rather than on the way in.
#
# The secret travels in the environment, never in argv, because argv is readable
# from /proc by anything running as this user.
maintainer_scrub_secret() {
    local secret="${1:-}"
    shift 2>/dev/null || true
    # A short or empty needle matches nearly everywhere, and a scrubber that
    # accepts one rewrites every file it walks. That is a worse day than the
    # leak it was meant to clean up, so refuse rather than guess.
    [ "${#secret}" -ge 16 ] || return 1
    [ "$#" -gt 0 ] || return 1
    MAINTAINER_SCRUB_NEEDLE="$secret" python3 - "$@" <<'SCRUBPY'
import os, sys
needle = os.environ.get("MAINTAINER_SCRUB_NEEDLE", "")
if len(needle) < 16:
    sys.exit(1)
raw = needle.encode()
mask = b"REDACTED_BY_MAINTAINER_ROTATE_THIS_SECRET"
changed = []
def scrub(path):
    try:
        data = open(path, "rb").read()
    except OSError:
        return
    if raw not in data:
        return
    # A NUL byte means a disk image or an object file, and a byte-length change
    # there corrupts the container. Report it and leave it alone: the fix for
    # those is rotating the secret, not editing the file.
    if b"\x00" in data:
        changed.append(f"{path}  BINARY, not modified: rotate the secret")
        return
    try:
        open(path, "wb").write(data.replace(raw, mask))
    except OSError:
        return
    changed.append(path)
for target in sys.argv[1:]:
    if os.path.isfile(target):
        scrub(target)
        continue
    for root, dirs, files in os.walk(target):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "target", "ctargets")]
        for name in files:
            scrub(os.path.join(root, name))
for c in changed:
    print(f"scrubbed the pinned token from {c}")
sys.exit(0 if changed else 0)
SCRUBPY
}

# Which backend failures fix themselves, and which do not.
#
# 2026-09-07T20-34-issues stopped on "You've hit your session limit, resets
# 10:10pm". run.sh alerted at critical for the backend exit, alerted again
# because the run wrote no report, and exited 1 so systemd's OnFailure alerted a
# third time. Three popups and a red in maintainer-doctor for 39 hours, for a
# window that reopened by itself ninety minutes later.
#
# Prints the line it matched and returns 0 when waiting is the whole fix.
#
# The list stays short on purpose. An empty credit balance is deliberately NOT
# in it: no retry pays an invoice, and a classifier that calls everything
# transient silences the alerts it exists to raise. An unreadable log is not
# transient either, for the same reason a guard that cannot ask must not answer.
backend_transient_reason() {
    local log="${1:-}" hit=""
    [ -n "$log" ] && [ -r "$log" ] || return 1
    hit="$(grep -aoiE "you'?ve hit your (session|usage) limit.{0,60}|usage limit reached.{0,60}|overloaded_error|rate_limit_error|api error: (429|5[0-9][0-9])|connection error|fetch failed" "$log" 2>/dev/null | tail -1)"
    [ -n "$hit" ] || return 1
    printf '%s' "$hit"
}

maintainer_lib() {
    local here; here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    for c in "$here/../lib/profile.sh" "$HOME/.local/share/maintainer/profile.sh"; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
