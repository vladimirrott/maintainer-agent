#!/usr/bin/env bash
# Standalone cases for the cron installer's output routing. run-tests.sh calls
# this file, and it can also run alone, which is what the regression gate does:
# the full suite takes longer than the gate's time limit on some machines.
set -uo pipefail
# shellcheck disable=SC2046  # the names are git's own fixed list, one per word
unset $(git rev-parse --local-env-vars 2>/dev/null)
# The tree under test: run-tests.sh passes MX_TREE, and a run of this file alone
# tests the checkout that holds it.
root="${MX_TREE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
unset MAINTAINER_FORCE MAINTAINER_POST MAINTAINER_PROFILE MAINTAINER_SETTINGS \
      MAINTAINER_STATE MAINTAINER_STATE_DIR MAINTAINER_SLUG MAINTAINER_REPO \
      MAINTAINER_TASKS MAINTAINER_SKILL MAINTAINER_IN_RUN MAINTAINER_SCRIPTS \
      MAINTAINER_BACKEND MAINTAINER_PROSE_STYLE MAINTAINER_ACCOUNT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
make_stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$stub_dir/$1"; chmod +x "$stub_dir/$1"; }

cr="$root/platform/posix/install-cron.sh"
# A cron entry that discards run.sh's stderr hides every refusal made before the
# run opens its log (unknown profile, missing wall, another run in progress).
cdh="$stub_dir/crondry"; rm -rf "$cdh"; mkdir -p "$cdh/.local/share/maintainer/profiles/cronp"
printf 'TASKS="review sweep"\nSTATE_DIR="%s/state"\n' "$cdh" > "$cdh/.local/share/maintainer/profiles/cronp/profile.env"
printf '#!/usr/bin/env bash\nexit 0\n' > "$cdh/.local/share/maintainer/run.sh"; chmod +x "$cdh/.local/share/maintainer/run.sh"
make_stub crontab 'case "$1" in -l) exit 0 ;; *) cat >/dev/null ;; esac'
cblock="$(PATH="$stub_dir:$PATH" HOME="$cdh" MAINTAINER_PROFILE=cronp bash "$cr" --dry-run 2>&1)"
if grep -q '/dev/null' <<<"$cblock"; then
    bad "cron entries discard run.sh output to /dev/null; early refusals leave no trace"
else
    ok "cron entries do not discard run.sh output"
fi
centries="$(grep '/run.sh cronp ' <<<"$cblock")"
[ "$(grep -c -F ">>\"$cdh/state/logs/cron.out\" 2>&1" <<<"$centries")" = 2 ] \
    && ok "each cron entry appends to a file under the profile's STATE_DIR" \
    || bad "cron entries do not append run.sh output under STATE_DIR: $(printf '%s' "$centries" | tr '\n' ' ')"
[ ! -d "$cdh/state/logs" ] && ok "--dry-run does not create the logs directory" \
    || bad "--dry-run created the logs directory"
PATH="$stub_dir:$PATH" HOME="$cdh" MAINTAINER_PROFILE=cronp bash "$cr" >/dev/null 2>&1
[ -d "$cdh/state/logs" ] && ok "cron install creates the STATE_DIR logs directory" \
    || bad "cron install did not create the logs directory its entries append to"

# A STATE_DIR that cannot hold a logs directory stops the install before crontab
# is touched. Otherwise the entries would be written and append to nowhere.
cbd="$stub_dir/cronbad"; rm -rf "$cbd"; mkdir -p "$cbd/.local/share/maintainer/profiles/cronp"
: > "$stub_dir/not-a-dir"
printf 'TASKS="review"\nSTATE_DIR="%s/state"\n' "$stub_dir/not-a-dir" > "$cbd/.local/share/maintainer/profiles/cronp/profile.env"
printf '#!/usr/bin/env bash\nexit 0\n' > "$cbd/.local/share/maintainer/run.sh"; chmod +x "$cbd/.local/share/maintainer/run.sh"
make_stub crontab 'case "$1" in -l) exit 0 ;; *) touch "$CRON_WROTE"; cat >/dev/null ;; esac'
CRON_WROTE="$stub_dir/crontab-wrote"; rm -f "$CRON_WROTE"; export CRON_WROTE
PATH="$stub_dir:$PATH" HOME="$cbd" MAINTAINER_PROFILE=cronp bash "$cr" >/dev/null 2>&1; cbrc=$?
if [ "$cbrc" != 0 ] && [ ! -e "$CRON_WROTE" ]; then
    ok "an unwritable STATE_DIR stops the install before crontab is written"
else
    bad "an unwritable STATE_DIR: install rc=$cbrc, crontab written=$([ -e "$CRON_WROTE" ] && echo yes || echo no)"
fi

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
