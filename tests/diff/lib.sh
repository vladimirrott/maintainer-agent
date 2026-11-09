#!/usr/bin/env bash
# Helpers for differential scenarios. record.sh sources this file, then the scenario.
#
# The scenario process runs under `env -i` with PATH set to a directory of
# symlinks to real tools (MX_REALBIN) and nothing else, so a tool nobody stubbed
# and nobody allowed is "command not found" in both trees instead of whatever the
# host happens to have. Variables set by record.sh: MX_TREE MX_WORK MX_RAW MX_HOME
# MX_STUBS MX_REALBIN MX_TMP MX_CWD MX_TIMEOUT. Everything else is built here.
set -euo pipefail
# Directory and file modes are part of the recorded state; the host umask must not leak in.
umask 022

MX_STATE="$MX_WORK/state"
MX_REPO="$MX_WORK/repo"
MX_KEY="$MX_WORK/receipt.key"
MX_RAN=0
MX_ENVV=()
MX_PATH_EXTRA=""
# The tools the programs reach for by name. Each gets a logging stub by default.
MX_STUB_TOOLS="gh claude codex opencode podman systemctl crontab launchctl loginctl notify-send flock tar"

mx_die() { printf 'diff harness: %s\n' "$1" >&2; exit 2; }

# Fixed identity and dates for every git call the scenario or the program makes.
export GIT_AUTHOR_NAME=mx GIT_AUTHOR_EMAIL=mx@example.invalid
export GIT_COMMITTER_NAME=mx GIT_COMMITTER_EMAIL=mx@example.invalid
export GIT_AUTHOR_DATE="2026-01-01T00:00:00+0000" GIT_COMMITTER_DATE="2026-01-01T00:00:00+0000"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export TZ=UTC LC_ALL=C LANG=C PYTHONDONTWRITEBYTECODE=1 PYTHONHASHSEED=0

# mx_stub NAME [BODY]: a stub on the program's PATH. Every call writes, before
# BODY runs, one line to each of four logs (BODY is an argument or stdin, run as bash):
#   calls.log           NAME and argv, in call order across ALL stubs
#   argv.NAME.log       argv of this stub only
#   env.NAME.log        the environment variables that change what a tool does
#   stdin.NAME.log      what the program piped into the stub (empty when nothing)
# The stub reads its stdin to log it and hands BODY the same bytes again, so a
# program that feeds a stub through a pipe or a here-document is compared too.
mx_stub() {
    local name="$1" body
    if [ $# -ge 2 ]; then body="$2"; else body="$(cat)"; fi
    {
        printf '#!/usr/bin/env bash\n'
        printf '_mx_dir=%q\n_mx_name=%q\n' "$MX_RAW" "$name"
        cat <<'HDR'
_mx_argv="$(printf ' %q' "$@")"
printf 'argv:%s\n' "$_mx_argv" >> "$_mx_dir/argv.$_mx_name.log"
printf '%s:%s\n' "$_mx_name" "$_mx_argv" >> "$_mx_dir/calls.log"
_mx_in=""
if [ ! -t 0 ]; then _mx_in="$(cat; printf x)"; _mx_in="${_mx_in%x}"; exec 0< <(printf '%s' "$_mx_in"); fi
printf 'stdin: %q\n' "$_mx_in" >> "$_mx_dir/stdin.$_mx_name.log"
# A credential is logged as set or unset, never by value. GH_TOKEN counts as set
# when it holds anything; MAINTAINER_* names that look like a secret do too.
_mx_e=""
for _mx_v in GH_HOST GH_CONFIG_DIR HOME LC_ALL LANG TZ; do
    if [ -n "${!_mx_v+x}" ]; then _mx_e+=" $_mx_v=${!_mx_v@Q}"; else _mx_e+=" $_mx_v=<unset>"; fi
done
for _mx_v in GH_TOKEN GITHUB_TOKEN; do
    if [ -n "${!_mx_v:-}" ]; then _mx_e+=" $_mx_v=<set>"; else _mx_e+=" $_mx_v=<unset>"; fi
done
for _mx_v in $(compgen -v MAINTAINER_ | LC_ALL=C sort); do
    case "$_mx_v" in
        *KEY*|*TOKEN*|*SECRET*|*PASSWORD*) _mx_e+=" $_mx_v=<set>" ;;
        *) _mx_e+=" $_mx_v=${!_mx_v@Q}" ;;
    esac
done
printf 'env:%s\n' "$_mx_e" >> "$_mx_dir/env.$_mx_name.log"
unset _mx_dir _mx_name _mx_argv _mx_in _mx_e _mx_v
HDR
        printf '%s\n' "$body"
    } > "$MX_STUBS/$name"
    chmod +x "$MX_STUBS/$name"
}

