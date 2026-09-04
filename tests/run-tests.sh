#!/usr/bin/env bash
# Offline test suite. No network, no GitHub, no model call.
#
# Everything here tests a REFUSAL. This agent's safety comes from what it
# declines to do, so those are the paths worth pinning.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Clear anything a run exports before measuring anything.
#
# Invoked from inside a run, this suite reported 236 passed / 6 failed, and
# worse, two cases in the cadence block PASSED because MAINTAINER_FORCE=1 was
# inherited and the gate they test was disabled. MAINTAINER_POST=off sent every
# run.sh the suite starts down the rehearsal branch, which exits 78 in a
# checkout that has no rendered wall, so the identity gate cases never reached
# the gate they exist to prove.
#
# A suite whose answer depends on who called it is not a measurement.
unset MAINTAINER_FORCE MAINTAINER_POST MAINTAINER_PROFILE MAINTAINER_SETTINGS \
      MAINTAINER_STATE MAINTAINER_STATE_DIR MAINTAINER_SLUG MAINTAINER_REPO \
      MAINTAINER_TASKS MAINTAINER_SKILL MAINTAINER_IN_RUN MAINTAINER_SCRIPTS \
      MAINTAINER_BACKEND MAINTAINER_PROSE_STYLE MAINTAINER_ACCOUNT
pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# A fake PATH: gh, claude, codex and notify-send never reach the real ones.
stub_dir="$(mktemp -d)"
# And a scratch state directory, so a test run cannot append to the real audit
# trail. It did: 22 empty logs from --show-prompt calls landed in the live one.
export MAINTAINER_STATE_DIR="$stub_dir/state-root"
mkdir -p "$MAINTAINER_STATE_DIR/state"
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

echo "== every profile's deny wall names the verbs that matter =="
# Generated, then asserted. The tests read the artifact the agent is handed, not
# the spec it came from: a generator bug that drops every absolute spelling is
# invisible to a test that reads the input.
#
# EVERY profile. This block pinned profiles/sysknife by name, so deleting a rule
# from a second profile's deny.json left all three gates green and that
# profile's containment was unguarded.
for pdj in "$root"/profiles/*/deny.json; do
    pn="$(basename "$(dirname "$pdj")")"
    wd="$stub_dir/wall-$pn"; mkdir -p "$wd"
    cp "$pdj" "$wd/"
    [ -f "$(dirname "$pdj")/opencode.json" ] && cp "$(dirname "$pdj")/opencode.json" "$wd/"
    python3 "$root/scripts/render-settings.py" "$wd" /home/fakeuser >/dev/null 2>&1 \
        && ok "$pn: the deny wall generates from deny.json" || bad "$pn: render-settings.py failed"
    w="$wd/settings.json"
    for verb in "git push" "gh pr merge" "cargo publish" "npm publish" "gh release" "git tag" \
                "gh repo delete" "gh secret" "maintainer-merge receipt"; do
        grep -qF "Bash($verb:*)" "$w" && ok "$pn: denies '$verb'" || bad "$pn: LOST '$verb'"
        grep -qF "Bash(/usr/bin/$verb:*)" "$w" \
            && ok "$pn: denies '/usr/bin/$verb'" || bad "$pn: no absolute spelling of '$verb'"
    done
    for path in ".ssh" ".config/gh/" ".aws" ".gnupg" ".netrc" ".credentials.json"; do
        grep -qF "$path" "$w" && ok "$pn: protects $path" || bad "$pn: LOST $path"
    done
done
# The primary profile's artifact stays available to the assertions below.
wall_dir="$stub_dir/wall-sysknife"
s="$wall_dir/settings.json"
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

echo "== the wall covers the directories the tools are really installed in =="
# The wall listed three FHS prefixes. On this machine `cargo` is in ~/.cargo/bin,
# `npm` under ~/.local/lib/nodejs/.../bin and `maintainer-merge` in ~/.local/bin,
# so the publishing verbs had no absolute rule and the single rule protecting
# the merge gate's receipt was bypassable by writing the full path.
real_wall="$stub_dir/wall-real"; mkdir -p "$real_wall"
cp "$root/profiles/sysknife/deny.json" "$real_wall/"
python3 "$root/scripts/render-settings.py" "$real_wall" "$HOME" >/dev/null 2>&1
python3 - "$real_wall/settings.json" <<'PYEOF' && ok "every verb is denied at its real install directory" || bad "a verb has no rule where its binary actually lives"
import json, os, shutil, sys
deny = set(json.load(open(sys.argv[1]))["permissions"]["deny"])
missing = []
for verb in ("cargo publish", "npm publish", "git push", "gh pr merge",
             "gh repo delete", "maintainer-merge receipt"):
    real = shutil.which(verb.split()[0])
    if not real:
        continue
    rule = f"Bash({os.path.dirname(real)}/{verb}:*)"
    if rule not in deny:
        missing.append(rule)
for m in missing:
    print("  missing:", m)
sys.exit(1 if missing else 0)
PYEOF

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


echo "== the merge gate reads mergeStateStatus, which it used to discard =="
# It fetched mergeStateStatus and never read the variable, which shellcheck
# found by noticing it was unused. BEHIND is the one that matters: the branch is
# not up to date with its base, so every green check describes a tree that is
# not the one being merged.
# The CLEAN case reaches the fetch, so #9 needs a ref like the others.
git -C "$gr" update-ref "refs/pull/9/head" "$verified"
ms_case() {  # $1 = mergeStateStatus, $2 = expected substring
    PATH="$stub_dir:$PATH" bash "$mg" receipt 9 "$verified" "mutation proved" >/dev/null 2>&1
    make_stub gh "case \"\$*\" in
      *'auth switch'*) exit 0;;
      *'api user'*) echo testuser;;
      *reviewDecision*) echo APPROVED;;
      *headRefOid*) echo $verified;;
      *mergeStateStatus*) echo $1;;
      *'pr checks'*) echo '[{\"name\":\"rust\",\"bucket\":\"pass\"}]';;
      *'pr merge'*) echo MERGED_STUB;;
    esac"
    out=$(PATH="$stub_dir:$PATH" bash "$mg" merge 9 2>&1)
    if printf '%s' "$out" | grep -q "$2"; then ok "mergeStateStatus $1 -> $2"
    else bad "mergeStateStatus $1 did not produce '$2' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90))"; fi
}
ms_case BEHIND  "BEHIND its base"
ms_case DIRTY   "conflicts"
ms_case BLOCKED "BLOCKED"
ms_case UNKNOWN "only CLEAN and HAS_HOOKS"
ms_case CLEAN   "receipt valid"

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
# Every script the repository ships must reach the deployment. transcript.py did
# not, and the backend's fallback hid it: runs kept working and stopped
# recording which commands the agent ran.
for f in "$root"/scripts/*.py; do
    n="$(basename "$f")"
    [ -f "$ih/.local/share/maintainer/scripts/$n" ] && ok "scripts/$n deployed" \
        || bad "scripts/$n was never deployed"
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
[ -e "$th/.local/share/systemd/timers" ] && ok "a stamp is written before enabling (no catch-up storm)" \
    || bad "no stamp written; enabling fires every missed slot at once"

echo "== every command the prompt names is declared, and resolves =="
# A prompt told an unattended run to call `sysknife-maint screen <pr>` after that
# command had been renamed to `maintainer screen`. The run report carried a
# screen verdict for a command that could not have produced one. Nothing caught
# it: the evals check that a RULE is present, not that a tool exists.
#
# Scanned over the ASSEMBLED prompt, because the doctrine and the task prompt
# come from different files and only the assembly is what the agent reads. Every
# task of every profile: a stale name in the one prompt nobody assembled is the
# case this exists for, and a second profile's prompts are no less able to name
# a command that is gone.
for pe in "$root"/profiles/*/profile.env; do
  pf="$(basename "$(dirname "$pe")")"
  [ "$pf" = "_template" ] && continue
  rm -f "$stub_dir"/p-*.md
  # shellcheck disable=SC1090,SC1091
  ( . "$pe"
    for tk in $TASKS; do
        PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" --show-prompt "$pf" "$tk" \
            >"$stub_dir/p-$tk.md" 2>/dev/null
    done )
  # shellcheck disable=SC1090,SC1091
  ( . "$pe"
    python3 - "$stub_dir" "$REQUIRED_COMMANDS" "$KNOWN_NAMES" <<'PYEOF'
import glob, os, re, sys
d, required, known = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
allowed = set(required) | set(known)
# Hyphenated lowercase words inside backticks, taken as the first token of the
# span. Precise enough that the current prompts yield a handful of names rather
# than ninety; calibrated by checking it flags a renamed command and nothing else.
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
  ) && ok "$pf: every hyphenated name is declared, and none is padding" \
    || bad "$pf: an undeclared or unused name in its prompts (see above)"
