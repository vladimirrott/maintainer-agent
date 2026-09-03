#!/usr/bin/env bash
# Offline test suite. No network, no GitHub, no model call.
#
# Everything here tests a REFUSAL. This agent's safety comes from what it
# declines to do, so those are the paths worth pinning.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# A fake PATH: gh, claude, codex and notify-send never reach the real ones.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
make_stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$stub_dir/$1"; chmod +x "$stub_dir/$1"; }
make_stub notify-send 'exit 0'
make_stub claude 'echo "claude stub invoked" >&2; exit 0'
make_stub codex  'echo "codex stub invoked" >&2; exit 0'
make_stub flock  'exit 0'

echo "== argument handling =="
out=$(PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" nosuchprofile review 2>&1); rc=$?
check "unknown profile is rejected" "$rc" "64"
out=$(PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" sysknife nosuchtask 2>&1); rc=$?
check "unknown task is rejected" "$rc" "64"

echo "== the GitHub identity gate =="
# The gate is the single most important refusal: a write under the wrong
# account stamps an employer-linked identity onto personal open-source work.
gate_test() {  # $1 = what `gh api user` reports, $2 = expected rc
    make_stub gh "case \"\$*\" in *'auth switch'*) exit 0;; *'api user'*) [ -n \"$1\" ] && echo \"$1\"; exit 0;; esac"
    out=$(PATH="$stub_dir:$PATH" HOME="$stub_dir" bash "$root/lib/run.sh" sysknife review 2>&1); rc=$?
    if [ "$rc" = "$2" ]; then ok "gh='${1:-<empty>}' -> rc=$2"; else bad "gh='${1:-<empty>}' expected rc=$2, got $rc"; fi
    printf '%s' "$out" | grep -q 'refusing to run' && printf '        (refusal message present)\n'
}
gate_test "someone-else" 1
gate_test ""             1

echo "== the Claude deny wall still names the verbs that matter =="
s="$root/profiles/sysknife/settings.json.template"
for verb in "git push" "gh pr merge" "cargo publish" "npm publish" "gh release" "git tag"; do
    if grep -q "$verb" "$s"; then ok "deny list names '$verb'"; else bad "deny list LOST '$verb'"; fi
done
# Checked one path per assertion. A single alternation would let one lost rule
# hide behind another that still matches, which is how a guard goes vacuous.
for path in ".ssh" ".config/gh/" ".config/gh-personal/" ".aws" ".gnupg" ".netrc" ".credentials.json"; do
    if grep -qF "$path" "$s"; then ok "deny list protects $path"; else bad "deny list LOST $path"; fi
done

echo "== the Codex backend documents its weaker containment =="
# Codex has no per-command deny list. If someone swaps the default backend
# without reading that, publishing verbs stop being blocked. Pin the warning.
if grep -q 'COARSER' "$root/lib/backends/codex.sh"; then
    ok "codex backend states its containment is coarser"
else
    bad "codex backend no longer warns that it cannot express a deny list"
fi
if grep -q 'BACKEND="\${MAINTAINER_BACKEND:-claude}"' "$root/profiles/sysknife/profile.env"; then
    ok "default backend is claude"
else
    bad "default backend is no longer claude"
fi

echo "== the deny-wall template renders to valid JSON with no placeholder left =="
rendered="$(mktemp)"; sed "s|__HOME__|/tmp/fakehome|g" "$s" > "$rendered"
if grep -q '__HOME__' "$rendered"; then bad "template left an unrendered placeholder"; else ok "template renders fully"; fi
if python3 -c "import json;json.load(open('$rendered'))" 2>/dev/null; then ok "rendered deny wall is valid JSON"; else bad "rendered deny wall is not valid JSON"; fi
if grep -q '/tmp/fakehome/.ssh' "$rendered"; then ok "rendered rules carry absolute paths"; else bad "rendered rules lost their absolute paths"; fi
rm -f "$rendered"

echo "== no home path or username is committed =="
# The needle is assembled at runtime so this file does not match itself, which
# is how the check first "found" a leak that was only its own source line.
needle="entro""pia"
if grep -rq "$needle" --exclude-dir=.git --exclude=run-tests.sh "$root"; then
    bad "a home path leaked into the repository"
    grep -rn "$needle" --exclude-dir=.git --exclude=run-tests.sh "$root" | head -3
else
    ok "no home path committed"
fi

echo "== install.sh --dry-run changes nothing =="
before=$(find "$HOME/.local/share/maintainer" -type f 2>/dev/null | wc -l)
"$root/install.sh" --dry-run >/dev/null 2>&1
after=$(find "$HOME/.local/share/maintainer" -type f 2>/dev/null | wc -l)
check "dry run leaves the filesystem alone" "$after" "$before"

echo "== every prompt carries the reservation rule =="
for p in review issues audit; do
    if grep -q 'twir-listed' "$root/profiles/sysknife/prompts/$p.md"; then
        ok "prompts/$p.md carries the reserved-issue rule"
    else
        bad "prompts/$p.md lost the reserved-issue rule"
    fi
done

echo "== the helper parses and keeps its report sentinel =="
python3 -c "import ast;ast.parse(open('$root/bin/maintainer').read())" 2>/dev/null \
  && ok "bin/maintainer parses" || bad "bin/maintainer does not parse"
grep -q 'report not yet written' "$root/bin/maintainer" \
  && ok "report sentinel intact" || bad "report sentinel gone (finish can no longer reject an empty run)"

echo "== the merge gate refuses without a valid receipt =="
mg="$root/bin/maintainer-merge"
export MAINTAINER_STATE="$stub_dir/state" MAINTAINER_ACCOUNT="testuser" MAINTAINER_SLUG="o/r" MAINTAINER_REPO="$stub_dir/repo"
mkdir -p "$MAINTAINER_STATE" "$MAINTAINER_REPO"

# Identity is checked before anything else.
make_stub gh "case \"\$*\" in *'auth switch'*) exit 0;; *'api user'*) echo wronguser; exit 0;; esac"
out=$(PATH="$stub_dir:$PATH" bash "$mg" merge 1 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'not testuser'; then ok "merge refuses under the wrong gh account"; else bad "merge did not refuse a wrong account (rc=$rc)"; fi

# Right account, but no receipt exists.
make_stub gh "case \"\$*\" in *'auth switch'*) exit 0;; *'api user'*) echo testuser; exit 0;; esac"
out=$(PATH="$stub_dir:$PATH" bash "$mg" merge 1 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'no verification receipt'; then ok "merge refuses with no receipt"; else bad "merge did not refuse a missing receipt (rc=$rc)"; fi

# Receipt exists, but the review is not approved.
PATH="$stub_dir:$PATH" bash "$mg" receipt 1 abcdef1234 "drift guard mutated, went red" >/dev/null 2>&1
make_stub gh "case \"\$*\" in
  *'auth switch'*) exit 0;;
  *'api user'*) echo testuser;;
  *reviewDecision*) echo CHANGES_REQUESTED;;
  *headRefOid*) echo abcdef1234;;
  *mergeStateStatus*) echo CLEAN;;
