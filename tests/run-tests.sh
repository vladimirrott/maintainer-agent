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
# Generated, then asserted. The tests read the artifact the agent is handed, not
# the spec it came from: a generator bug that drops every absolute spelling is
# invisible to a test that reads the input.
wall_dir="$stub_dir/wall"; mkdir -p "$wall_dir"
cp "$root/profiles/sysknife/deny.json" "$root/profiles/sysknife/opencode.json" "$wall_dir/"
python3 "$root/scripts/render-settings.py" "$wall_dir" /home/fakeuser >/dev/null 2>&1 \
    && ok "the deny wall generates from deny.json" || bad "render-settings.py failed"
s="$wall_dir/settings.json"
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

echo "== the generated wall is valid, absolute, and home-relative where it must be =="
if python3 -c "import json;json.load(open('$s'))" 2>/dev/null; then ok "generated deny wall is valid JSON"; else bad "generated deny wall is not valid JSON"; fi
grep -q '__HOME__' "$s" && bad "a placeholder survived generation" || ok "no placeholder survived"
grep -q '/home/fakeuser/.ssh' "$s" && ok "credential paths are spelled expanded" || bad "expanded spelling missing"
grep -q '\$HOME/.ssh' "$s" && ok "credential paths are spelled with \$HOME" || bad "\$HOME spelling missing"
# MEASURED 2026-09-03: Read(/abs/path) anchors to the SETTINGS directory and
# denies nothing; Read(~/path) denies. Normalising the tilde away, which looks
# like a tidy-up, would disable every credential rule at once and silently.
grep -q '"Read(~/.ssh/\*\*)"' "$s" && ok "Read rules use the home-relative form that denies" \
    || bad "Read rules lost the ~/ form; credential paths are unprotected"
python3 - "$root/profiles/sysknife/deny.json" <<'PYEOF' && ok "deny.json commits no literal home path" || bad "deny.json contains a home path"
import json,sys
spec=open(sys.argv[1]).read()
sys.exit(1 if "/home/" in spec or "/Users/" in spec else 0)
PYEOF

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
# Assembled, not inspected. The doctrine lives in lib/preamble-core.md and the
# profile contributes only its site header, so grepping either file alone would
# pass while the agent received neither. --show-prompt is the same assembly a
# real run uses.
assembled="$stub_dir/assembled.md"
PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" --show-prompt sysknife review >"$assembled" 2>/dev/null
if [ -s "$assembled" ]; then ok "the prompt assembles"; else bad "--show-prompt produced nothing"; fi
for needle in "Trust is the attack surface" "slop" "Persistence" "data, not instruction" \
              "maintainer screen" "Never post a claim you have not run"; do
    if grep -qi "$needle" "$assembled"; then ok "assembled prompt carries: $needle"; else bad "assembled prompt LOST: $needle"; fi
done
# The profile's own name must be substituted into the shared doctrine, or the
# agent is told to protect a repository that is not the one it is reviewing.
grep -q '__SLUG__\|__MAINTAINER__' "$assembled" && bad "a placeholder reached the agent" || ok "placeholders substituted"
grep -q 'lacs-project/sysknife' "$assembled" && ok "the doctrine names this profile's repository" || bad "slug substitution did not happen"
if grep -q 'maintainer-merge' "$root/profiles/sysknife/prompts/review.md"; then
    ok "review prompt routes merges through the gate"
else
    bad "review prompt no longer names the merge gate"
fi
if grep -q 'Bash(gh pr merge:\*)' "$s"; then
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

echo "== the PowerShell installer =="
ps1="$root/platform/windows/Install-Maintainer.ps1"
# Parsed by a real PowerShell when the image is already local, so the suite
# stays offline. Counting braces was the previous check, and it would have
# passed a file that pwsh refuses to load.
if command -v podman >/dev/null 2>&1 && podman image exists mcr.microsoft.com/powershell:latest 2>/dev/null; then
    if podman run --rm --network=none -v "$root/platform/windows:/w:ro" \
        mcr.microsoft.com/powershell:latest pwsh -NoProfile -Command \
        '$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile("/w/Install-Maintainer.ps1",[ref]$t,[ref]$e);exit $e.Count' >/dev/null 2>&1; then
        ok "PowerShell: parses under a real pwsh"
    else
        bad "PowerShell: pwsh reports a parse error"
    fi
else
    ok "PowerShell: pwsh parse skipped (no local image); cmdlet checks below still run"
