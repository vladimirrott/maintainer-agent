#!/usr/bin/env bash
# Install the maintainer agent for the current user.
#
#   ./install.sh              deploy files, do not touch timers
#   ./install.sh --timers     deploy and enable the timers
#   ./install.sh --dry-run    print what would change
#   ./install.sh --uninstall  remove everything except the audit trail
#
# Idempotent. Deploys into ~/.local so nothing needs root.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
share="$HOME/.local/share/maintainer"
bin="$HOME/.local/bin"
units="$HOME/.config/systemd/user"
dry=0; timers=0; uninstall=0
for a in "$@"; do
    case "$a" in
        --dry-run)   dry=1 ;;
        --timers)    timers=1 ;;
        --uninstall) uninstall=1 ;;
        *) echo "install.sh: unknown flag $a" >&2; exit 64 ;;
    esac
done

say() { printf '  %s\n' "$*"; }
run() { if [ "$dry" = 1 ]; then say "would: $*"; else "$@"; fi; }

# --- uninstall -------------------------------------------------------------
# People try what they can remove. The audit trail is deliberately NOT deleted:
# it is the record of what the agent published in someone's name, and a tool
# that erases that on its way out is a tool nobody should have trusted.
if [ "$uninstall" = 1 ]; then
    # A live deployment is not removed without being asked twice.
    #
    # On 2026-09-04 an unattended run of the `magent` profile, reviewing this
    # repository at POST=off, ran `./install.sh --uninstall` against the real
    # HOME while root-causing a failing uninstall test. It disabled all six
    # timers -- including the four that maintain a DIFFERENT project -- and then
    # died before removing anything. Nothing ran unattended for three and a half
    # hours and nothing said so. The rehearsal wall stopped it reaching GitHub
    # and had nothing to say about the scheduler that runs it.
    #
    # docs/plan.md put it abstractly: an agent that reviews its own repository
    # can change the rules it is reviewed under. This is the concrete form.
    if [ "$dry" = 0 ] && [ "${MAINTAINER_UNINSTALL_YES:-}" != 1 ]; then
        _live=0
        if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
            _live="$(systemctl --user list-timers 'maintainer@*' --no-pager 2>/dev/null \
                     | grep -c 'maintainer@' || true)"
        fi
        if [ "${_live:-0}" -gt 0 ]; then
            echo "install.sh: $_live maintainer timer(s) are enabled on this machine." >&2
            echo "            Removing them stops every profile, including any that" >&2
            echo "            maintains a repository other than this one." >&2
            echo "" >&2
            echo "            Re-run with MAINTAINER_UNINSTALL_YES=1 to go ahead, or" >&2
            echo "            --dry-run to see what would be removed." >&2
            exit 3
        fi
    fi
    say "removing the maintainer agent"
    # Nothing below may abort the rest. Every step records its own failure and
    # the script reports them at the end, because the previous version put the
    # cron removal at the end of an `&&` list, so a `crontab` that exists but
    # cannot write killed the script under `set -e` AFTER the timers were off
    # and BEFORE a single file was removed. Half-uninstalled and silent is worse
    # than either finished state.
    _failed=""
    step() { if "$@"; then :; else _failed="$_failed
  $*"; fi; }
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        for t in "$units"/maintainer@*.timer; do
            [ -e "$t" ] || continue
            step run systemctl --user disable --now "$(basename "$t")"
        done
        for u in "$units"/maintainer*.service "$units"/maintainer@*.timer "$units"/podman-userns-warmup.service; do
            [ -e "$u" ] || continue
            run rm -f "$u"
        done
        run systemctl --user daemon-reload
    fi
    if [ "$(uname -s)" = Darwin ]; then
        for pl in "$HOME"/Library/LaunchAgents/dev.maintainer.*.plist; do
            [ -e "$pl" ] || continue
            run launchctl unload "$pl"
            run rm -f "$pl"
        done
    fi
    if command -v crontab >/dev/null 2>&1 && [ -x "$root/platform/posix/install-cron.sh" ]; then
        step run "$root/platform/posix/install-cron.sh" --remove
    fi
    for f in maintainer maintainer-merge maintainer-doctor maintainer-repo; do
        [ -e "$bin/$f" ] && run rm -f "$bin/$f"
    done
    step run rm -rf "$share"
    say ""
    if [ -n "$_failed" ]; then
        say "SOME STEPS FAILED. This deployment is part-removed, and that is the"
        say "state to fix rather than to leave:"
        printf '%s\n' "$_failed" >&2
        say ""
    fi
    say "removed: $share, the four commands in $bin, and every scheduler entry."
    say "kept:    the audit trail. Delete it yourself if you want it gone:"
    for pe in "$root"/profiles/*/profile.env; do
        [ -e "$pe" ] || continue
        say "         $(grep -m1 '^STATE_DIR=' "$pe" | sed 's/.*="//; s/"$//; s|\$HOME|'"$HOME"'|')"
    done
    exit 0
fi

# Stamp the deployed tree with what it came from. Three versions are in play and
# they disagree in normal use: the checkout, the deployed tree, and the profile.
# The deployed tree is the one that actually runs, so it carries the stamp, and
# everything reads this file rather than asking git. Printing the checkout's
# version would be the wrong one and the most flattering.
stamp_version() {
    printf 'version=%s\ncommit=%s\ninstalled_at=%s\ninstalled_from=%s\n' \
        "$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo unknown)" \
        "$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
        "$(date -Is)" "$root"
}

say "deploying from $root"
run mkdir -p "$share" "$bin" "$units"
run cp "$root/lib/run.sh" "$share/run.sh"
run cp "$root/lib/prose-style.md" "$share/prose-style.md"
run cp "$root/lib/preamble-core.md" "$share/preamble-core.md"
run cp "$root/lib/profile.sh" "$share/profile.sh"
if [ "$dry" = 1 ]; then say "would stamp $share/VERSION"; else stamp_version > "$share/VERSION"; fi
# The key that makes a verification receipt unforgeable. Before this, a receipt
# was a JSON file in the state directory and the only thing protecting it was a
# deny rule on `maintainer-merge receipt`: the deny wall emits Bash() and Read()
# rules and nothing else, so an agent with an ordinary file-write tool could
# write the receipt directly and skip verification entirely. Minted once, never
# rotated automatically, and never printed.
if [ "$dry" = 1 ]; then
    say "would mint $share/receipt.key if absent"
elif [ ! -f "$share/receipt.key" ]; then
    ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n" > "$share/receipt.key" )
    chmod 600 "$share/receipt.key"
    say "minted a receipt-signing key"
fi
run mkdir -p "$share/scripts"
# Every script, not a list. render-settings.py was deployed and transcript.py
# was not, and the backend's fallback made the missing one invisible: runs kept
# working and silently stopped recording what the agent executed.
for f in "$root"/scripts/*.py; do
    run cp "$f" "$share/scripts/$(basename "$f")"
done
# `cp -r src dst` copies src INTO dst when dst already exists, so a second
# install nests profiles/profiles and backends/backends. That happened, and the
# render step below then wrote into the nested copy while the live deny wall
# stayed stale at its previous size. Remove the destination first so a re-install
# is a replacement rather than an accumulation.
run rm -rf "$share/backends" "$share/profiles"
run cp -r "$root/lib/backends" "$share/backends"
run cp -r "$root/profiles" "$share/profiles"
# Generate the deny walls from each profile's deny.json. Two walls come out of
# one input: the live one, and the rehearsal one that also blocks every GitHub
# write verb. A hand-kept second copy would drift, and a drifted rehearsal wall
# is a promise it cannot keep.
#
# _template is scaffolding for `./new-profile.sh`, not a runnable profile, so it
# is not deployed.
run rm -rf "$share/profiles/_template"
for spec in "$share"/profiles/*/deny.json; do
    [ -e "$spec" ] || continue
    pd="$(dirname "$spec")"
    if [ "$dry" = 1 ]; then
        say "would generate $(basename "$pd")/settings.json and settings-rehearsal.json"
    else
        python3 "$root/scripts/render-settings.py" "$pd" "$HOME" \
            || { echo "install.sh: generating the deny wall failed" >&2; exit 1; }
    fi
done
run cp "$root/bin/maintainer" "$bin/maintainer"
run cp "$root/bin/maintainer-merge" "$bin/maintainer-merge"
run cp "$root/bin/maintainer-doctor" "$bin/maintainer-doctor"
run cp "$root/bin/maintainer-repo" "$bin/maintainer-repo"
run cp "$root/bin/maintainer-mcp" "$bin/maintainer-mcp"
run chmod +x "$share/run.sh" "$bin/maintainer" "$bin/maintainer-merge" "$bin/maintainer-doctor" "$bin/maintainer-repo" "$bin/maintainer-mcp"

# run.sh resolves the profile relative to its own parent, so the deployed tree
# must mirror the repository layout: $share/{run.sh,profiles,backends}.
if [ "$dry" = 0 ] && [ ! -d "$share/profiles/sysknife" ]; then
    echo "install.sh: profiles did not land where run.sh expects" >&2
    exit 1
fi

# --- platform dispatch -----------------------------------------------------
# The core is bash everywhere. Only scheduling is per-platform, so only that is
# forked. Two implementations of the gate would drift, and the gate is the
# product.
case "$(uname -s)" in
  Linux)
    for u in "$root"/platform/linux/*.service "$root"/platform/linux/*.timer; do
        [ -e "$u" ] || continue
        run cp "$u" "$units/$(basename "$u")"
    done
    run cp "$root/platform/linux/run-instance.sh" "$share/run-instance.sh"
    run chmod +x "$share/run-instance.sh"
    # The OnFailure alert. Deployed beside run-instance.sh for the same reason:
    # the unit file calls a script so it needs no shell quoting of its own.
    run cp "$root/platform/linux/alert.sh" "$share/alert.sh"
    run chmod +x "$share/alert.sh"
    say "platform: Linux (systemd user units)"
    ;;
  Darwin)
    say "platform: macOS (launchd)"
    say "run platform/macos/install-launchd.sh to register the agents"
    say "note: launchd has no Persistent=true; a missed run does not catch up"
    timers=0
    ;;
  MINGW*|MSYS*|CYGWIN*)
    say "platform: Windows"
    say "files deployed; register the tasks from PowerShell:"
    say "  platform\\windows\\Install-Maintainer.ps1"
    timers=0
    ;;
  *)
    say "platform: $(uname -s) is unrecognised; files deployed, scheduling is yours to wire"
    timers=0
    ;;
esac

if [ "$timers" = 1 ]; then
    run systemctl --user daemon-reload
    # The units live under platform/linux. An earlier version globbed
    # $root/systemd, which does not exist: with nullglob off the loop ran once
    # on the literal pattern and `systemctl enable '*.timer'` aborted the
    # install having enabled nothing. Count what the glob matched and refuse to
    # report success over an empty set.
    enabled=0
    for t in "$root"/platform/linux/*.timer; do
        [ -e "$t" ] || continue
        name="$(basename "$t")"
        # Write a stamp first. A fresh Persistent=true timer treats "never run"
        # as a missed slot and fires a catch-up run the instant it is enabled,
        # which lands a job on top of whatever a human is doing right now.
        run mkdir -p "$HOME/.local/share/systemd/timers"
        run touch "$HOME/.local/share/systemd/timers/stamp-$name"
        run systemctl --user enable --now "$name"
        say "enabled $name"
        enabled=$((enabled+1))
    done
    if [ "$enabled" = 0 ]; then
        echo "install.sh: --timers matched no unit files under $root/platform/linux" >&2
        exit 1
    fi
else
    say "timers not touched (pass --timers to enable them)"
fi
say "done"
say ""
say "next: maintainer-doctor        # checks the install by running it, not by listing files"
if [ "$timers" = 0 ]; then
    case "$(uname -s)" in
      Linux)  say "      ./install.sh --timers     # enable the systemd timers" ;;
      Darwin) say "      platform/macos/install-launchd.sh" ;;
      *)      say "      platform/posix/install-cron.sh   # works anywhere with crontab" ;;
    esac
fi