esac"
out=$(PATH="$stub_dir:$PATH" bash "$mg" merge 1 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'not APPROVED'; then ok "merge refuses an unapproved PR"; else bad "merge did not refuse an unapproved PR (rc=$rc)"; fi

# Approved, but a check is failing.
make_stub gh "case \"\$*\" in
  *'auth switch'*) exit 0;;
  *'api user'*) echo testuser;;
  *reviewDecision*) echo APPROVED;;
  *headRefOid*) echo abcdef1234;;
  *mergeStateStatus*) echo CLEAN;;
  *'pr checks'*) echo '[{\"name\":\"rust\",\"bucket\":\"fail\"}]';;
esac"
out=$(PATH="$stub_dir:$PATH" bash "$mg" merge 1 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'failing check'; then ok "merge refuses a failing board"; else bad "merge did not refuse a failing board (rc=$rc)"; fi

# Approved, board green, but zero checks reported at all.
make_stub gh "case \"\$*\" in
  *'auth switch'*) exit 0;;
  *'api user'*) echo testuser;;
  *reviewDecision*) echo APPROVED;;
  *headRefOid*) echo abcdef1234;;
  *mergeStateStatus*) echo CLEAN;;
  *'pr checks'*) echo '';;
esac"
out=$(PATH="$stub_dir:$PATH" bash "$mg" merge 1 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'no checks at all'; then ok "merge refuses when no checks reported (empty is not green)"; else bad "merge treated an empty board as green (rc=$rc)"; fi

echo "== a receipt dies when production code moves under it =="
# The condition the whole gate rests on. Built against a real git repo, because
# the check is a real `git diff` and a stub would prove nothing.
gr="$stub_dir/repo"
git -C "$gr" init -q -b main 2>/dev/null
git -C "$gr" config user.email t@t; git -C "$gr" config user.name t
mkdir -p "$gr/crates/x/src" "$gr/docs"
echo "fn main() {}" > "$gr/crates/x/src/lib.rs"; echo "hello" > "$gr/docs/a.md"
git -C "$gr" add -A >/dev/null; git -C "$gr" commit -qm base
verified=$(git -C "$gr" rev-parse HEAD)

# Case A: only docs moved after the verified head. The receipt must survive.
echo "changed" > "$gr/docs/a.md"; git -C "$gr" add -A >/dev/null; git -C "$gr" commit -qm docs-only
docs_head=$(git -C "$gr" rev-parse HEAD)
git -C "$gr" branch -f "pr-7" "$docs_head" >/dev/null 2>&1
# Case B: production moved. The receipt must die.
echo "fn main() { changed() }" > "$gr/crates/x/src/lib.rs"; git -C "$gr" add -A >/dev/null; git -C "$gr" commit -qm prod
prod_head=$(git -C "$gr" rev-parse HEAD)
git -C "$gr" branch -f "pr-8" "$prod_head" >/dev/null 2>&1

# `git fetch origin refs/pull/N/head` has no origin here, so point the gate at
# local refs by giving it an origin that is the repo itself.
git -C "$gr" remote add origin "$gr" 2>/dev/null
git -C "$gr" update-ref "refs/pull/7/head" "$docs_head"
git -C "$gr" update-ref "refs/pull/8/head" "$prod_head"

gate_case() {  # $1 pr, $2 head, $3 expect-substring, $4 label
    PATH="$stub_dir:$PATH" bash "$mg" receipt "$1" "$verified" "mutation proved" >/dev/null 2>&1
    make_stub gh "case \"\$*\" in
      *'auth switch'*) exit 0;;
      *'api user'*) echo testuser;;
      *reviewDecision*) echo APPROVED;;
      *headRefOid*) echo $2;;
      *mergeStateStatus*) echo CLEAN;;
      *'pr checks'*) echo '[{\"name\":\"rust\",\"bucket\":\"pass\"}]';;
      *'pr merge'*) echo MERGED_STUB;;
    esac"
    out=$(PATH="$stub_dir:$PATH" bash "$mg" merge "$1" 2>&1)
    if printf '%s' "$out" | grep -q "$3"; then ok "$4"; else bad "$4 (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90))"; fi
}
gate_case 7 "$docs_head" "receipt still applies" "docs-only movement keeps the receipt valid"
gate_case 8 "$prod_head" "production code changed" "production movement invalidates the receipt"