done

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
lock_before=$(ls "$HOME/.local/state/sysknife-maint/state" 2>/dev/null | wc -l)
PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" --show-prompt sysknife issues >/dev/null 2>&1
lock_after=$(ls "$HOME/.local/state/sysknife-maint/state" 2>/dev/null | wc -l)
check "--show-prompt writes no state" "$lock_after" "$lock_before"
PATH="$stub_dir:$PATH" bash "$root/lib/run.sh" --show-prompt sysknife issues 2>/dev/null | grep -q 'preview only' \
    && ok "--show-prompt marks its context as a preview" || bad "--show-prompt passes off a fake context as real"
# A preview must leave no trace at all. It opened a log file per call before this
# was asserted, and 22 empty logs from one test run landed in the live trail.
fresh="$stub_dir/fresh-state"; rm -rf "$fresh"; mkdir -p "$fresh"
MAINTAINER_STATE_DIR="$fresh" PATH="$stub_dir:$PATH" \
    bash "$root/lib/run.sh" --show-prompt sysknife review >/dev/null 2>&1
left=$(find "$fresh" -type f 2>/dev/null | wc -l)
check "--show-prompt writes no log into the audit trail" "$left" "0"

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
# A checkout under $HOME must be written as $HOME/..., because profile.env gets
# committed and the adopter's username would go with it. This repository's own
# leak check caught it the first time a profile was scaffolded here.
( cd "$np" && ./new-profile.sh underhome acme/uh "$HOME/src/uh" acmebot "Ada" ) >/dev/null 2>&1
if grep -q 'REPO_PATH=.*\$HOME/src/uh' "$np/profiles/underhome/profile.env"; then
    ok "a checkout under \$HOME is written relative, not expanded"
else
    bad "new-profile wrote a literal home path into a file meant to be committed"
    grep -n 'REPO_PATH' "$np/profiles/underhome/profile.env" | head -1