# Every tool in MX_STUB_TOOLS answers with exit 0 and no output until a scenario
# says otherwise. tar passes through to the real tar so an extraction still works.
mx_default_stubs() {
    local t
    for t in $MX_STUB_TOOLS; do
        case "$t" in
            tar) mx_stub tar "exec \"$MX_REALBIN/tar\" \"\$@\"" ;;
            *)   mx_stub "$t" 'exit 0' ;;
        esac
    done
}

# mx_env NAME VALUE: one environment variable for the program under test. A later
# call for the same NAME replaces the earlier one.
mx_env() {
    local kept=() e
    for e in ${MX_ENVV[@]+"${MX_ENVV[@]}"}; do
        case "$e" in "$1="*) ;; *) kept+=("$e") ;; esac
    done
    MX_ENVV=(${kept[@]+"${kept[@]}"} "$1=$2")
}
# mx_path_add DIR: directory searched after the stubs and before the real tools.
mx_path_add() { MX_PATH_EXTRA="$MX_PATH_EXTRA:$1"; }

# The environment maintainer-merge and maintainer-repo read when run.sh is not
# the caller: the five names the loader wants, a fixed signing key, and PROD_GLOBS.
mx_merge_env() {
    mkdir -p "$MX_STATE"
    mx_write_key
    mx_env MAINTAINER_STATE "$MX_STATE"
    mx_env MAINTAINER_ACCOUNT testuser
    mx_env MAINTAINER_SLUG o/r
    mx_env MAINTAINER_REPO "$MX_REPO"
    mx_env MAINTAINER_PROFILE magent
    mx_env MAINTAINER_RECEIPT_KEY "$MX_KEY"
    mx_env PROD_GLOBS 'crates/*/src/*'
}

mx_write_key() {
    printf '%s' "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" > "$MX_KEY"
    chmod 600 "$MX_KEY"
}

# mx_receipt PR HEAD KIND PROOF: a signed receipt written the way the gate writes
# one (json.dump indent=2, HMAC-SHA256 over those bytes), with a fixed timestamp.
mx_receipt() {
    mkdir -p "$MX_STATE/receipts"
    python3 -I - "$MX_STATE/receipts/$1.json" "$1" "$2" "$3" "$4" "$MX_KEY" <<'PYEOF'
import hashlib, hmac, json, sys
out, pr, head, kind, proof, key_path = sys.argv[1:7]
d = {"pr": int(pr), "head": head, "kind": kind, "proof": proof,
     "recorded_at": "2026-01-01T00:00:00+00:00", "recorded_by": "mxuser"}
payload = json.dumps(d, indent=2).encode()
key = open(key_path).read().strip().encode()
d["signature"] = hmac.new(key, payload, hashlib.sha256).hexdigest()
json.dump(d, open(out, "w"), indent=2)
PYEOF
}