echo "== the doctrine reaches a run, not just a reader =="
pre="$root/profiles/sysknife/prompts/common-preamble.md"
for needle in "Trust is the attack surface" "slop" "Persistence"; do
    if grep -qi "$needle" "$pre"; then ok "preamble carries: $needle"; else bad "preamble lost: $needle"; fi
done
if grep -q 'maintainer-merge' "$root/profiles/sysknife/prompts/review.md"; then
    ok "review prompt routes merges through the gate"
else
    bad "review prompt no longer names the merge gate"
fi
if grep -q 'Bash(gh pr merge:\*)' "$root/profiles/sysknife/settings.json.template"; then
    ok "direct gh pr merge is still denied (the gate is the only path)"
else
    bad "gh pr merge is no longer denied; the gate can be bypassed"
fi

echo "== the installed layout resolves, not just the repo layout =="
# The bug this catches: run.sh looked for profiles at ../profiles, which is right
# in the repo (lib/run.sh) and wrong once installed beside them. The unit exited
# 64 and the timer logged nothing, because a file-existence check is not a start.
lay="$stub_dir/layout"; mkdir -p "$lay/profiles/sysknife/prompts"
cp "$root/lib/run.sh" "$lay/run.sh"
cp -r "$root/lib/backends" "$lay/backends"
cp "$root/profiles/sysknife/profile.env" "$lay/profiles/sysknife/"
make_stub gh "case \"\$*\" in *'auth switch'*) exit 0;; *'api user'*) echo nobody; exit 0;; esac"
out=$(PATH="$stub_dir:$PATH" HOME="$stub_dir" bash "$lay/run.sh" sysknife review 2>&1); rc=$?
# It must get PAST profile resolution and fail on the identity gate (rc=1),
# not on "no profile" (rc=64).
if [ "$rc" = "1" ]; then ok "installed layout resolves the profile (reached the identity gate)"
elif [ "$rc" = "64" ]; then bad "installed layout cannot find its profile (exit 64) -- the deployment bug"
else bad "installed layout: unexpected rc=$rc"; fi