fi
# $Profile is an automatic PowerShell variable. Shadowing it in a param block is
# legal and confusing, so the parameter is named ProfileName.
grep -qE '\[string\]\$Profile\b' "$ps1" && bad "the param shadows PowerShell's automatic \$Profile" \
    || ok "PowerShell: no parameter shadows an automatic variable"
grep -q 'TASKS=' "$ps1" && ok "PowerShell reads the task list from the profile" \
    || bad "PowerShell hardcodes a task list"
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

echo "== the receipt cannot be asserted by the agent, only observed =="
if grep -q 'Bash(maintainer-merge receipt:\*)' "$s"; then
    ok "hand-written receipts are denied to the agent"
else
    bad "the agent can write its own receipt; the merge gate proves nothing"
fi
if grep -q 'cmd_verify' "$mg" && grep -q 'THE GUARD DOES NOT BITE' "$mg"; then
    ok "verify runs the mutation and refuses a guard that stays green"
else
    bad "there is no observed-verification path"
fi
if grep -q '"kind": "observed"' "$mg" || grep -q 'observed' "$mg"; then
    ok "receipts record whether they were observed or merely asserted"
else
    bad "receipts do not distinguish observation from assertion"
fi

echo "== absolute-path spellings of every blocked verb are denied =="
# MEASURED: /usr/bin/touch evaded a rule written for touch. The matcher keys on
# the command as written, so each verb needs its absolute forms too.
for verb in "git push" "git tag" "gh pr merge" "cargo publish" "npm publish"; do
    cmd=${verb%% *}
    if grep -q "Bash(/usr/bin/$verb:\*)" "$s"; then
        ok "absolute form denied: /usr/bin/$verb"
    else
        bad "absolute form NOT denied: /usr/bin/$verb"
    fi
done
grep -q 'Bash(git -C:\*)' "$s" && ok "git -C (flags before the verb) is denied" || bad "git -C evades the push/tag rules"

echo "== install is idempotent (a second run must replace, not accumulate) =="
ih="$stub_dir/inst"; mkdir -p "$ih"
HOME="$ih" "$root/install.sh" >/dev/null 2>&1
HOME="$ih" "$root/install.sh" >/dev/null 2>&1
nested=$(find "$ih/.local/share/maintainer" -type d \( -name profiles -o -name backends \) 2>/dev/null | wc -l)
if [ "$nested" = "2" ]; then ok "two installs leave one profiles/ and one backends/"; else bad "two installs left $nested such dirs (cp -r nested them)"; fi
want=$(python3 -c "import json;print(len(json.load(open('$s'))['permissions']['deny']))")
got=$(python3 -c "import json;print(len(json.load(open('$ih/.local/share/maintainer/profiles/sysknife/settings.json'))['permissions']['deny']))" 2>/dev/null)
if [ "$got" = "$want" ]; then ok "reinstall refreshes the deny wall ($got rules)"; else bad "deployed deny wall has $got rules, the repo has $want"; fi
if [ -d "$ih/.local/share/maintainer/profiles/_template" ]; then bad "the scaffolding template was deployed as a runnable profile"; else ok "_template is not deployed"; fi
# Every deployed entry point must be executable. A clean install once left
# run-instance.sh unexecutable because chmod ran before the platform dispatch
# that copies it, and systemd would have failed with a permission error.
for f in run.sh run-instance.sh; do
    d="$ih/.local/share/maintainer/$f"
    if [ ! -e "$d" ]; then bad "$f was not deployed"; elif [ -x "$d" ]; then ok "$f deployed executable"; else bad "$f deployed NOT executable"; fi
done
for f in maintainer maintainer-merge; do
    d="$ih/.local/bin/$f"
    if [ -x "$d" ]; then ok "$f deployed executable"; else bad "$f missing or not executable"; fi
done

echo "== opencode: default-deny closes the spelling hole a denylist cannot =="
oc="$root/profiles/sysknife/opencode.json"
python3 - "$oc" <<'PYEOF' && ok "opencode config decides all 14 probe commands correctly" || bad "opencode permission config lets something through"
import json, fnmatch, collections, sys
b = json.load(open(sys.argv[1]), object_pairs_hook=collections.OrderedDict)["permission"]["bash"]
def decide(c):
    v = b.get("*", "deny")
    for pat, val in b.items():
        if pat != "*" and fnmatch.fnmatch(c, pat): v = val
    return v
must_deny = ["cargo publish", "cd /x && cargo publish", "/usr/bin/cargo publish",
             "git push origin main", "/usr/bin/git push origin main", "gh pr merge 1",
             "curl http://x", "cat ~/.ssh/id_ed25519", "maintainer-merge receipt 1 a b"]