fi
[ -f "$np/profiles/demo/profile.env" ] && ok "new-profile scaffolds a profile" || bad "new-profile wrote no profile"
grep -rq '__[A-Z_]*__' "$np/profiles/demo" && bad "a placeholder survived scaffolding" || ok "every placeholder is substituted"
grep -q 'REPO_SLUG="acme/widget"' "$np/profiles/demo/profile.env" && ok "the slug lands in profile.env" || bad "the slug did not substitute"
tasks=$(sed -n 's/^TASKS="\(.*\)"/\1/p' "$np/profiles/demo/profile.env" | wc -w)
made=$(find "$np/platform/linux" -name 'maintainer@demo-*.timer' | wc -l)
check "one timer per task" "$made" "$tasks"
( cd "$np" && ./new-profile.sh demo acme/widget /tmp/widget acmebot ) >/dev/null 2>&1 \
    && bad "new-profile overwrote an existing profile" || ok "new-profile refuses to overwrite"
# The closing instructions must name commands that exist. They told the adopter
# to call run.sh by its deployed path after `maintainer run` had replaced it.
nextsteps=$( cd "$np" && ./new-profile.sh steps acme/s /tmp/s acmebot "A" 2>&1 )
printf '%s' "$nextsteps" | grep -q 'maintainer run' && ok "the next steps name the command that exists" \
    || bad "new-profile still points at a path instead of a command"
printf '%s' "$nextsteps" | grep -q 'MAINTAINER_PROFILE' && ok "the next steps say to export the profile" \
    || bad "the next steps would have the adopter querying the wrong profile"
# The scaffolded profile must produce a real prompt, not a template with holes.
( cd "$np" && PATH="$stub_dir:$PATH" bash lib/run.sh --show-prompt demo review 2>/dev/null ) | grep -q 'acme/widget' \
    && ok "a scaffolded profile assembles a prompt naming its own repository" \
    || bad "a scaffolded profile cannot assemble a prompt"
# Two carve-outs an adopter had to discover by hitting them. Both were written
# for profiles/magent first and stayed there, so the next adopter would have hit
# them again: the screen rule reading as a ban on running your own gates, and a
# first run having no previous baseline to diff against.
scaffolded=$( cd "$np" && PATH="$stub_dir:$PATH" bash lib/run.sh --show-prompt demo review 2>/dev/null )
printf '%s' "$scaffolded" | grep -q 'about code arriving' \
    && ok "the template says whose code the agent may run" \
    || bad "the template leaves the screen rule reading as a ban on its own gates"
printf '%s' "$scaffolded" | grep -q 'YOU HAVE NOT REVIEWED' \
    && ok "the template points at the unreviewed range, not the fetch delta" \
    || bad "the template still points the agent at the fetch delta"
printf '%s' "$scaffolded" | grep -q 'first run there is no previous baseline' \
    && ok "the template handles a first run with no baseline" \
    || bad "a scaffolded first run has no instruction for an empty baseline"
# And no code file may carry a repository's name for it to work.
if grep -q 'MAINTAINER_TASKS' "$root/bin/maintainer" && grep -q 'MAINTAINER_TASKS' "$root/lib/run.sh"; then
    ok "the task list comes from the profile, not from bin/maintainer"
else
    bad "bin/maintainer still hardcodes the task list"
fi

echo "== status answers the question a maintainer actually has =="
# Built here rather than read off this machine. These cases used to run against
# whatever profile happened to be deployed and whatever timers happened to be
# registered, so they passed locally and failed the first time CI ran them: on a
# runner there is no deployment and no systemd, and status correctly said so
# while the assertions expected my laptop's answer.
sh_home="$stub_dir/statushome"
mkdir -p "$sh_home/.local/share/maintainer/profiles/sk" \
         "$sh_home/.local/state/sk-maint/state" "$sh_home/.local/state/sk-maint/runs"
cat > "$sh_home/.local/share/maintainer/profiles/sk/profile.env" <<'ENVSK'
PROFILE_NAME="sk"
REPO_SLUG="acme/sk"
REPO_PATH="$HOME/src/sk"
STATE_DIR="$HOME/.local/state/sk-maint"
TASKS="review issues"
MIN_HOURS_review=6
POST="on"
GH_ACCOUNT="acmebot"
ENVSK
printf '{"run_id":"2026-01-01T00-00-review","main_sha":"abc"}\n' \
    > "$sh_home/.local/state/sk-maint/state/last-review.json"
printf '# report\nsecond line\n' > "$sh_home/.local/state/sk-maint/runs/2026-01-01T00-00-review.md"
# A timer that fires in an hour, in the shape systemctl --output=json emits:
# `next` is an absolute timestamp in microseconds, which is what tripped the
# duration column into printing "in 20700 days" the first time.
make_stub systemctl 'case "$*" in
  *list-timers*json*) python3 -c "import json,time;print(json.dumps([{\"unit\":\"maintainer@sk-review.timer\",\"next\":int((time.time()+3600)*1e6)}]))";;
  *) exit 0;;
esac'
out=$(PATH="$stub_dir:$PATH" HOME="$sh_home" MAINTAINER_PROFILE=sk \
      env -u MAINTAINER_STATE -u MAINTAINER_REPO -u MAINTAINER_SLUG -u MAINTAINER_TASKS \
          -u MAINTAINER_STATE_DIR python3 "$root/bin/maintainer" status 2>&1)
for want in "acme/sk" "posting" "review" "issues"; do
    printf '%s' "$out" | grep -q "$want" && ok "status reports $want" || bad "status does not report $want"
done
printf '%s' "$out" | grep -qE 'in [0-9]+' && ok "status converts the next-run time to a duration" \
    || bad "status does not show when the next run is"
printf '%s' "$out" | grep -q '2 lines' && ok "status reports how long the last report was" \
    || bad "status does not size the last report"
