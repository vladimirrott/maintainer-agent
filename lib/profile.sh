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
    if [ -n "${MAINTAINER_SLUG:-}" ] && [ -n "${MAINTAINER_REPO:-}" ]; then
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
maintainer_lib() {
    local here; here="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    for c in "$here/../lib/profile.sh" "$HOME/.local/share/maintainer/profile.sh"; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