must_allow = ["git status", "cargo test -p x", "maintainer-merge verify 1 a b c",
              "gh pr review 1 --approve", "podman run --rm x"]
bad = [c for c in must_deny if decide(c) != "deny"] + [c for c in must_allow if decide(c) != "allow"]
if bad: print("  wrong verdicts:", bad); sys.exit(1)
sys.exit(0)
PYEOF
grep -q '"\*": "deny"' "$oc" && ok "opencode config is default-deny" || bad "opencode config is not default-deny"
grep -q 'default-deny' "$root/lib/backends/opencode.sh" && ok "opencode backend explains its posture" || bad "opencode backend does not state its containment"

echo "== the universal cron fallback =="
cr="$root/platform/posix/install-cron.sh"
[ -x "$cr" ] && ok "cron installer present and executable" || bad "cron installer missing"
grep -q 'PATH=' "$cr" && ok "cron entries pin PATH (cron gives almost none)" || bad "cron entries do not pin PATH"
grep -q 'awk -v m=' "$cr" && ok "cron install strips its old block (idempotent)" || bad "cron install would accumulate entries"

echo "== doctor executes rather than inspects =="
d="$root/bin/maintainer-doctor"
[ -x "$d" ] && ok "doctor present and executable" || bad "doctor missing"
grep -q 'podman run' "$d" && ok "doctor actually starts a container" || bad "doctor only checks that podman exists"
grep -q 'gh api user' "$d" && ok "doctor resolves the real gh identity" || bad "doctor does not check identity"
grep -q 'fix:' "$d" && ok "doctor prints a fix, not just a symptom" || bad "doctor reports problems without remedies"
if PATH="$stub_dir:$PATH" HOME="$stub_dir/nothing" bash "$d" --quick >/dev/null 2>&1; then
    bad "doctor passed against an empty home; it inspects nothing"
else
    ok "doctor fails against an empty home"
fi

echo "== housekeeping: prune and release-check =="
mr="$root/bin/maintainer-repo"
[ -x "$mr" ] && ok "maintainer-repo present and executable" || bad "maintainer-repo missing"
grep -q 'gh pr list' "$mr" && ok "prune consults open PRs before deleting a branch" || bad "prune could delete a branch that still has an open PR"
grep -q 'merge-base --is-ancestor' "$mr" && ok "prune defines merged as an ancestor of origin/main" || bad "prune uses a weaker merged test"
grep -qE 'case "\$br" in main\|master' "$mr" && ok "prune never touches main" || bad "prune does not exclude main"
# The release verdict must come from the CHANGELOG, not from commit subjects.
# An earlier version read subject lines for the word "security" and scored a
# genuine authorization fix as zero, because its subject said "gate mutating
# query actions".
grep -q 'Unreleased' "$mr" && ok "release-check reads the CHANGELOG Unreleased section" || bad "release-check no longer reads the CHANGELOG"
grep -q 'rests on file counts alone' "$mr" && ok "release-check warns when the CHANGELOG is unreadable" || bad "release-check would pass silently over a missing CHANGELOG"
if grep -q "format=%s.*grep -ciE 'security" "$mr"; then bad "release-check still guesses from commit subjects"; else ok "release-check does not guess from commit subjects"; fi


echo "== --timers enables unit files that exist =="
# The bug: the loop globbed $root/systemd, a directory this repository has never
# had. With nullglob off it ran once on the literal pattern, and
# `systemctl enable '*.timer'` aborted the install having enabled nothing. A
# file-existence check cannot see this; only running the install can.
th="$stub_dir/timerhome"; mkdir -p "$th"
make_stub systemctl 'printf "%s\n" "$*" >> "$SYSTEMCTL_LOG"; exit 0'
make_stub loginctl 'echo yes'
SYSTEMCTL_LOG="$stub_dir/systemctl.log"; : > "$SYSTEMCTL_LOG"
PATH="$stub_dir:$PATH" HOME="$th" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" "$root/install.sh" --timers >/dev/null 2>&1
enabled=$(grep -c 'enable --now maintainer@' "$SYSTEMCTL_LOG" 2>/dev/null || echo 0)
units_in_repo=$(find "$root/platform/linux" -name '*.timer' | wc -l)
if [ "$enabled" = "$units_in_repo" ] && [ "$enabled" -gt 0 ]; then
    ok "--timers enabled all $enabled timer units"