printf '%s' "$out" | grep -qi 'never' && ok "status marks a task that has never run" \
    || bad "status does not distinguish a task that never ran"
grep -q 'def cmd_run' "$root/bin/maintainer" && ok "maintainer run wraps the deployed orchestrator" \
    || bad "no maintainer run subcommand"
grep -q 'os.execv' "$root/bin/maintainer" && ok "maintainer run execs run.sh rather than reimplementing it" \
    || bad "maintainer run does not delegate to run.sh"
out=$(python3 "$root/bin/maintainer" run 2>&1); rc=$?
[ "$rc" != 0 ] && ok "maintainer run with no task is refused" || bad "maintainer run accepted an empty task"

echo "== a second profile reads its own settings, not the first one's =="
# Found by scaffolding a profile for this repository and running status against
# it. It printed the new profile's name and POST setting above the FIRST
# profile's repository path and run history, because those came from module
# defaults. An adopter would have read another project's runs as their own.
two="$stub_dir/twoprofiles"; mkdir -p "$two/.local/share/maintainer/profiles/other"
cat > "$two/.local/share/maintainer/profiles/other/profile.env" <<'ENV'
PROFILE_NAME="other"
REPO_PATH="$HOME/src/otherrepo"
REPO_SLUG="someone/otherrepo"
STATE_DIR="$HOME/.local/state/other-maint"
TASKS="triage"
MIN_HOURS_triage=12
POST="off"
ENV
mkdir -p "$two/.local/state/other-maint/runs" "$two/.local/state/other-maint/state"
out=$(env -u MAINTAINER_STATE -u MAINTAINER_REPO -u MAINTAINER_SLUG -u MAINTAINER_TASKS \
      -u MAINTAINER_STATE_DIR HOME="$two" MAINTAINER_PROFILE=other \
      python3 "$root/bin/maintainer" status 2>&1)
printf '%s' "$out" | grep -q 'someone/otherrepo' && ok "status reports the second profile's slug" \
    || bad "status did not read the second profile's slug"
printf '%s' "$out" | grep -q 'src/otherrepo' && ok "status reports the second profile's repository" \
    || bad "status showed the wrong repository for a second profile"
printf '%s' "$out" | grep -q 'triage' && ok "status reports the second profile's task list" \
    || bad "status showed the wrong task list for a second profile"
printf '%s' "$out" | grep -qi 'lacs\|sysknife' && bad "the first profile's data leaked into the second profile's status" \
    || ok "no first-profile data leaks into a second profile"
printf '%s' "$out" | grep -qi 'OFF, rehearsal' && ok "status reads POST from the deployed profile" \
    || bad "status did not read POST"

echo "== the screen decides what may execute on this host =="
# Containment layer 3, and it had no test at all until now. `cargo test` on a
# fork PR runs a stranger's code as this user and `build.rs` runs it at compile
# time, so a screen that errs toward SAFE launders an unknown into a
# reassurance. Every case here is driven through the real cmd_screen.
screen_stub() {  # $1 = files json, $2 = changedFiles count, $3 = diff text
    make_stub gh "case \"\$*\" in
      *'pr view'*) cat <<'J'
{\"files\":$1,\"headRefOid\":\"abcdef1234567890\",\"author\":{\"login\":\"stranger\"},\"title\":\"t\",\"changedFiles\":$2}
J
        ;;
      *'pr diff'*) printf '%s\n' '$3' ;;
      *) exit 1 ;;
    esac"
}
screen_run() { PATH="$stub_dir:$PATH" MAINTAINER_REPO="$stub_dir" python3 "$root/bin/maintainer" screen 1 2>&1; }
screen_case() {  # $1 label, $2 expected substring
    out="$(screen_run)"
    if printf '%s' "$out" | grep -qF "$2"; then ok "$1"
    else bad "$1 (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-100))"; fi
}

screen_stub '[{"path":"README.md"},{"path":"docs/a.md"}]' 2 ''
screen_case "docs-only change is INERT" "VERDICT: INERT"

screen_stub '[{"path":"crates/x/src/lib.rs"}]' 1 ''
screen_case "a .rs file is DO NOT EXECUTE (cargo test runs it)" "VERDICT: DO NOT EXECUTE"

screen_stub '[{"path":"crates/x/build.rs"}]' 1 ''
screen_case "build.rs is DO NOT EXECUTE (it runs at compile time)" "runs at compile time"

screen_stub '[{"path":".github/workflows/ci.yml"}]' 1 ''
screen_case "a workflow change warns against approving its run" "Do NOT approve its queued workflow"

screen_stub '[{"path":"scripts/x.sh"}]' 1 ''
screen_case "a shell script is DO NOT EXECUTE (the gates run it)" "VERDICT: DO NOT EXECUTE"

# A dependency line moved inside Cargo.toml: new third-party code would be built.
screen_stub '[{"path":"Cargo.toml"}]' 1 'diff --git a/Cargo.toml b/Cargo.toml
+[dependencies]
+evil = "1.0"'
screen_case "a dependency change is DO NOT EXECUTE" "dependency lines changed"

# gh returns fewer files than it says exist: the rest were never screened.
screen_stub '[{"path":"README.md"}]' 300 ''
screen_case "a truncated file list fails closed" "never screened"

# An extension the screen does not classify must not fall through to INERT.
screen_stub '[{"path":"assets/blob.bin"}]' 1 ''
screen_case "an unclassifiable file fails closed" "failing closed"