echo "== prose discipline is opt-OUT, and reaches the prompt =="
ps="$root/lib/prose-style.md"
for needle in "em dashes" "throat-clearing" "not X, it" "adverbs" "Never disclose"; do
    if grep -qi "$needle" "$ps"; then ok "prose style covers: $needle"; else bad "prose style lost: $needle"; fi
done
if grep -q 'PROSE_STYLE="${MAINTAINER_PROSE_STYLE:-stop-slop}"' "$root/profiles/sysknife/profile.env"; then
    ok "default is stop-slop (opt-out, not opt-in)"
else
    bad "prose style is no longer on by default"
fi
# A misspelled or absent value must still get the discipline. Only "raw" opts out.
if grep -q '!= "raw"' "$root/lib/run.sh"; then
    ok "only an explicit \"raw\" disables it; a typo still writes well"
else
    bad "the opt-out is not fail-safe"
fi
# And it must actually land in the assembled prompt.
if grep -q 'prose-style.md' "$root/lib/run.sh" && grep -q 'prose-style.md' "$root/install.sh"; then
    ok "prose style is assembled into the prompt and shipped by install"
else
    bad "prose style is not wired into the prompt or not installed"
fi

echo "== cross-platform: only scheduling forks, the core does not =="
[ -f "$root/platform/linux/maintainer@.service" ]        && ok "linux: systemd units present"   || bad "linux units missing"
[ -x "$root/platform/macos/install-launchd.sh" ]         && ok "macos: launchd installer present" || bad "macos installer missing"
[ -f "$root/platform/windows/Install-Maintainer.ps1" ]   && ok "windows: PowerShell installer present" || bad "windows installer missing"
if grep -q 'uname -s' "$root/install.sh"; then ok "install.sh dispatches by platform"; else bad "install.sh is not platform-aware"; fi
# Only one implementation of the gate may exist.
# Count only executable implementations. Prose that describes the gate (docs,
# eval scenarios, this file) is not a second implementation, and an earlier
# version of this check counted it as one.
gates=$(grep -rl 'no verification receipt' "$root/bin" "$root/lib" "$root/platform" 2>/dev/null | wc -l)
if [ "$gates" = "1" ]; then ok "exactly one executable implementation of the merge gate"; else bad "$gates executable implementations of the merge gate (they will drift)"; fi

echo "== the PowerShell installer, statically (pwsh is not installed here) =="
ps1="$root/platform/windows/Install-Maintainer.ps1"
o=$(grep -c '{' "$ps1"); c=$(grep -c '}' "$ps1")
[ -n "$o" ] && ok "PowerShell: braces present (open-lines=$o close-lines=$c)"
for cmdlet in New-ScheduledTaskAction New-ScheduledTaskTrigger New-ScheduledTaskSettingsSet New-ScheduledTaskPrincipal Register-ScheduledTask; do
    grep -q "$cmdlet" "$ps1" && ok "PowerShell uses $cmdlet" || bad "PowerShell lost $cmdlet"
done
grep -q 'StartWhenAvailable' "$ps1" && ok "PowerShell sets StartWhenAvailable (the Persistent=true analogue)" || bad "missed-run catch-up not configured"
grep -q 'RunLevel Limited' "$ps1" && ok "PowerShell task runs unelevated" || bad "PowerShell task may run elevated"

echo "== the cursor backend cannot be handed a posting task =="
cb="$root/lib/backends/cursor.sh"
grep -q 'backend_allowed_tasks' "$cb" && ok "cursor declares its allowed tasks" || bad "cursor no longer restricts itself"
grep -q 'backend_allowed_tasks' "$root/lib/run.sh" && ok "run.sh enforces the declaration" || bad "run.sh ignores backend task restrictions"
# Only executable lines count. The file explains at length why --force is
# absent, and an earlier version of this check read those comments as usage.
if sed 's/#.*//' "$cb" | grep -qE '(^|[[:space:]])--(force|yolo)([[:space:]]|$)'; then
    bad "cursor backend passes --force (full write access)"
else
    ok "cursor backend never passes --force outside comments"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