else
    bad "--timers enabled $enabled of $units_in_repo units"
fi
grep -q "enable --now \*\.timer" "$SYSTEMCTL_LOG" && bad "--timers passed an unexpanded glob to systemctl" \
    || ok "--timers never passes a literal glob"
for u in $(find "$root/platform/linux" -name '*.timer' -exec basename {} \;); do
    grep -q "stamp-$u" "$SYSTEMCTL_LOG" 2>/dev/null
done
[ -e "$th/.local/share/systemd/timers" ] && ok "a stamp is written before enabling (no catch-up storm)" \
    || bad "no stamp written; enabling fires every missed slot at once"

echo "== every command the prompt names is declared, and resolves =="
# A prompt told an unattended run to call `sysknife-maint screen <pr>` after that
# command had been renamed to `maintainer screen`. The run report carried a
# screen verdict for a command that could not have produced one. Nothing caught
# it: the evals check that a RULE is present, not that a tool exists.
#
# Scanned over the ASSEMBLED prompt, because the doctrine and the task prompt
# come from different files and only the assembly is what the agent reads.
# Every task, not a sample: a stale command name in the one prompt nobody
# assembled is exactly the case this check exists for.
# shellcheck disable=SC1091
( . "$root/profiles/sysknife/profile.env"
  for tk in $TASKS; do
      PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" --show-prompt sysknife "$tk" \
          >"$stub_dir/p-$tk.md" 2>/dev/null
  done )
# shellcheck disable=SC1091
( . "$root/profiles/sysknife/profile.env"
  python3 - "$stub_dir" "$REQUIRED_COMMANDS" "$KNOWN_NAMES" <<'PYEOF'
import glob, os, re, sys
d, required, known = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
allowed = set(required) | set(known)
# Hyphenated lowercase words inside backticks, taken as the first token of the
# span. Precise enough that the current prompts yield nine names, not ninety;
# calibrated by checking it flags a renamed command and nothing else.
span = re.compile(r"`([^`\n]+)`")
name = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)+$")
seen, undeclared = set(), {}
for f in sorted(glob.glob(os.path.join(d, "p-*.md"))):
    for m in span.findall(open(f).read()):
        tok = m.split()[0] if m.split() else ""
        if not name.match(tok):
            continue
        seen.add(tok)
        if tok not in allowed:
            undeclared.setdefault(tok, os.path.basename(f))
for tok, f in undeclared.items():
    print(f"  {tok} (in {f}) is neither a REQUIRED_COMMAND nor a KNOWN_NAME")
# A declaration nobody uses is padding, and padding is how this check would go
# quiet: add every plausible name and it can never fail again.
unused = [k for k in known if k not in seen]
for k in unused:
    print(f"  KNOWN_NAMES lists '{k}', which no assembled prompt uses")
sys.exit(1 if undeclared or unused else 0)
PYEOF
) && ok "every hyphenated name in the prompt is declared, and no declaration is padding" \
  || bad "an undeclared or unused name in the prompt (see above)"

echo "== the cadence gate holds a task that ran too recently =="
# launchd cannot express "every N days" and cron's day-of-month stepping fires
# on the 31st and again on the 1st. Before this gate, the macOS installer said
# the since-last-run state enforced the cadence; nothing did, so `audit` would
# have run five times a week.
cad="$stub_dir/cadence"; mkdir -p "$cad/state"
age_last() { touch -d "@$(( $(date +%s) - $1 ))" "$cad/state/last-review.json"; }
echo '{"run_id":"x"}' > "$cad/state/last-review.json"
cad_run() { MAINTAINER_STATE_DIR="$cad" PATH="$stub_dir:$PATH" \
            env "$@" bash "$root/lib/run.sh" sysknife review 2>&1; }
# MIN_HOURS_review is 6.
age_last 7200
out=$(cad_run X=1)
printf '%s' "$out" | grep -q '^skipped' && ok "a task inside its minimum interval is skipped" \
    || bad "the gate did not hold a 2h-old task (got: $(printf '%s' "$out" | head -1))"
printf '%s' "$out" | grep -q 'MAINTAINER_FORCE' && ok "the skip names the override" || bad "the skip does not say how to override"
age_last 32400
out=$(cad_run X=1)
printf '%s' "$out" | grep -q '^skipped' && bad "a task past its interval was skipped anyway" \
    || ok "a task past its minimum interval proceeds"