# And if gh cannot answer at all, the screen must refuse rather than guess.
make_stub gh 'exit 1'
out="$(screen_run)"
if printf '%s' "$out" | grep -q 'READ-ONLY'; then ok "an unreachable gh fails closed"
else bad "the screen produced a verdict with no data (got: $(printf '%s' "$out" | head -1))"; fi

echo "== a run cannot start inside another run, and the override does not travel =="
# The agent inherits run.sh's environment. MAINTAINER_FORCE=1 was in it, so
# every run.sh the agent invoked skipped its cadence gate: a repro that should
# have printed "skipped" started a real pass against another repository's
# checkout instead. Nothing forbade the nesting either, so a rehearsal could
# have launched a full run of a posting profile.
out=$(MAINTAINER_IN_RUN="other/review" PATH="$stub_dir:$PATH" \
      bash "$root/lib/run.sh" sysknife review 2>&1); rc=$?
if [ "$rc" = 78 ] && printf '%s' "$out" | grep -q "already inside the run 'other/review'"; then
    ok "a nested run is refused, naming the run it is inside"
else
    bad "a nested run was not refused (rc=$rc)"
fi
# A preview from inside a run stays allowed: reading the prompt harms nothing.
MAINTAINER_IN_RUN="other/review" PATH="$stub_dir:$PATH" \
    bash "$root/lib/run.sh" --show-prompt sysknife review >/dev/null 2>&1 \
    && ok "a preview from inside a run is still allowed" \
    || bad "the nested guard also blocks --show-prompt"

# What the backend actually receives, measured by running one.
envh="$stub_dir/envrun"; mkdir -p "$envh/backends" "$envh/profiles/envp/prompts" "$envh/bin"
cp "$root/lib/run.sh" "$envh/run.sh"
cp "$root/lib/preamble-core.md" "$root/lib/prose-style.md" "$envh/"
cat > "$envh/backends/envdump.sh" <<'BACKEND'
backend_name() { printf 'envdump'; }
backend_check() { return 0; }
backend_run() { env | sort > "$ENVDUMP_OUT"; return 0; }
BACKEND
cat > "$envh/profiles/envp/profile.env" <<'ENVP'
PROFILE_NAME="envp"
REPO_PATH="$HOME/repo"
REPO_SLUG="o/r"
MAINTAINER_NAME="Tester"
GH_ACCOUNT="testuser"
STATE_DIR="${MAINTAINER_STATE_DIR:-$HOME/state}"
HELPER="$HOME/bin/maintainer"
TASKS="review"
MODEL_review="m"
MIN_HOURS_review=6
POST="on"
PROSE_STYLE="raw"
BACKEND="envdump"
LOCK_WAIT=5
REQUIRED_COMMANDS="gh"
KNOWN_NAMES=""
ENVP
printf '# task\n' > "$envh/profiles/envp/prompts/review.md"
printf '# site\n' > "$envh/profiles/envp/prompts/common-preamble.md"
# A helper that behaves like `maintainer start` and `finish` without a repo.
cat > "$envh/bin/maintainer" <<'HELPER'
#!/usr/bin/env bash
case "$1" in
  start)  echo "=== maintainer testrun-review ==="; echo "context";;
  finish) exit 0;;
esac
HELPER
chmod +x "$envh/bin/maintainer"
mkdir -p "$envh/state/state" "$envh/state/runs" "$envh/repo"
make_stub gh "case \"\$*\" in *'api user'*) echo testuser;; esac; exit 0"
printf '# r\n' > "$envh/state/runs/testrun-review.md"
ENVDUMP_OUT="$stub_dir/backend.env" PATH="$stub_dir:$envh/bin:$PATH" HOME="$envh" \
    MAINTAINER_FORCE=1 MAINTAINER_STATE_DIR="$envh/state" \
    bash "$envh/run.sh" envp review >/dev/null 2>&1
if [ -f "$stub_dir/backend.env" ]; then
    ok "the backend ran, so its environment can be measured"
    grep -q '^MAINTAINER_FORCE=' "$stub_dir/backend.env" \
        && bad "MAINTAINER_FORCE reached the backend; nested runs skip their cadence gate" \
        || ok "MAINTAINER_FORCE does not reach the backend"
    grep -q '^MAINTAINER_IN_RUN=envp/review$' "$stub_dir/backend.env" \
        && ok "the backend is told which run it is inside" \
        || bad "MAINTAINER_IN_RUN is not set for the backend"
    grep -q '^MAINTAINER_POST=' "$stub_dir/backend.env" \
        && ok "MAINTAINER_POST does reach the tools (prune has to honour it)" \
        || bad "MAINTAINER_POST is not exported"
else
    bad "the env-dump backend never ran, so this block measured nothing"
fi

echo "== three guards that shipped without a test =="
# All three were found by a run that mutated them and watched every gate stay
# green. A guard nothing tests is a guard that will be deleted by someone tidying
# up, and nobody will know.

# 1. prune must not delete during a rehearsal.
pr="$stub_dir/prunerepo"; rm -rf "$pr"; mkdir -p "$pr"
git -C "$pr" init -q -b main; git -C "$pr" config user.email t@t; git -C "$pr" config user.name t
echo a > "$pr/a"; git -C "$pr" add -A; git -C "$pr" commit -qm base
git -C "$pr" branch merged-one; git -C "$pr" remote add origin "$pr"; git -C "$pr" fetch -q origin 2>/dev/null
make_stub gh 'exit 0'
MAINTAINER_POST=off MAINTAINER_REPO="$pr" MAINTAINER_SLUG="o/r" PATH="$stub_dir:$PATH" \
    bash "$root/bin/maintainer-repo" prune >/dev/null 2>&1
