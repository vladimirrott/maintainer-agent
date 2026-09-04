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

# Deduplicated: both globs match `sysknife-maint`, so the first version wrote
# every alert to the same file twice and an operator counting alerts would have
# counted double.
while read -r d; do
    [ -d "$d" ] || continue
    mkdir -p "$d/logs"
    printf '%s  ALERT %s: %s\n' "$(date -Is)" "$instance" "$msg" >> "$d/logs/alerts.log"
done < <(printf '%s\n' "$HOME"/.local/state/*-maint "$HOME"/.local/state/*maint* | sort -u)

DISPLAY="${DISPLAY:-:1}" \
DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}" \
notify-send -u critical -a maintainer "maintainer · ${instance} · FAILED" \
    "$msg
fix    maintainer-doctor
then   journalctl --user -u maintainer@${instance}.service -n 40" 2>/dev/null || true