age_last 60
out=$(cad_run MAINTAINER_FORCE=1)
printf '%s' "$out" | grep -q '^skipped' && bad "MAINTAINER_FORCE did not override the gate" \
    || ok "MAINTAINER_FORCE overrides the gate"
# The gate must read the profile's number, not a constant compiled into run.sh.
grep -q 'MIN_HOURS_\$task' "$root/lib/run.sh" && ok "the interval comes from the profile" \
    || bad "run.sh no longer reads MIN_HOURS_<task> from the profile"

echo "== rehearsal: POST=off does the work and reaches nobody =="
reh="$wall_dir/settings-rehearsal.json"
[ -f "$reh" ] && ok "a rehearsal wall is generated beside the live one" || bad "no rehearsal wall generated"
python3 - "$s" "$reh" <<'PYEOF' && ok "the rehearsal wall is a strict superset of the live wall" || bad "the rehearsal wall is not a superset"
import json, sys
live = set(json.load(open(sys.argv[1]))["permissions"]["deny"])
reh = set(json.load(open(sys.argv[2]))["permissions"]["deny"])
sys.exit(0 if live < reh else 1)
PYEOF
# One assertion per verb. An alternation would let a lost rule hide behind one
# that still matched, which is how a guard goes vacuous.
for verb in "gh pr review" "gh pr comment" "gh issue comment" "gh issue create" "gh label" "gh api -X POST"; do
    grep -qF "Bash($verb:*)" "$reh" && ok "rehearsal blocks '$verb'" || bad "rehearsal does NOT block '$verb'"
done
grep -qF "Bash(/usr/bin/gh issue comment:*)" "$reh" && ok "rehearsal blocks the absolute spelling too" \
    || bad "rehearsal misses /usr/bin spellings"
# The prompt must say so as well. A wall alone produces a confused run that
# keeps trying; the sentence is what makes it stop.
banner=$(PATH="$stub_dir:$PATH" MAINTAINER_POST=off bash "$root/lib/run.sh" --show-prompt sysknife review 2>/dev/null)
printf '%s' "$banner" | grep -q 'REHEARSAL' && ok "POST=off puts the rehearsal notice in the prompt" \
    || bad "POST=off does not tell the agent it is rehearsing"
printf '%s' "$banner" | grep -q 'list what you WOULD have posted' && ok "the rehearsal asks for the drafts it withheld" \
    || bad "a rehearsal that withholds without recording is not reviewable"
