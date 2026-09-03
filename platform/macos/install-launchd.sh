#!/usr/bin/env bash
# Register a profile's tasks with launchd.
#
#   install-launchd.sh [profile]     default: sysknife (or $MAINTAINER_PROFILE)
#   install-launchd.sh --remove [profile]
#
# launchd differs from systemd in one way that matters: there is no
# Persistent=true. A StartCalendarInterval job missed while the machine was
# asleep does NOT catch up; it fires at the next matching time. `RunAtLoad` is
# deliberately false, because a catch-up run at login lands a job on top of
# whatever the user is doing.
#
# Every job therefore fires DAILY, and the real cadence is MIN_HOURS_<task> in
# profile.env, which run.sh enforces. An earlier version of this file claimed
# the since-last-run state already did that. Nothing did: `audit`, nominally a
# five-day task, would have run every day.
set -euo pipefail
share="$HOME/.local/share/maintainer"
agents="$HOME/Library/LaunchAgents"

remove=0; [ "${1:-}" = "--remove" ] && { remove=1; shift; }
profile="${1:-${MAINTAINER_PROFILE:-sysknife}}"
label_prefix="dev.maintainer.$profile"
env_file="$share/profiles/$profile/profile.env"
[ -f "$env_file" ] || { echo "install-launchd: no deployed profile '$profile'; run ./install.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$env_file"
mkdir -p "$agents" "$STATE_DIR/logs"

if [ "$remove" = 1 ]; then
    for f in "$agents/$label_prefix".*.plist; do
        [ -e "$f" ] || continue
        launchctl unload "$f" 2>/dev/null || true
        rm -f "$f"
        printf '  removed %s\n' "$(basename "$f")"
    done
    exit 0
fi

hour=9
for task in $TASKS; do
    label="$label_prefix.$task"
    f="$agents/$label.plist"
    cat > "$f" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$share/run.sh</string>
    <string>$profile</string>
    <string>$task</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_PATH</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>17</integer></dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$STATE_DIR/logs/launchd-$task.out</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/logs/launchd-$task.err</string>
</dict>
</plist>
PLIST
    launchctl unload "$f" >/dev/null 2>&1 || true
    launchctl load "$f"
    min_var="MIN_HOURS_$task"
    printf '  loaded %s (fires daily at %02d:17; runs when %sh have passed)\n' \
        "$label" "$hour" "${!min_var:-0}"
    hour=$((hour + 1))
done
printf '  done. list with: launchctl list | grep %s\n' "$label_prefix"