# mx_commit DIR MESSAGE [FILE CONTENT]...: commit with a date one second after the
# last commit this scenario made, so the history is the same on every run.
MX_CLOCK=0
mx_commit() {
    local dir="$1" msg="$2"; shift 2
    while [ $# -ge 2 ]; do
        mkdir -p "$dir/$(dirname "$1")"
        printf '%s\n' "$2" > "$dir/$1"
        git -C "$dir" add -- "$1"
        shift 2
    done
    MX_CLOCK=$((MX_CLOCK + 1))
    local stamp; stamp="$(printf '2026-01-01T00:00:%02d+0000' "$MX_CLOCK")"
    GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" \
        git -C "$dir" commit -q --allow-empty -m "$msg"
}

# mx_git_repo [DIR]: an empty repository on main.
mx_git_repo() {
    local dir="${1:-$MX_REPO}"
    git init -q -b main "$dir"
}

# mx_update_gh PR STATE DECISION AUTHOR [REVIEW_STATE [REVIEW_USER [REVIEW_HEAD]]]
# [CROSS [MODIFY]]: a gh stub that answers the three questions `maintainer-merge
# update` asks, as the account testuser: the pull request facts, the reviews, and
# who is logged in. MX_UPDATE_HEAD is the 40-hex head it reports. Variables, not
# positional arguments, keep a scenario readable:
#   MX_U_REVIEW="APPROVED testuser $MX_UPDATE_HEAD"   MX_U_CROSS=false  MX_U_MODIFY=false
MX_UPDATE_HEAD="1111111111111111111111111111111111111111"
mx_update_gh() {
    local pr="$1" state="$2" decision="$3" author="$4"
    local cross="${MX_U_CROSS:-false}" modify="${MX_U_MODIFY:-false}"
    local rv_state rv_user rv_head
    read -r rv_state rv_user rv_head <<<"${MX_U_REVIEW:-APPROVED testuser $MX_UPDATE_HEAD}"
    local dec_json='null'; [ "$decision" = "-" ] || dec_json="\"$decision\""
    mkdir -p "$MX_WORK/gh-answers"
    printf '{"headRefOid":"%s","mergeStateStatus":"%s","reviewDecision":%s,"author":{"login":"%s"},"isCrossRepository":%s,"maintainerCanModify":%s}\n' \
        "$MX_UPDATE_HEAD" "$state" "$dec_json" "$author" "$cross" "$modify" > "$MX_WORK/gh-answers/pr-view.json"
    if [ "$rv_state" = "-" ]; then : > "$MX_WORK/gh-answers/reviews.jsonl"
    else
        printf '{"user":{"login":"%s"},"state":"%s","commit_id":"%s"}\n' "$rv_user" "$rv_state" "$rv_head" \
            > "$MX_WORK/gh-answers/reviews.jsonl"
    fi
    mx_stub gh "case \"\$*\" in
  *'auth switch'*) exit 0 ;;
  *'api user'*) echo testuser ;;
  *'api --paginate'*) cat \"$MX_WORK/gh-answers/reviews.jsonl\" ;;
  *'pr view $pr'*) cat \"$MX_WORK/gh-answers/pr-view.json\" ;;
esac"
}

# mx_pr_origin PR: a bare origin that holds the pull request's head at refs/pull/PR/head.
mx_pr_origin() {
    git init -q --bare -b main "$MX_WORK/origin.git"
    git -C "$MX_REPO" remote add origin "$MX_WORK/origin.git"
    git -C "$MX_REPO" push -q origin "main:refs/pull/$1/head" main
}

# mx_release_fixture: the repository maintainer-repo release-check reads. MX_REPO
# has a bare origin, one commit tagged v0.1.0 with an empty Unreleased section,
# and the profile globs the check counts. A scenario adds its own commits, then
# calls mx_release_push.
mx_release_fixture() {
    mx_merge_env
    mx_env PROD_GLOBS 'bin/* lib/*'
    mx_env SHIPPED_GLOBS 'bin/*'
    mx_git_repo "$MX_REPO"
    git init -q --bare -b main "$MX_WORK/origin.git"
    git -C "$MX_REPO" remote add origin "$MX_WORK/origin.git"
    mx_commit "$MX_REPO" "release 0.1.0" CHANGELOG.md "# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01
### Added
- first release"
    git -C "$MX_REPO" tag v0.1.0
}
mx_release_push() { git -C "$MX_REPO" push -q origin main v0.1.0; }