if git -C "$pr" show-ref --verify -q refs/heads/merged-one; then
    ok "prune deletes nothing while POST=off"
else
    bad "a rehearsal deleted a branch"
fi
MAINTAINER_POST=on MAINTAINER_REPO="$pr" MAINTAINER_SLUG="o/r" PATH="$stub_dir:$PATH" \
    bash "$root/bin/maintainer-repo" prune >/dev/null 2>&1
if git -C "$pr" show-ref --verify -q refs/heads/merged-one; then
    bad "prune deleted nothing with POST=on either; the test proves nothing"
else
    ok "prune does delete with POST=on (so the POST=off case means something)"
fi

# 2. the merge gate must not merge during a rehearsal. Same shape as prune:
#    `gh pr merge` runs inside the script, where no deny rule can see it.
grep -q 'POST="\${MAINTAINER_POST:-on}"' "$root/bin/maintainer-merge" \
    && ok "the merge gate reads POST" || bad "the merge gate ignores POST"
# Located by line number rather than by a context window, which was set to four
# lines and missed a five-line guard.
python3 - "$root/bin/maintainer-merge" <<'PYEOF' && ok "the merge gate returns before gh pr merge when POST=off" || bad "a rehearsal could merge a pull request"
import sys
lines = open(sys.argv[1]).read().splitlines()
merge = next((i for i, l in enumerate(lines) if "gh pr merge " in l and not l.strip().startswith("#")), None)
if merge is None:
    print("  no gh pr merge call found at all"); sys.exit(1)
window = lines[max(0, merge - 12):merge]
if not any('"$POST" = off' in l for l in window):
    print("  no POST=off check in the 12 lines before the merge call"); sys.exit(1)
if not any("return 0" in l for l in window):
    print("  the POST=off branch does not return before the merge"); sys.exit(1)
sys.exit(0)
PYEOF

# 3. the profile name must not reach a shell unquoted.
inj="$stub_dir/injhome"; rm -rf "$inj"
evil='pwn"; touch '"$stub_dir"'/INJECTED; :"'
mkdir -p "$inj/.local/share/maintainer/profiles/$evil"
printf 'REPO_SLUG="o/r"\nTASKS="review"\n' > "$inj/.local/share/maintainer/profiles/$evil/profile.env"
rm -f "$stub_dir/INJECTED"
out=$(HOME="$inj" MAINTAINER_PROFILE="$evil" python3 "$root/bin/maintainer" status 2>&1); rc=$?
if [ -e "$stub_dir/INJECTED" ]; then
    bad "a profile name reached the shell: the injection ran"
