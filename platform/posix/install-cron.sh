#!/usr/bin/env bash
# Universal scheduler fallback: anything with crontab.
#
# This is what multiplies OS coverage. systemd covers most Linux, launchd covers
# macOS, Task Scheduler covers Windows; cron covers FreeBSD, OpenBSD, NetBSD,
# Alpine and other musl or systemd-less Linux, Termux on Android, and any
# container or VM where a user session manager is absent.
#
#   install-cron.sh            install the entries
#   install-cron.sh --dry-run  print the crontab that would be written
#   install-cron.sh --remove   take them out again
#
# Two honest differences from systemd, both of which change behaviour:
#
#   1. There is no Persistent=true. A run missed while the machine was off does
#      NOT catch up. `maintainer start` computes what changed since the last run
#      of that task, so the work is not lost, only delayed.
#   2. cron has no equivalent of a per-unit lock. run.sh takes its own flock, so
#      overlapping entries serialise rather than race.
set -eu

share="$HOME/.local/share/maintainer"
profile="${MAINTAINER_PROFILE:-sysknife}"
marker="# maintainer-agent ($profile)"
mode="${1:-install}"

[ -x "$share/run.sh" ] || { echo "install-cron: $share/run.sh not found; run ./install.sh first" >&2; exit 1; }
command -v crontab >/dev/null || { echo "install-cron: no crontab on this system" >&2; exit 1; }

# cron gives a job almost no environment. PATH in particular is usually just
# /usr/bin:/bin, which is how a scheduled agent ends up reporting that `cargo`
# does not exist. Pin it here rather than discovering it in a run report.
cron_path="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

# cron cannot express "every N days" directly. Day-of-month stepping is the
# closest equivalent and is what the systemd units use, so the cadences match.
gen() {
    printf '%s\n' "$marker"
    printf 'PATH=%s\n' "$cron_path"
    printf '13 9 * * *   %s %s review  >/dev/null 2>&1\n'      "$share/run.sh" "$profile"
    printf '13 21 * * *  %s %s review  >/dev/null 2>&1\n'      "$share/run.sh" "$profile"
    printf '41 10 1-31/2 * * %s %s issues >/dev/null 2>&1\n'   "$share/run.sh" "$profile"
    printf '27 11 1-31/3 * * %s %s ci     >/dev/null 2>&1\n'   "$share/run.sh" "$profile"
    printf '19 12 1-31/5 * * %s %s audit  >/dev/null 2>&1\n'   "$share/run.sh" "$profile"
    printf '%s end\n' "$marker"
}

current="$(crontab -l 2>/dev/null || true)"
# Strip any previous block so this is idempotent. Reinstalling must replace, not
# accumulate; the same mistake cost a stale deny wall on the file-copy path.
stripped="$(printf '%s\n' "$current" | awk -v m="$marker" '
    $0 == m {skip=1} 
    skip != 1 {print}
    $0 == m " end" {skip=0}' )"

case "$mode" in
  --dry-run)
    echo "--- crontab that would be installed ---"; gen ;;
  --remove)
    printf '%s\n' "$stripped" | crontab -
    echo "  maintainer entries removed" ;;
  install)
    { printf '%s\n' "$stripped"; gen; } | crontab -
    echo "  installed $(gen | grep -c run.sh) cron entries for profile '$profile'"
    echo "  inspect with: crontab -l"
    echo "  note: cron does not catch up a missed run; see the header of this script" ;;
  *) echo "usage: install-cron.sh [--dry-run|--remove]" >&2; exit 64 ;;
esac
