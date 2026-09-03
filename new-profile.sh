#!/usr/bin/env bash
# Scaffold a profile for another repository.
#
#   ./new-profile.sh <profile> <owner/repo> <path-to-checkout> <gh-account> "<your name>"
#
# Writes profiles/<profile>/ and the systemd units for it, then tells you the
# three things to do before the first run. Nothing is enabled and nothing posts:
# a new profile starts at POST=off, so the first week produces reports and
# drafts and reaches nobody.
#
# CONTRIBUTING.md claims a second repository needs a profile and no code change.
# This script is what makes that true; before it existed, adding one meant
# editing a hardcoded skill map, hand-writing four unit files, and copying a
# 72-line deny wall by hand.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,9p' "$0" >&2; exit 64; }
[ $# -ge 4 ] || usage
profile="$1"; slug="$2"; path="$3"; account="$4"; name="${5:-$account}"

case "$profile" in
    _*|*/*|"") echo "new-profile: '$profile' is not a usable profile name" >&2; exit 64 ;;
esac
case "$slug" in */*) ;; *) echo "new-profile: '$slug' is not owner/repo" >&2; exit 64 ;; esac
[ -d "$root/profiles/$profile" ] && { echo "new-profile: profiles/$profile already exists" >&2; exit 1; }
[ -d "$path/.git" ] || echo "  warning: $path is not a git checkout yet"

# Substituting into a path with a & or | in it would corrupt the sed script, and
# a corrupted profile.env is a run that reads the wrong repository.
for v in "$profile" "$slug" "$path" "$account" "$name"; do
    case "$v" in *[\|\&]*) echo "new-profile: '|' and '&' are not allowed in an argument" >&2; exit 64 ;; esac
done

cp -r "$root/profiles/_template" "$root/profiles/$profile"
while IFS= read -r f; do
    sed -i \
        -e "s|__PROFILE__|$profile|g" \
        -e "s|__SLUG__|$slug|g" \
        -e "s|__REPO_PATH__|$path|g" \
        -e "s|__GH_ACCOUNT__|$account|g" \
        -e "s|__MAINTAINER_NAME__|$name|g" "$f"
done < <(find "$root/profiles/$profile" -type f)

if grep -rq '__[A-Z_]*__' "$root/profiles/$profile"; then
    echo "new-profile: a placeholder survived substitution:" >&2
    grep -rn '__[A-Z_]*__' "$root/profiles/$profile" >&2
    exit 1
fi

# One scheduling shape: fire daily, and let MIN_HOURS_<task> in profile.env
# decide whether there is anything to do. launchd cannot express "every N days"
# at all and cron's day-of-month stepping fires on the 31st and again on the
# 1st, so putting the cadence in one place that every platform reads is the only
# way it means the same thing everywhere.
tasks="$(sed -n 's/^TASKS="\(.*\)"/\1/p' "$root/profiles/$profile/profile.env")"
hour=9
for task in $tasks; do
    unit="$root/platform/linux/maintainer@$profile-$task.timer"
    cat > "$unit" <<UNIT
[Unit]
Description=maintainer: $profile $task (timer)

[Timer]
# Fires daily. The real cadence is MIN_HOURS_$task in profiles/$profile/profile.env,
# which run.sh enforces on every platform.
OnCalendar=*-*-* $(printf '%02d' "$hour"):17:00
Persistent=true
RandomizedDelaySec=300
Unit=maintainer@$profile-$task.service

[Install]
WantedBy=timers.target
UNIT
    echo "  wrote $(basename "$unit")"
    hour=$((hour + 1))
done

cat <<NEXT

  profiles/$profile/ is ready. Three things before the first run:

  1. Read profiles/$profile/profile.env end to end. It decides what an
     unattended agent does in your name.
  2. Rewrite profiles/$profile/prompts/*.md for this repository. The generic
     ones are a starting point, not a description of your project. Read
     profiles/sysknife/prompts/ for a worked set.
  3. Install and look at the assembled prompt before anything runs:

       ./install.sh
       MAINTAINER_PROFILE=$profile maintainer-doctor
       ./lib/run.sh --show-prompt $profile review | less

  Then one rehearsal run by hand. POST=off, so it posts nothing:

       ~/.local/share/maintainer/run.sh $profile review
       maintainer log 1

  Turn posting on in profile.env only after you have read a week of reports.
NEXT