elif [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'not a plain word'; then
    ok "a profile name that is not a plain word is refused"
else
    bad "the injection did not run, but nothing refused it either (rc=$rc)"
fi
# And the ordinary case must still work, or the refusal is just a broken tool.
ok2="$stub_dir/okhome"; mkdir -p "$ok2/.local/share/maintainer/profiles/plain"
printf 'REPO_SLUG="o/r"\nTASKS="review"\nSTATE_DIR="$HOME/st"\nPOST="off"\n' \
    > "$ok2/.local/share/maintainer/profiles/plain/profile.env"
HOME="$ok2" MAINTAINER_PROFILE=plain python3 "$root/bin/maintainer" status 2>&1 | grep -q 'o/r' \
    && ok "a plain profile name still works" || bad "the name check rejects a valid profile"

echo "== the social preview is the size GitHub actually accepts =="
# GitHub's own docs: at least 640x320, 1280x640 for best display, under 1MB,
# cropped to 2:1. Read from the PNG's IHDR chunk so this needs no image library:
# an optional dependency that is absent turns a gate green, which this project
# has been bitten by before.
python3 - "$root/assets/social-preview.png" <<'PYEOF' && ok "social preview is 1280x640 and under 1MB" || bad "the social preview would be rejected or cropped badly"
import struct, sys, os
p = sys.argv[1]
if not os.path.exists(p):
    print("  no social preview at", p); sys.exit(1)
b = open(p, "rb").read()
if b[:8] != b"\x89PNG\r\n\x1a\n":
    print("  not a PNG; GitHub takes PNG, JPG or GIF"); sys.exit(1)
w, h = struct.unpack(">II", b[16:24])
bad = []
if (w, h) != (1280, 640):
    bad.append(f"{w}x{h}, wanted 1280x640")
if len(b) > 1_000_000:
    bad.append(f"{len(b)} bytes, over the 1MB limit")
for m in bad:
    print("  " + m)
sys.exit(1 if bad else 0)
PYEOF
[ -f "$root/assets/logo.svg" ] && ok "the mark is in the tree" || bad "assets/logo.svg is missing"
grep -q 'assets/logo.svg' "$root/README.md" && ok "the README shows the mark" || bad "the README does not reference the mark"
# The PNG is generated from the SVG. If someone edits the PNG alone the two
# drift, and the thing people see is the one nobody reviewed.
grep -q 'social-preview.svg' "$root/assets/social-preview.html" \
    && ok "the preview page renders the SVG, so the PNG has one source" \
    || bad "the PNG has no reproducible source"

echo "== no tool defaults to a person or a repository =="
# Every bash tool used to carry personal fallbacks: REPO_SLUG to one project,
# ACCOUNT to one GitHub login, REPO_PATH to a directory on one laptop. Harmless
# with one user, wrong with two: a stranger running `maintainer-repo prune` with
# no profile would have queried somebody else's repository.
needle_repo="lacs-project""/sysknife"
needle_user="vladimir""rott"
for f in "$root"/bin/* "$root"/lib/*.sh "$root"/install.sh "$root"/new-profile.sh; do
    [ -f "$f" ] || continue
    # Executable lines only. The files explain the defaults they used to have,
    # and a check that reads its own rationale is the vacuous kind.
    code=$(sed 's/#.*//' "$f")
    if printf '%s' "$code" | grep -qF "$needle_repo"; then
        bad "$(basename "$f") still defaults to a specific repository"
    elif printf '%s' "$code" | grep -qF "$needle_user"; then
        bad "$(basename "$f") still names a specific GitHub account"
    else
        ok "$(basename "$f") names no repository or account in code"
    fi
done
# And it must refuse rather than guess.
nohome="$stub_dir/noprofile"; mkdir -p "$nohome"
for tool in maintainer-repo maintainer-merge; do
    out=$(env -u MAINTAINER_SLUG -u MAINTAINER_REPO -u MAINTAINER_PROFILE -u MAINTAINER_STATE \
              -u MAINTAINER_ACCOUNT HOME="$nohome" bash "$root/bin/$tool" prune 2>&1); rc=$?
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'no profile is deployed'; then
        ok "$tool refuses when no profile says which repository"
    else
        bad "$tool ran without knowing which repository (rc=$rc)"
    fi
done
# Two deployed profiles must be an error, not a coin toss.
two="$stub_dir/twoprof"; mkdir -p "$two/.local/share/maintainer/profiles/alpha" \
                                  "$two/.local/share/maintainer/profiles/beta"
for p in alpha beta; do
    printf 'REPO_SLUG="o/%s"\nREPO_PATH="/tmp/%s"\nSTATE_DIR="/tmp/%s-st"\nGH_ACCOUNT="a"\n' \
        "$p" "$p" "$p" > "$two/.local/share/maintainer/profiles/$p/profile.env"
done
cp "$root/lib/profile.sh" "$two/.local/share/maintainer/profile.sh"
out=$(env -u MAINTAINER_SLUG -u MAINTAINER_REPO -u MAINTAINER_PROFILE -u MAINTAINER_STATE \
          -u MAINTAINER_ACCOUNT HOME="$two" bash "$root/bin/maintainer-repo" release-check 2>&1)
printf '%s' "$out" | grep -q '2 profiles are deployed' \
    && ok "two deployed profiles must be disambiguated, not guessed" \
    || bad "a tool picked a profile on its own"

echo "== a public repository has the files a public repository needs =="
# Checked because they are easy to intend and easy to forget, and because a
# licence that is absent is a licence nobody can rely on.
for f in LICENSE SECURITY.md CODE_OF_CONDUCT.md CODEOWNERS CONTRIBUTING.md CHANGELOG.md \
         .github/PULL_REQUEST_TEMPLATE.md .github/dependabot.yml \
         .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/feature.yml \
         .github/ISSUE_TEMPLATE/config.yml .github/workflows/ci.yml; do
    [ -s "$root/$f" ] && ok "$f is present and not empty" || bad "$f is missing or empty"
done
# Actions are the supply chain here. A tag is mutable; a SHA is not.
unpinned=$(grep -hoE 'uses: [^ ]+' "$root"/.github/workflows/*.yml | grep -vE '@[0-9a-f]{40}' || true)
if [ -z "$unpinned" ]; then ok "every action is pinned by SHA"; else
    bad "an action is pinned by tag, which is mutable:"; printf '%s\n' "$unpinned" | sed 's/^/        /'; fi
# Every SHA pin needs a comment naming what it claims to be. Whether the claim
# is TRUE needs the network, so scripts/verify-action-pins.sh does that in CI.
missing=0
while read -r line; do
    printf '%s' "$line" | grep -qE '# *\S' || { bad "a SHA pin carries no version comment: $line"; missing=1; }
done < <(grep -hE 'uses: [^ ]+@[0-9a-f]{40}' "$root"/.github/workflows/*.yml)
[ "$missing" = 0 ] && ok "every SHA pin says which version it claims to be"
[ -x "$root/scripts/verify-action-pins.sh" ] \
    && ok "a script exists that checks those claims against the API" \
    || bad "nothing verifies that a pin is the tag it claims"
# CI must run the gates rather than merely exist.
for gate in "tests/run-tests.sh" "evals/run-evals.sh" "scripts/check_claims.sh" "shellcheck"; do
    grep -q "$gate" "$root/.github/workflows/ci.yml" \
        && ok "CI runs $gate" || bad "CI does not run $gate"
done
# The workflow needs no write access and no secrets.
grep -q 'contents: read' "$root/.github/workflows/ci.yml" \
    && ok "CI asks for read-only permissions" || bad "CI does not restrict its permissions"
grep -q 'secrets\.' "$root/.github/workflows/ci.yml" \
    && bad "CI reads a secret; a fork's pull request must not be able to" \
    || ok "CI reads no secrets, so a fork's PR is safe to run"

echo "== the merge gate verifies more than one language =="
# It assumed Rust in four places: the image, the command, the mutation glob and
# the way it counts what ran. A pull request touching only shell could not earn
# a receipt and therefore could never merge, which took a live contributor PR to
# notice because refusing to merge is the safe outcome. Issue #11.
vs="$root/profiles/sysknife/verify.d"
[ -d "$vs" ] && ok "the profile declares verification suites" || bad "no verify.d/ for sysknife"
for suite in rust shell; do
    [ -f "$vs/$suite.sh" ] && ok "suite '$suite' exists" || bad "suite '$suite' is missing"
done
# Every suite must answer all four questions. A suite that cannot say how to
# count what ran is a suite that can write a receipt for a vacuous pass.
for suite in "$vs"/*.sh; do
    n="$(basename "$suite" .sh)"
    missing=""
    for fn in suite_covers suite_image suite_mutate_glob suite_command suite_ran; do
        grep -q "^$fn()" "$suite" || missing="$missing $fn"
    done
    [ -z "$missing" ] && ok "suite '$n' answers every question" \
        || bad "suite '$n' is missing:$missing"
done
# Path inference: each suite must claim its own and disclaim the others.
( . "$vs/rust.sh";  suite_covers "crates/x/src/lib.rs" ) && ok "rust claims a .rs path" || bad "rust does not claim .rs"
( . "$vs/rust.sh";  suite_covers "scripts/x.sh" )        && bad "rust claims a .sh path" || ok "rust disclaims .sh"
( . "$vs/shell.sh"; suite_covers "scripts/x.sh" )        && ok "shell claims a .sh path" || bad "shell does not claim .sh"
( . "$vs/shell.sh"; suite_covers "crates/x/src/lib.rs" ) && bad "shell claims a .rs path" || ok "shell disclaims .rs"
# A path no suite covers must be refused rather than silently run under Rust.
grep -q 'no suite in .* covers every changed path' "$root/bin/maintainer-merge" \
    && ok "an uncovered path is refused, not guessed at" \
    || bad "verify would fall back to a suite that does not run the changed code"
# The receipt has to say which suite proved it.
grep -q '"suite": suite' "$root/bin/maintainer-merge" \
    && ok "the receipt records which suite produced it" \
    || bad "a receipt does not say what verified it"

echo "== the shell suite really runs, fails on a mutation, and writes a receipt =="
# End to end against a repository built here, because forcing this through a
# real pull request proved only that a badly chosen mutation is refused.
# podman or docker, whichever this machine has. Requiring podman made CI red for
# a reason unrelated to the change: the runners have docker.
rt=""
command -v podman >/dev/null 2>&1 && rt=podman
[ -z "$rt" ] && command -v docker >/dev/null 2>&1 && rt=docker
if [ -n "$rt" ] && ( "$rt" image inspect docker.io/library/bash:5 >/dev/null 2>&1 \
                     || "$rt" pull -q docker.io/library/bash:5 >/dev/null 2>&1 ); then
    vr="$stub_dir/verifyrepo"; rm -rf "$vr"; mkdir -p "$vr"
    git -C "$vr" init -q -b main; git -C "$vr" config user.email t@t; git -C "$vr" config user.name t
    printf '#!/usr/bin/env bash\nGUARD=on\nif [ "$GUARD" = on ]; then echo "guard held"; exit 0; fi\necho "guard gone"; exit 1\n' \
        > "$vr/check.sh"
    git -C "$vr" add -A; git -C "$vr" commit -qm base
    verify_head="$(git -C "$vr" rev-parse HEAD)"
    git -C "$vr" update-ref "refs/pull/42/head" "$verify_head"
    git -C "$vr" remote add origin "$vr"
    make_stub gh "case \"\$*\" in
      *'auth switch'*) exit 0;;
      *'api user'*) echo testuser;;
      *files*) echo check.sh;;
    esac"
    out=$(PATH="$stub_dir:$PATH" MAINTAINER_STATE="$stub_dir/vstate" MAINTAINER_ACCOUNT=testuser \
          MAINTAINER_SLUG=o/r MAINTAINER_REPO="$vr" PROFILE_DIR="$root/profiles/sysknife" \
          bash "$mg" verify 42 "$verify_head" check.sh 's/GUARD=on/GUARD=off/' shell 2>&1)
    if printf '%s' "$out" | grep -q 'receipt recorded\|observed'; then
        ok "the shell suite produced an observed receipt"
    else
        bad "shell verify failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
    fi
    # And the same run must refuse when the mutation changes nothing.
    out=$(PATH="$stub_dir:$PATH" MAINTAINER_STATE="$stub_dir/vstate2" MAINTAINER_ACCOUNT=testuser \
          MAINTAINER_SLUG=o/r MAINTAINER_REPO="$vr" PROFILE_DIR="$root/profiles/sysknife" \
          bash "$mg" verify 42 "$verify_head" check.sh 's/NOTHING/MATCHES/' shell 2>&1)
    printf '%s' "$out" | grep -q 'THE GUARD DOES NOT BITE' \
        && ok "a mutation that changes nothing is refused" \
        || bad "a no-op mutation produced a receipt"
else
    bad "no container runtime (podman or docker); the shell suite was never executed"
fi
grep -q 'container_runtime()' "$mg" && ok "the gate accepts podman or docker" \
    || bad "the gate requires one specific container runtime"
grep -q 'suite_requires' "$root/profiles/sysknife/verify.d/rust.sh" \
    && ok "a suite that needs a specific runtime says so" \
    || bad "the rust suite does not declare its podman requirement"
# A fragment with no shebang leaves shellcheck unable to pick a dialect, which
# made the lint gate red rather than telling anyone what was wrong with the code.
for f in "$root"/profiles/*/verify.d/*.sh; do
    head -1 "$f" | grep -q 'shellcheck shell=' \
        && ok "$(basename "$(dirname "$(dirname "$f")")")/$(basename "$f") declares its shell" \
        || bad "$f has no shebang and no shellcheck shell directive"
done

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
