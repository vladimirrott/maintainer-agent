#!/usr/bin/env bash
# Run adversarial payloads inside the verification container and check that each
# one is stopped. Every control the merge gate claims is measured here, with the
# attack it is supposed to stop, because a flag being present in a command line
# is not evidence that it does anything.
#
#   ./tests/containment-probe.sh
#
# Needs podman or docker and pulls a small image. Not part of the offline suite:
# it runs real payloads and takes about a minute.
set -uo pipefail
pass=0; fail=0
ok()  { printf '  \033[32mstopped\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mGOT THROUGH\033[0m  %s\n' "$1"; fail=$((fail+1)); }

rt=""
command -v podman >/dev/null 2>&1 && rt=podman
[ -z "$rt" ] && command -v docker >/dev/null 2>&1 && rt=docker
[ -n "$rt" ] || { echo "no container runtime; this probe measured nothing" >&2; exit 1; }
IMG="${PROBE_IMAGE:-docker.io/library/bash:5}"
"$rt" image inspect "$IMG" >/dev/null 2>&1 || "$rt" pull -q "$IMG" >/dev/null 2>&1 \
    || { echo "cannot obtain $IMG" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
printf 'host file\n' > "$work/repofile"

# The same flags bin/maintainer-merge uses. Kept here deliberately rather than
# sourced: if the two drift, this probe stops describing the real gate, and the
# last check below is what catches that.
hardened() {
    "$rt" run --rm \
        --timeout "${PROBE_TIMEOUT:-15}" \
        --network=none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=256m \
        --pids-limit 512 \
        --memory 2g \
        --cpus 2 \
        -v "$work:/repo:z" -w /repo "$IMG" \
        sh -c "$1" 2>&1
}

echo "== what an adversarial pull request would try, inside the gate =="

out="$(hardened 'timeout 5 bash -c "echo > /dev/tcp/1.1.1.1/53" 2>&1; echo rc=$?')"
printf '%s' "$out" | grep -q 'rc=0' && bad "outbound TCP to 1.1.1.1:53" || ok "outbound TCP (--network=none)"

out="$(hardened 'getent hosts github.com >/dev/null 2>&1; echo rc=$?')"
printf '%s' "$out" | grep -q 'rc=0' && bad "DNS resolution" || ok "DNS resolution"

out="$(hardened 'echo pwned > /etc/passwd 2>&1; echo rc=$?')"
printf '%s' "$out" | grep -q 'rc=0' && bad "writing to /etc inside the image" || ok "writing to the image (--read-only)"

out="$(hardened 'printf "#!/bin/sh\necho ran\n" > /tmp/x && chmod +x /tmp/x && /tmp/x 2>&1; echo rc=$?')"
printf '%s' "$out" | grep -q '^ran' && bad "executing from /tmp" || ok "executing from /tmp (noexec)"

out="$(hardened 'grep -c . /proc/self/status >/dev/null; capsh --print 2>/dev/null | grep -i "current:" || grep CapEff /proc/self/status')"
if printf '%s' "$out" | grep -qE 'CapEff:\s*0+$'; then ok "capabilities (CapEff is empty)"
else bad "capabilities: $(printf '%s' "$out" | tr -d '\n' | cut -c1-60)"; fi

out="$(hardened 'grep NoNewPrivs /proc/self/status')"
printf '%s' "$out" | grep -q 'NoNewPrivs:.*1' && ok "privilege escalation (NoNewPrivs=1)" \
    || bad "NoNewPrivs is not set: $out"

# `if [ -n "$out" ] || true` was the first version of this, which is true
# whatever happens: with --pids-limit deleted the probe still reported "stopped".
# A check that cannot fail is the exact defect this file exists to catch, in the
# file that exists to catch it.
#
# The measurable property: with a pid cap, a fork bomb cannot reach the cap's
# worth of processes before the container dies. Count what it managed.
out="$(hardened 'n=0; while [ $n -lt 4000 ]; do sleep 30 & n=$((n+1)); done 2>/dev/null; echo spawned=$n')"
spawned="$(printf '%s' "$out" | sed -n 's/.*spawned=\([0-9]*\).*/\1/p' | tail -1)"
if [ -z "$spawned" ]; then
    ok "fork bomb (the container died before it could report)"
elif [ "$spawned" -lt 1000 ]; then
    ok "fork bomb (stopped at $spawned processes, cap is 512)"
else
    bad "fork bomb spawned $spawned processes; the pid cap is not in force"
fi

out="$(hardened 'head -c 4G /dev/zero > /tmp/balloon 2>&1; echo rc=$?')"
printf '%s' "$out" | grep -q 'rc=0' && bad "allocating 4G in a 256m tmpfs" || ok "memory balloon"

# The control that had to be found the hard way. GNU `timeout` around the client
# kills the CLI and leaves the container running: measured, two containers still
# spinning three minutes later with the host load at 5.5. podman's own --timeout
# is enforced by conmon, so the container dies whatever happens to the client.
before="$("$rt" ps -q 2>/dev/null | wc -l)"
hardened "while :; do :; done" >/dev/null 2>&1
sleep 3
after="$("$rt" ps -q 2>/dev/null | wc -l)"
[ "$after" -le "$before" ] && ok "infinite loop (--timeout, and no container left behind)" \
    || bad "an infinite loop left $((after-before)) container(s) running after the gate gave up"

# The first version of this check asserted that /proc/1/environ was unreadable,
# which can never be true: inside the container pid 1 IS the payload, so it is
# reading its own environment. The property that matters is whether anything
# from the HOST crosses, so plant a canary and look for it.
out="$(GH_TOKEN=ghp_PROBECANARY0000 ANTHROPIC_API_KEY=sk-PROBECANARY \
       hardened 'env; cat /proc/1/environ 2>/dev/null | tr "\0" "\n"')"
printf '%s' "$out" | grep -q PROBECANARY \
    && bad "a host credential reached the container" \
    || ok "host credentials (podman passes no host environment)"

out="$(hardened 'ls /repo; echo "escaped" > /repo/../escape 2>&1; echo rc=$?')"
[ -e "$work/../escape" ] && bad "writing outside the mount" || ok "writing outside the bind mount"

echo
echo "== the probe still describes the real gate =="
for flag in -- '--network=none' '--cap-drop=ALL' 'no-new-privileges' '--read-only' \
            'noexec' '--pids-limit' '--memory' '--cpus'; do
    [ "$flag" = "--" ] && continue
    if grep -q -- "$flag" "$(dirname "$0")/../bin/maintainer-merge"; then
        ok "bin/maintainer-merge still passes $flag"
    else
        bad "the gate no longer passes $flag; this probe is measuring something else"
    fi
done

printf '\n  %d stopped, %d got through\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