# mx_deploy_fixture: a HOME that looks like a finished ./install.sh for a profile
# named p, plus a clean checkout, state directory and logging stubs that answer
# like a healthy machine. maintainer-doctor reads exactly this layout.
mx_deploy_fixture() {
    local share="$MX_HOME/.local/share/maintainer" src="$MX_WORK/source" commit f
    mkdir -p "$share/profiles/p" "$share/backends" "$MX_HOME/.local/bin" \
             "$MX_HOME/.config/systemd/user" "$MX_STATE/runs" "$MX_STATE/receipts"
    mx_git_repo "$src"
    mx_commit "$src" "install source" README.md installed
    commit="$(git -C "$src" rev-parse --short HEAD)"
    printf 'version=v0.0.0\ncommit=%s\ninstalled_at=2026-01-01T00:00:00Z\ninstalled_from=%s\n' \
        "$commit" "$src" > "$share/VERSION"
    for f in run.sh run-instance.sh; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$share/$f"
        chmod +x "$share/$f"
    done
    printf '# claude backend\n' > "$share/backends/claude.sh"
    printf 'REPO_SLUG="o/r"\nGH_ACCOUNT="testuser"\nPOST=off\nREPO_PATH="%s"\nSTATE_DIR="%s"\n' \
        "$MX_REPO" "$MX_STATE" > "$share/profiles/p/profile.env"
    printf '{}\n' > "$share/profiles/p/deny.json"
    python3 -I - "$share/profiles/p" <<'PYEOF2'
import json, os, sys
d = sys.argv[1]
rules = ["Bash(rule%d:*)" % i for i in range(120)] + ["Read(~/.ssh/**)"]
json.dump({"permissions": {"deny": rules}}, open(os.path.join(d, "settings.json"), "w"))
json.dump({"permissions": {"deny": rules}}, open(os.path.join(d, "settings-rehearsal.json"), "w"))
PYEOF2
    ln -s "$MX_TREE/bin/maintainer" "$MX_HOME/.local/bin/maintainer"
    ln -s "$MX_TREE/bin/maintainer-merge" "$MX_HOME/.local/bin/maintainer-merge"
    : > "$MX_HOME/.config/systemd/user/podman-userns-warmup.service"
    mx_git_repo "$MX_REPO"
    mx_commit "$MX_REPO" "init" README.md checkout
    mx_path_add "$MX_HOME/.local/bin"
    mx_env MAINTAINER_PROFILE p
    mx_stub gh <<'STUB'
case "$*" in
  *'api user'*) echo testuser ;;
  *'auth token'*) echo ghp_0123456789abcdefghij ;;
  *'run list'*) echo '[{"workflowName":"ci","status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","url":"u"}]' ;;
esac
STUB
    mx_stub claude <<'STUB'
case "$*" in *--version*) echo '2.1.0 (Claude Code)' ;; esac
STUB
    mx_stub systemctl <<'STUB'
case "$*" in
  *list-timers*) echo 'Tue 2026-11-10 09:00:00 UTC 20h left - - maintainer@p-review.timer maintainer@p-review.service' ;;
  *list-unit-files*) echo 'maintainer@p-review.timer enabled enabled' ;;
esac
STUB
    mx_stub loginctl 'echo yes'
}

# mx_run PROGRAM [ARG...]: run PROGRAM (a path inside the tree, such as
# bin/maintainer-merge) once, from an empty working directory, with only the
# environment this scenario built. Exactly one call per scenario.
mx_run() {
    [ "$MX_RAN" = 0 ] || mx_die "a scenario runs exactly one program invocation"
    MX_RAN=1
    local prog="$1"; shift
    [ -x "$MX_TREE/$prog" ] || mx_die "$MX_TREE/$prog is not an executable file"
    local base=(
        "PATH=$MX_STUBS$MX_PATH_EXTRA:$MX_REALBIN" "HOME=$MX_HOME" "TMPDIR=$MX_TMP"
        "TZ=UTC" "LC_ALL=C" "LANG=C" "USER=mxuser" "LOGNAME=mxuser"
        "PYTHONDONTWRITEBYTECODE=1" "PYTHONHASHSEED=0"
        "GIT_AUTHOR_NAME=$GIT_AUTHOR_NAME" "GIT_AUTHOR_EMAIL=$GIT_AUTHOR_EMAIL"
        "GIT_COMMITTER_NAME=$GIT_COMMITTER_NAME" "GIT_COMMITTER_EMAIL=$GIT_COMMITTER_EMAIL"
        "GIT_AUTHOR_DATE=$GIT_AUTHOR_DATE" "GIT_COMMITTER_DATE=$GIT_COMMITTER_DATE"
        "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1" "GIT_TERMINAL_PROMPT=0"
    )
    mkdir -p "$MX_CWD" "$MX_TMP"
    local rc=0 t0=$SECONDS
    ( cd "$MX_CWD" && exec timeout -k 5 "$MX_TIMEOUT" \
          env -i "${base[@]}" ${MX_ENVV[@]+"${MX_ENVV[@]}"} "$MX_TREE/$prog" "$@" \
    ) >"$MX_RAW/stdout" 2>"$MX_RAW/stderr" </dev/null || rc=$?
    if [ "$rc" = 124 ] && [ $((SECONDS - t0)) -ge "$MX_TIMEOUT" ]; then
        mx_die "$prog timed out after ${MX_TIMEOUT}s; this is a hang, not a result"
    fi
    printf '%s\n' "$rc" > "$MX_RAW/rc"
}

mx_default_stubs