default=$(PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" --show-prompt sysknife review 2>/dev/null)
printf '%s' "$default" | grep -q 'REHEARSAL' && bad "the rehearsal notice appears when POST is on" \
    || ok "POST=on carries no rehearsal notice"
grep -q 'backend_rehearsal' "$root/lib/backends/claude.sh" && ok "claude declares it can enforce POST=off" \
    || bad "claude no longer declares rehearsal support"
grep -q 'backend_rehearsal' "$root/lib/backends/codex.sh" && bad "codex claims rehearsal support it cannot enforce" \
    || ok "codex does not claim rehearsal support (it has no deny list)"
grep -q 'backend_rehearsal' "$root/lib/run.sh" && ok "run.sh refuses a rehearsal on a backend that cannot enforce it" \
    || bad "run.sh would hand POST=off to a backend with no per-command control"
# A new profile must start silent.
grep -q 'MAINTAINER_POST:-off' "$root/profiles/_template/profile.env" && ok "a scaffolded profile starts at POST=off" \
    || bad "a new profile would post on its first run"

echo "== the doctrine is not optional =="
# lib/preamble-core.md carries the injection rule, the screen rule and the
# evidence rule. A run assembled without it is an unattended agent with none of
# them, so its absence must stop the run rather than shorten the prompt.
lay2="$stub_dir/nodoctrine"; mkdir -p "$lay2/profiles/sysknife/prompts"
cp "$root/lib/run.sh" "$lay2/run.sh"; cp -r "$root/lib/backends" "$lay2/backends"
cp "$root/profiles/sysknife/profile.env" "$lay2/profiles/sysknife/"
cp "$root/profiles/sysknife/prompts/"*.md "$lay2/profiles/sysknife/prompts/"
cp "$root/lib/prose-style.md" "$lay2/prose-style.md"
out=$(PATH="$stub_dir:$PATH" HOME="$stub_dir" bash "$lay2/run.sh" --show-prompt sysknife review 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'preamble-core'; then
    ok "a tree with no core preamble refuses to run"
else
    bad "a run assembled a prompt with no doctrine in it (rc=$rc)"
fi
cp "$root/lib/preamble-core.md" "$lay2/preamble-core.md"
PATH="$stub_dir:$PATH" HOME="$stub_dir" bash "$lay2/run.sh" --show-prompt sysknife review >/dev/null 2>&1 \
    && ok "and runs once the core preamble is restored" || bad "the core preamble is not found in the installed layout"

echo "== --show-prompt shows, and changes nothing =="
snap_before=$(find "$root" -newer "$root/README.md" -type f 2>/dev/null | wc -l)
lock_before=$(ls "$HOME/.local/state/sysknife-maint/state" 2>/dev/null | wc -l)
PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" --show-prompt sysknife issues >/dev/null 2>&1
lock_after=$(ls "$HOME/.local/state/sysknife-maint/state" 2>/dev/null | wc -l)
check "--show-prompt writes no state" "$lock_after" "$lock_before"
PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" --show-prompt sysknife issues 2>/dev/null | grep -q 'preview only' \
    && ok "--show-prompt marks its context as a preview" || bad "--show-prompt passes off a fake context as real"

echo "== uninstall removes the tool and keeps the audit trail =="
uh="$stub_dir/unin"; mkdir -p "$uh"
HOME="$uh" "$root/install.sh" >/dev/null 2>&1
mkdir -p "$uh/.local/state/sysknife-maint/runs"; echo "a run" > "$uh/.local/state/sysknife-maint/runs/keep.md"
PATH="$stub_dir:$PATH" HOME="$uh" "$root/install.sh" --uninstall >/dev/null 2>&1
[ -d "$uh/.local/share/maintainer" ] && bad "uninstall left the deployed tree" || ok "uninstall removes the deployed tree"
[ -e "$uh/.local/bin/maintainer" ] && bad "uninstall left commands on PATH" || ok "uninstall removes the commands"
[ -f "$uh/.local/state/sysknife-maint/runs/keep.md" ] \
    && ok "uninstall keeps the audit trail (it is the record of what was posted in your name)" \
    || bad "uninstall deleted the audit trail"

echo "== new-profile.sh makes CONTRIBUTING's promise true =="
np="$stub_dir/np"; mkdir -p "$np"; cp -r "$root"/* "$np/" 2>/dev/null
rm -rf "$np/.git"
( cd "$np" && ./new-profile.sh demo acme/widget /tmp/widget acmebot "Ada" ) >/dev/null 2>&1
[ -f "$np/profiles/demo/profile.env" ] && ok "new-profile scaffolds a profile" || bad "new-profile wrote no profile"
grep -rq '__[A-Z_]*__' "$np/profiles/demo" && bad "a placeholder survived scaffolding" || ok "every placeholder is substituted"
grep -q 'REPO_SLUG="acme/widget"' "$np/profiles/demo/profile.env" && ok "the slug lands in profile.env" || bad "the slug did not substitute"
tasks=$(sed -n 's/^TASKS="\(.*\)"/\1/p' "$np/profiles/demo/profile.env" | wc -w)
made=$(find "$np/platform/linux" -name 'maintainer@demo-*.timer' | wc -l)
check "one timer per task" "$made" "$tasks"
( cd "$np" && ./new-profile.sh demo acme/widget /tmp/widget acmebot ) >/dev/null 2>&1 \
    && bad "new-profile overwrote an existing profile" || ok "new-profile refuses to overwrite"
# The scaffolded profile must produce a real prompt, not a template with holes.
( cd "$np" && PATH="$stub_dir:$PATH" bash lib/run.sh --show-prompt demo review 2>/dev/null ) | grep -q 'acme/widget' \
    && ok "a scaffolded profile assembles a prompt naming its own repository" \
    || bad "a scaffolded profile cannot assemble a prompt"
# And no code file may carry a repository's name for it to work.
if grep -q 'MAINTAINER_TASKS' "$root/bin/maintainer" && grep -q 'MAINTAINER_TASKS' "$root/lib/run.sh"; then
    ok "the task list comes from the profile, not from bin/maintainer"
else
    bad "bin/maintainer still hardcodes the task list"
fi

echo "== status answers the question a maintainer actually has =="
out=$(MAINTAINER_PROFILE=sysknife python3 "$root/bin/maintainer" status 2>&1)
for want in "profile" "posting" "task" "review"; do
    printf '%s' "$out" | grep -qi "$want" && ok "status reports $want" || bad "status does not report $want"
done
printf '%s' "$out" | grep -qE 'in [0-9]+' && ok "status converts the next-run time to a duration" \
    || bad "status does not show when the next run is"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
