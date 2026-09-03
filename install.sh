#!/usr/bin/env bash
# Install the maintainer agent for the current user.
#
#   ./install.sh              deploy files, do not touch timers
#   ./install.sh --timers     deploy and enable the timers
#   ./install.sh --dry-run    print what would change
#
# Idempotent. Deploys into ~/.local so nothing needs root.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
share="$HOME/.local/share/maintainer"
bin="$HOME/.local/bin"
units="$HOME/.config/systemd/user"
dry=0; timers=0
for a in "$@"; do
    case "$a" in
        --dry-run) dry=1 ;;
        --timers)  timers=1 ;;
        *) echo "install.sh: unknown flag $a" >&2; exit 64 ;;
    esac
done

say() { printf '  %s\n' "$*"; }
run() { if [ "$dry" = 1 ]; then say "would: $*"; else "$@"; fi; }

say "deploying from $root"
run mkdir -p "$share" "$bin" "$units"
run cp "$root/lib/run.sh" "$share/run.sh"
run cp "$root/systemd/run-instance.sh" "$share/run-instance.sh"
run cp -r "$root/lib/backends" "$share/backends"
run cp -r "$root/profiles" "$share/profiles"
# Render the deny wall. Its paths must be absolute at runtime, but the repo
# holds a template so no home path is committed. Substitution happens here.
for tpl in "$share"/profiles/*/settings.json.template; do
    [ -e "$tpl" ] || continue
    out="${tpl%.template}"
    if [ "$dry" = 1 ]; then
        say "would render $(basename "$(dirname "$tpl")")/settings.json"
    else
        sed "s|__HOME__|$HOME|g" "$tpl" > "$out"
        rm -f "$tpl"
        grep -q '__HOME__' "$out" && { echo "install.sh: settings template did not fully render" >&2; exit 1; }
        python3 -c "import json,sys; json.load(open('$out'))" \
            || { echo "install.sh: rendered settings.json is not valid JSON" >&2; exit 1; }
    fi
done
run cp "$root/bin/maintainer" "$bin/maintainer"
run cp "$root/bin/maintainer-merge" "$bin/maintainer-merge"
run chmod +x "$share/run.sh" "$share/run-instance.sh" "$bin/maintainer" "$bin/maintainer-merge"

# run.sh resolves the profile relative to its own parent, so the deployed tree
# must mirror the repository layout: $share/{run.sh,profiles,backends}.
if [ "$dry" = 0 ] && [ ! -d "$share/profiles/sysknife" ]; then
    echo "install.sh: profiles did not land where run.sh expects" >&2
    exit 1
fi

for u in "$root"/systemd/podman-userns-warmup.service "$root"/systemd/maintainer@.service "$root"/systemd/maintainer-alert@.service "$root"/systemd/*.timer; do
    run cp "$u" "$units/$(basename "$u")"
done

if [ "$timers" = 1 ]; then
    run systemctl --user daemon-reload
    for t in "$root"/systemd/*.timer; do
        name="$(basename "$t")"
        # Write a stamp first. A fresh Persistent=true timer treats "never run"
        # as a missed slot and fires a catch-up run the instant it is enabled,
        # which lands a job on top of whatever a human is doing right now.
        run mkdir -p "$HOME/.local/share/systemd/timers"
        run touch "$HOME/.local/share/systemd/timers/stamp-$name"
        run systemctl --user enable --now "$name"
        say "enabled $name"
    done
else
    say "timers not touched (pass --timers to enable them)"
fi
say "done"
