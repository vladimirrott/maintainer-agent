#!/usr/bin/env bash
# Run a command while holding one lock per machine, shared by every worktree.
#
# The pre-commit hook runs the whole offline suite and a shellcheck sweep that
# needs about 8 GB. Four agents committing in four worktrees ran four of them at
# once, the kernel hit a global OOM and killed the terminal. One lock turns that
# into a queue.
#
#   with-hook-lock.sh <command> [args...]
#
# MAGENT_HOOK_LOCK       lock file (default: <runtime or cache dir>/magent/hook.lock, a 0700 directory)
# MAGENT_HOOK_LOCK_WAIT  seconds to wait for it (default 1800)
# Exit 75 when the wait runs out. Any other code is the command's own.
set -uo pipefail
[ "$#" -gt 0 ] || { echo "usage: with-hook-lock.sh <command> [args...]" >&2; exit 64; }

# The command may itself call this script (the hook re-runs itself under the
# lock). The inner call already holds it and must not wait on itself.
if [ -n "${MAGENT_HOOK_LOCKED:-}" ]; then exec "$@"; fi

wait_s="${MAGENT_HOOK_LOCK_WAIT:-1800}"
# The lock lives in a directory this user owns (mode 0700), never under a fixed
# name in a shared one: another local user could plant a symlink there and have
# this script truncate whatever it points at.
if [ -n "${MAGENT_HOOK_LOCK:-}" ]; then
    lock="$MAGENT_HOOK_LOCK"
else
    dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/magent"
    mkdir -p "$dir" && chmod 700 "$dir" || { printf '[hook-lock] cannot prepare %s\n' "$dir" >&2; exit 75; }
    [ -O "$dir" ] && [ ! -L "$dir" ] || { printf '[hook-lock] %s is not a private directory of this user; refusing.\n' "$dir" >&2; exit 75; }
    lock="$dir/hook.lock"
fi
if [ -L "$lock" ] || { [ -e "$lock" ] && [ ! -O "$lock" ]; }; then
    printf '[hook-lock] %s is a symlink or belongs to another user; refusing to open it.\n' "$lock" >&2
    exit 75
fi

if ! command -v flock >/dev/null 2>&1; then
    printf '[hook-lock] flock is not installed; this run is not serialised with other worktrees.\n' >&2
    exec "$@"
fi

exec 9>>"$lock" || { printf '[hook-lock] cannot open %s\n' "$lock" >&2; exit 75; }
if ! flock -w "$wait_s" 9; then
    printf '[hook-lock] another gate run held %s for %ss; giving up. Retry when it finishes.\n' "$lock" "$wait_s" >&2
    exit 75
fi
export MAGENT_HOOK_LOCKED=1
exec "$@"
