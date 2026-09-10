#!/usr/bin/env bash
# Last-resort alert, fired by systemd's OnFailure when the run unit failed
# BEFORE lib/run.sh could speak for itself: a missing binary, a WorkingDirectory
# that is gone, a TimeoutStartSec kill.
#
# A separate file for the same reason as run-instance.sh: a unit file is a bad
# place for shell quoting. The first version of this lived inline in
# ExecStart= and systemd refused it with "Unbalanced quoting, ignoring".
#
# It writes to disk as well as to the desktop. It used to only call notify-send,
# so a failure at 03:00 left a popup that was gone by morning and no other trace.
set -uo pipefail
instance="${1:-unknown}"
msg="the run unit failed before it could report; systemd killed or refused it"

# The trail of the profile that failed, and no other. The instance is
# `<profile>-<task>`, so the profile is everything before the last hyphen; the
# earlier version globbed every *-maint directory and wrote each alert into all
# of them, so magent failures appeared in sysknife's alerts.log and an operator
# reading either file was reading two projects' incidents interleaved.
#
# Falling back to the glob when the profile cannot be placed is deliberate: an
# alert that lands somewhere is worth more than one that lands nowhere.
profile="${instance%-*}"
dirs="$HOME/.local/state/${profile}-maint"
[ -d "$dirs" ] || dirs="$(printf '%s\n' "$HOME"/.local/state/*-maint | sort -u)"
# shellcheck disable=SC2086  # $dirs is newline-separated and is split on purpose
while read -r d; do
    [ -d "$d" ] || continue
    mkdir -p "$d/logs"
    printf '%s  ALERT %s: %s\n' "$(date -Is)" "$instance" "$msg" >> "$d/logs/alerts.log"
done < <(printf '%s\n' $dirs)

# The trail above is written either way; only the popup is optional. A headless
# host has nobody to show it to, and the same switch turns run.sh's notifier off,
# so one setting covers both rather than one of them surprising somebody.
if [ "${MAINTAINER_NOTIFY:-on}" = off ]; then exit 0; fi

DISPLAY="${DISPLAY:-:1}" \
DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}" \
notify-send -u critical -a maintainer "maintainer · ${instance} · FAILED" \
    "$msg
fix    maintainer-doctor
then   journalctl --user -u maintainer@${instance}.service -n 40" 2>/dev/null || true
