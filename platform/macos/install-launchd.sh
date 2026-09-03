#!/usr/bin/env bash
# Register the maintainer tasks with launchd.
#
# launchd differs from systemd in one way that matters here: there is no
# Persistent=true. A StartCalendarInterval job missed while the machine was
# asleep does NOT catch up by default; it fires at the next matching time.
# `RunAtLoad` is deliberately false, because a catch-up run at login lands a job
# on top of whatever the user is doing.
set -euo pipefail
share="$HOME/.local/share/maintainer"
agents="$HOME/Library/LaunchAgents"
label_prefix="dev.maintainer"
mkdir -p "$agents"

plist() {  # $1 task, $2 hour, $3 minute, $4 interval-days (0 = daily)
    local task="$1" hour="$2" min="$3" days="$4"
    local label="$label_prefix.sysknife-$task"
    local f="$agents/$label.plist"
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
    <string>sysknife</string>
    <string>$task</string>
  </array>
  <key>WorkingDirectory</key><string>$HOME/Desktop/lacs</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>$min</integer></dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$HOME/.local/state/sysknife-maint/logs/launchd-$task.out</string>
  <key>StandardErrorPath</key><string>$HOME/.local/state/sysknife-maint/logs/launchd-$task.err</string>
</dict>
</plist>
PLIST
    # Every-N-days is not expressible in StartCalendarInterval. The job runs
    # daily and run.sh's own since-last-run state decides whether there is
    # anything to do, which is the honest way to say "every N days" here.
    [ "$days" != "0" ] && printf '  note: %s runs daily; cadence is enforced by the since-last-run state\n' "$task"
    launchctl unload "$f" >/dev/null 2>&1 || true
    launchctl load "$f"
    printf '  loaded %s\n' "$label"
}

mkdir -p "$HOME/.local/state/sysknife-maint/logs"
plist review 9  13 0
plist issues 10 41 2
plist ci     11 27 3
plist audit  12 19 5
printf '  done. list with: launchctl list | grep %s\n' "$label_prefix"
