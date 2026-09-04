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
pass=0; fail=0; skip=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail+1)); }
# A skip is not a pass. It is counted separately, printed in the summary, and CI
# requires the count to be zero, so a case that stops running because a tool went
# missing shows up as a gap rather than as silence. The only user today is the
# container verification, which needs podman or docker and cannot be faked.
noenv(){ printf '  SKIP  %s\n' "$1"; skip=$((skip+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# A fake PATH: gh, claude, codex and notify-send never reach the real ones.
stub_dir="$(mktemp -d)"
# And a scratch state directory, so a test run cannot append to the real audit
# trail. It did: 22 empty logs from --show-prompt calls landed in the live one.
export MAINTAINER_STATE_DIR="$stub_dir/state-root"
mkdir -p "$MAINTAINER_STATE_DIR/state"
# And a scratch signing key. Without this the suite signs with the key
# install.sh minted on the developer's laptop, so it passed here and failed in
# CI, where no key exists at all. The forgery cases below override it again with
# a key of their own.
export MAINTAINER_RECEIPT_KEY="$stub_dir/receipt.key"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$MAINTAINER_RECEIPT_KEY"
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
# These cases are about the other conditions, so they need a profile that has
# declared its production paths. A merge with none declared is refused, which is
# asserted on its own just below.
export PROD_GLOBS="crates/*/src/*"
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
# The real parse runs in CI, in a job whose container IS powershell, so it
# cannot be skipped. This used to attempt it here when the image happened to be
# local and report a PASS when it did not, which made the case count differ
# between machines and reported a check that had not run as one that had. A
# suite that says "no network" should not contain a case that needs a 350 MB
# pull. What is checked here is that the job which cannot be skipped still
# exists and is still pinned to a PowerShell image.
psjob="$root/.github/workflows/ci.yml"
grep -q 'container: mcr.microsoft.com/powershell' "$psjob" \
    && ok "PowerShell: CI parses the installer inside a real pwsh container" \
    || bad "nothing parses Install-Maintainer.ps1 with a real PowerShell"
grep -q 'Parser\]::ParseFile' "$psjob" \
    && ok "PowerShell: and it parses rather than counting braces" \
    || bad "the Windows job no longer calls the parser"
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
if grep -q "format=%s.*grep -ciE 'security" "$mr"; then bad "release-check still guesses from commit subjects"; else ok "release-check does not guess from commit subjects"; fi
# Driven, not grepped. A real repository with a tag, an origin, and a CHANGELOG
# this test controls.
rcrepo="$stub_dir/rcrepo"; rcorigin="$stub_dir/rcorigin"
git init -q --bare "$rcorigin"
git init -q -b main "$rcrepo"
git -C "$rcrepo" config user.email t@t; git -C "$rcrepo" config user.name t
mkdir -p "$rcrepo/bin"
printf 'v1\n' > "$rcrepo/bin/tool"; printf '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n' > "$rcrepo/CHANGELOG.md"
git -C "$rcrepo" add -A >/dev/null; git -C "$rcrepo" commit -qm base
git -C "$rcrepo" tag v0.1.0
printf 'v2\n' > "$rcrepo/bin/tool"
git -C "$rcrepo" commit -qam 'change production code'
git -C "$rcrepo" remote add origin "$rcorigin"; git -C "$rcrepo" push -q --tags origin main
rc_run() { PATH="$stub_dir:$PATH" MAINTAINER_SLUG=o/r MAINTAINER_REPO="$rcrepo" \
    MAINTAINER_STATE="$stub_dir/rcstate" MAINTAINER_ACCOUNT=t PROD_GLOBS="bin/*" \
    bash "$mr" release-check 2>&1; }
out="$(rc_run)"
printf '%s' "$out" | grep -q 'rests on file counts alone' \
    && ok "an empty Unreleased section is reported as read nothing" \
    || bad "release-check read an empty Unreleased section without saying so"
# The delimiter bug: sed prints BOTH headings, so an empty section came back as
# two lines and -z was false. The warning above never printed once in practice.
printf '%s' "$out" | grep -q 'newest version heading' \
    && ok "and it names the heading the entries were probably promoted into" \
    || bad "the warning does not say where to look instead"
printf '%s' "$out" | grep -q 'digit:   last' \
    && ok "with nothing to read it does not claim a breaking change" \
    || bad "release-check guessed a digit from an unread CHANGELOG"
# Now a populated section that removes a capability.
printf '# Changelog\n\n## [Unreleased]\n\n### Removed\n\n- A run can no longer assert a receipt.\n\n## [0.1.0] - 2026-01-01\n' \
    > "$rcrepo/CHANGELOG.md"
out="$(rc_run)"
printf '%s' "$out" | grep -q 'RELEASE DUE' \
    && ok "a removed capability makes the release due" \
    || bad "a removed capability did not make the release due"
printf '%s' "$out" | grep -q 'digit:   middle' \
    && ok "and it moves the middle digit" \
    || bad "a removed capability was scored as a patch"
printf '%s' "$out" | grep -q 'CHANGELOG read from' \
    && ok "it names which tree the CHANGELOG came from" \
    || bad "the CHANGELOG source is unstated while the counts come from origin/main"


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
# MAINTAINER_PROFILE is named rather than left to a default: `maintainer` used
# to fall back to "sysknife" when nothing said otherwise, and now enumerates the
# deployed profiles and refuses. That refusal has its own test; these cases are
# about how the screen classifies files, so they pin the profile.
screen_run() { PATH="$stub_dir:$PATH" MAINTAINER_PROFILE=sysknife MAINTAINER_REPO="$stub_dir" python3 "$root/bin/maintainer" screen 1 2>&1; }
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
# And it must survive a host with no systemd. `_next_runs` called systemctl by
# name with no guard, so on macOS, Windows or in any container `status` printed
# three lines and died with an uncaught FileNotFoundError. Three of the four
# schedulers this project documents are not systemd. Found by running this suite
# inside python:3.12, where it is not the test that fails but the tool.
nosysd="$stub_dir/nosystemd"; mkdir -p "$nosysd"
for t in git bash python3 grep sed; do
    src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$nosysd/$t"
done
out=$(PATH="$nosysd" HOME="$ok2" MAINTAINER_PROFILE=plain \
      python3 "$root/bin/maintainer" status 2>&1); rc=$?
[ "$rc" = 0 ] && ok "status runs on a host with no systemctl" \
    || bad "status died without a scheduler (rc=$rc)"
printf '%s' "$out" | grep -q 'Traceback' \
    && bad "status printed a Python traceback at the user" \
    || ok "and it does so without a traceback"
printf '%s' "$out" | grep -q 'task .*next' \
    && ok "and still prints the task table, with no next-run column to fill" \
    || bad "status stopped before the task table"

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
# Comments stripped first. This grep ran over the whole file, so writing the
# words `secrets.GITHUB_TOKEN` in a comment that EXPLAINS the policy failed the
# check that enforces it. GITHUB_TOKEN itself is allowed: it is the automatic
# token, scoped by `permissions:` above, and GitHub hands a fork's pull request
# a read-only copy. Any other secret is a repository secret, which a fork's
# `pull_request` run must never see.
othersecret=$(sed 's/#.*//' "$root/.github/workflows/ci.yml" \
    | grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' | grep -v '^secrets\.GITHUB_TOKEN$' || true)
if [ -z "$othersecret" ]; then ok "CI reads no repository secret, so a fork's PR is safe to run"
else bad "CI reads a secret a fork's pull request must not be able to: $othersecret"; fi

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
    # One skip per case the if-branch would have run, so the suite reports the
    # same number of cases on every machine. Emitting a single line here made
    # the total differ by one between this laptop and a container, and
    # scripts/check_claims.sh compares that total against the README.
    noenv "the shell suite produced an observed receipt (needs podman or docker)"
    noenv "a mutation that changes nothing is refused (needs podman or docker)"
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

echo "== the thinking budget reaches the process, per task =="
# Reasoning effort is not a CLI flag: Claude Code reads MAX_THINKING_TOKENS from
# the environment. A setting nobody confirmed reached the process is the same
# shape as the MAINTAINER_FORCE leak, so this measures rather than greps.
tb="$stub_dir/thinkstub"; mkdir -p "$tb"
printf '#!/usr/bin/env bash\nenv | grep -E "^MAX_THINKING_TOKENS=" >&2\nexit 0\n' > "$tb/claude"
chmod +x "$tb/claude"
tlog="$stub_dir/think.log"
think_for() {  # $1 = task -> the budget the backend exported
    : > "$tlog"
    ( export PATH="$tb:$PATH" MAINTAINER_TASK="$1" PROFILE_DIR="$root/profiles/sysknife"
      # shellcheck disable=SC1091
      . "$root/profiles/sysknife/profile.env"
      # shellcheck disable=SC1091
      . "$root/lib/backends/claude.sh"
      backend_run /dev/null opus "$tlog" /tmp >/dev/null 2>&1 )
    sed -n 's/^MAX_THINKING_TOKENS=//p' "$tlog" | head -1
}
r_think="$(think_for review)"; c_think="$(think_for ci)"
[ -n "$r_think" ] && ok "review exports a thinking budget ($r_think)" \
    || bad "no MAX_THINKING_TOKENS reached the process for review"
[ -n "$c_think" ] && [ "$c_think" != "$r_think" ] \
    && ok "ci gets its own, smaller budget ($c_think)" \
    || bad "every task got the same budget; the per-task setting does nothing"
grep -q 'MAX_THINKING_TOKENS' "$root/lib/backends/claude.sh" \
    && ok "the backend names the mechanism rather than implying a flag" \
    || bad "the thinking budget is not wired into the claude backend"

echo "== the MCP server speaks the protocol, and exposes no way round the gate =="
mcp="$root/bin/maintainer-mcp"
[ -x "$mcp" ] && ok "maintainer-mcp is present and executable" || bad "no MCP server"
session() { printf '%s\n' "$@" | python3 "$mcp" 2>/dev/null; }
out=$(session '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
              '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
              '{"jsonrpc":"2.0","id":3,"method":"resources/list"}')
printf '%s' "$out" | grep -q '"protocolVersion"' && ok "initialize answers with a protocol version" \
    || bad "initialize did not answer"
printf '%s' "$out" | grep -q '"tools"' && ok "tools/list answers" || bad "tools/list did not answer"
printf '%s' "$out" | grep -q '"resources"' && ok "resources/list answers" || bad "resources/list did not answer"

# The refusals must survive the change of interface. An MCP client is driven by
# a model, so anything exposed here is exposed to a model.
tools=$(session '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 -c "
import json,sys
for l in sys.stdin:
    m=json.loads(l)
    if 'result' in m and 'tools' in m['result']:
        print(' '.join(t['name'] for t in m['result']['tools']))")
# Named exactly, not by substring: the first version of this check flagged
# maintainer_release_check, which only reports whether a release is owed and
# cannot cut one. A crude needle produces a finding about the needle.
for forbidden in maintainer_receipt maintainer_release maintainer_publish \
                 maintainer_push maintainer_tag maintainer_exec maintainer_shell; do
    printf ' %s ' "$tools" | grep -q " $forbidden " \
        && bad "MCP exposes $forbidden" \
        || ok "MCP exposes no $forbidden"
done
# And the tools it does expose must not be able to publish. release_check reads
# the CHANGELOG and says which digit moves; it never tags.
grep -q '"release-check"' "$mcp" && ok "release_check only asks maintainer-repo, which never tags" \
    || bad "the release tool does something other than release-check"
printf ' %s ' "$tools" | grep -q ' maintainer_verify ' \
    && ok "verify is exposed (it is the only way to earn a receipt)" \
    || bad "verify is missing, so a receipt can never be earned over MCP"
# A model supplies these arguments. They are validated, not interpolated.
out=$(session '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"maintainer_merge","arguments":{"pr":"7; rm -rf /"}}}')
printf '%s' "$out" | grep -q 'positive integer' && ok "a non-integer pull request number is refused" \
    || bad "MCP accepted a non-integer pr"
out=$(session '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"maintainer_status","arguments":{"profile":"../../etc"}}}')
printf '%s' "$out" | grep -q 'plain name' && ok "a profile name that is a path is refused" \
    || bad "MCP accepted a path as a profile name"
out=$(session '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope","arguments":{}}}')
printf '%s' "$out" | grep -q 'no tool named' && ok "an unknown tool is refused" || bad "unknown tool not refused"
# prune over MCP is always a dry run: deleting is a decision.
grep -q '"prune", "--dry-run"' "$mcp" && ok "prune over MCP is always a dry run" \
    || bad "MCP could delete branches"
grep -q 'maintainer-merge", "merge"' "$mcp" \
    && ok "merge shells out to the gate rather than reimplementing it" \
    || bad "MCP does not route merges through maintainer-merge"

echo "== the receipt dies on the paths THIS repository calls production =="
# The globs were sysknife's directory names, so on any other repository they
# matched nothing: a pull request could earn a receipt at one head, push a
# rewritten bin/ at the next, and the gate would say "no production diff,
# receipt still applies". A merge against a receipt describing a tree that is
# gone is the exact failure the receipt exists to prevent.
for pe in "$root"/profiles/*/profile.env; do
    pn="$(basename "$(dirname "$pe")")"
    grep -q '^PROD_GLOBS=' "$pe" && ok "$pn declares which paths are production" \
        || bad "$pn declares no PROD_GLOBS, so a receipt can survive a rewrite"
done
grep -q 'PROD_GLOBS:-' "$root/bin/maintainer-merge" \
    && ok "the gate reads the globs from the profile" \
    || bad "the gate still carries a hardcoded production path list"
# Executed, not grepped: a merge with no production paths declared must refuse.
out=$(env -u PROD_GLOBS PATH="$stub_dir:$PATH" MAINTAINER_STATE="$stub_dir/state" \
      MAINTAINER_ACCOUNT=testuser MAINTAINER_SLUG=o/r MAINTAINER_REPO="$stub_dir/repo" \
      bash "$mg" merge 1 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'declares no PROD_GLOBS'; then
    ok "a profile with no globs is refused a merge, not given a default"
else
    bad "the gate merged, or failed for another reason, with no production paths declared (rc=$rc)"
fi

# Executed, against a real repository, on a path THIS profile calls production.
pg="$stub_dir/prodglobs"; rm -rf "$pg"; mkdir -p "$pg/bin" "$pg/docs"
git -C "$pg" init -q -b main; git -C "$pg" config user.email t@t; git -C "$pg" config user.name t
echo "code" > "$pg/bin/tool"; echo "words" > "$pg/docs/x.md"
git -C "$pg" add -A; git -C "$pg" commit -qm base
pg_verified="$(git -C "$pg" rev-parse HEAD)"
echo "changed" > "$pg/docs/x.md"; git -C "$pg" add -A; git -C "$pg" commit -qm docs
pg_docs="$(git -C "$pg" rev-parse HEAD)"
echo "rewritten" > "$pg/bin/tool"; git -C "$pg" add -A; git -C "$pg" commit -qm prod
pg_prod="$(git -C "$pg" rev-parse HEAD)"
git -C "$pg" remote add origin "$pg"
git -C "$pg" update-ref refs/pull/21/head "$pg_docs"
git -C "$pg" update-ref refs/pull/22/head "$pg_prod"
pg_case() {  # $1 pr, $2 head, $3 expected substring, $4 label
    PATH="$stub_dir:$PATH" MAINTAINER_STATE="$stub_dir/pgstate" MAINTAINER_ACCOUNT=testuser \
        MAINTAINER_SLUG=o/r MAINTAINER_REPO="$pg" PROD_GLOBS="bin/*" \
        bash "$mg" receipt "$1" "$pg_verified" "proved" >/dev/null 2>&1
    make_stub gh "case \"\$*\" in
      *'auth switch'*) exit 0;;
      *'api user'*) echo testuser;;
      *reviewDecision*) echo APPROVED;;
      *headRefOid*) echo $2;;
      *mergeStateStatus*) echo CLEAN;;
      *'pr checks'*) echo '[{\"name\":\"x\",\"bucket\":\"pass\"}]';;
      *'pr merge'*) echo MERGED_STUB;;
    esac"
    out=$(PATH="$stub_dir:$PATH" MAINTAINER_STATE="$stub_dir/pgstate" MAINTAINER_ACCOUNT=testuser \
          MAINTAINER_SLUG=o/r MAINTAINER_REPO="$pg" PROD_GLOBS="bin/*" MAINTAINER_POST=off \
          bash "$mg" merge "$1" 2>&1)
    printf '%s' "$out" | grep -q "$3" && ok "$4" \
        || bad "$4 (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90))"
}
pg_case 21 "$pg_docs" "receipt still applies" "a docs-only move keeps the receipt"
pg_case 22 "$pg_prod" "production code changed" "a rewrite of bin/ kills the receipt"

echo "== a receipt cannot be written by anything but the gate =="
# It used to be an unsigned JSON file whose only protection was a deny rule on
# one CLI verb, while the deny wall emits only Bash() and Read() rules. An agent
# with an ordinary write tool could create the file by hand, with
# "kind": "observed", and merge without ever running a mutation. That is
# SECURITY.md's own first named threat.
rk="$stub_dir/rkey"; printf 'deadbeefcafe\n' > "$rk"
forge="$stub_dir/forged"; mkdir -p "$forge/receipts"
make_stub gh 'case "$*" in *"api user"*) echo testuser;; esac; exit 0'
printf '{"pr":1,"head":"abcdef1234567890","kind":"observed","proof":"written by hand"}\n' \
    > "$forge/receipts/1.json"
out=$(PATH="$stub_dir:$PATH" MAINTAINER_RECEIPT_KEY="$rk" MAINTAINER_STATE="$forge" \
      MAINTAINER_ACCOUNT=testuser MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp PROD_GLOBS="bin/*" \
      bash "$mg" merge 1 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'carries no signature'; then
    ok "a hand-written receipt is refused"
else
    bad "a hand-written receipt merged or failed for another reason (rc=$rc)"
fi
# And one with a signature that does not match the payload.
printf '{"pr":2,"head":"abcdef1234567890","kind":"observed","proof":"edited","signature":"00"}\n' \
    > "$forge/receipts/2.json"
out=$(PATH="$stub_dir:$PATH" MAINTAINER_RECEIPT_KEY="$rk" MAINTAINER_STATE="$forge" \
      MAINTAINER_ACCOUNT=testuser MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp PROD_GLOBS="bin/*" \
      bash "$mg" merge 2 2>&1)
printf '%s' "$out" | grep -q 'does not match its signature' \
    && ok "a receipt edited after signing is refused" \
    || bad "an edited receipt was accepted"

echo "== an unattended run cannot assert; it can only observe =="
# Signing alone does not separate an agent from a human: both run as this user,
# so both can reach the key. What separates them is that `verify` records
# something re-checkable and `receipt` records a sentence. So a run may not use
# `receipt`, and may not merge on what `receipt` writes. Three layers, and only
# the third is un-evadable by an agent that edits its own environment.
out=$(PATH="$stub_dir:$PATH" MAINTAINER_IN_RUN="sysknife/review" MAINTAINER_STATE="$forge" \
      MAINTAINER_ACCOUNT=testuser MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp \
      bash "$mg" receipt 3 abcdef1234567890 'I promise' 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'may not assert a receipt'; then
    ok "a run is refused the receipt command"
else
    bad "a run wrote an asserted receipt (rc=$rc)"
fi
[ -f "$forge/receipts/3.json" ] && bad "the refusal still left a receipt on disk" \
    || ok "the refusal wrote nothing"
# Layer 2: the deny wall spells the command, in every profile.
for pdj in "$root"/profiles/*/deny.json; do
    pn="$(basename "$(dirname "$pdj")")"
    grep -q 'maintainer-merge receipt' "$pdj" \
        && ok "$pn denies the receipt command to the agent" \
        || bad "$pn lets an agent run maintainer-merge receipt"
done
# Layer 3, the one that holds when the other two are evaded: a properly signed
# asserted receipt, written outside a run, is still refused inside one.
PATH="$stub_dir:$PATH" MAINTAINER_STATE="$forge" MAINTAINER_ACCOUNT=testuser \
    MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp \
    bash "$mg" receipt 4 abcdef1234567890 'proved by hand' >/dev/null 2>&1
if [ -f "$forge/receipts/4.json" ]; then
    ok "outside a run the receipt command still works"
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('signature') and d['kind']=='asserted' else 1)" \
        "$forge/receipts/4.json" && ok "and what it writes is signed and marked asserted" \
        || bad "the asserted receipt is unsigned or mislabelled"
    out=$(PATH="$stub_dir:$PATH" MAINTAINER_IN_RUN="sysknife/review" MAINTAINER_STATE="$forge" \
          MAINTAINER_ACCOUNT=testuser MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp PROD_GLOBS="bin/*" \
          bash "$mg" merge 4 2>&1)
    printf '%s' "$out" | grep -q "is 'asserted', not 'observed'" \
        && ok "a run may not merge on an asserted receipt" \
        || bad "a run merged on a claim nothing checked"
else
    bad "the receipt command wrote nothing outside a run"
fi
# A proof string is a human sentence, so it contains quotes. The heredoc that
# used to write this file interpolated it raw and produced JSON merge could not
# parse, and the refusal then blamed the receipt rather than the quoting.
PATH="$stub_dir:$PATH" MAINTAINER_STATE="$forge" MAINTAINER_ACCOUNT=testuser \
    MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp \
    bash "$mg" receipt 5 abcdef1234567890 'reverting `|| true` leaves it "green": 0 bytes' >/dev/null 2>&1
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$forge/receipts/5.json" 2>/dev/null \
    && ok "a proof containing quotes and backticks still writes valid JSON" \
    || bad "a quoted proof string produced an unparseable receipt"

# The key must be denied to readers, in every profile.
for pdj in "$root"/profiles/*/deny.json; do
    pn="$(basename "$(dirname "$pdj")")"
    grep -q 'receipt.key' "$pdj" && ok "$pn denies the receipt key to readers" \
        || bad "$pn leaves the receipt-signing key readable"
done

echo "== a symlink may not leave the tree the gate edits =="
# The mutation step runs on the HOST, outside the container. A tracked symlink
# harness.sh -> ~/.ssh/id_ed25519 survives git archive, and `sed -i` follows it:
# the key's plaintext lands in the extracted tree, which is then bind-mounted
# into the container where the pull request's own test can print it, and 200
# characters of it land in the receipt. Every container flag is irrelevant,
# because the read happens before the container exists.
# Driven through the real function rather than grepped out of the source. The
# first two cases here were `grep -q 'ships symlink' "$mg"`, which passes for any
# file that contains the words and says nothing about what the gate does.
# One helper for every call into maintainer-merge's own functions. $mg is
# resolved at runtime, which shellcheck cannot follow, so the directive lives
# here once instead of above each of the five call sites.
# shellcheck disable=SC1090
mgfn() { local fn="$1"; shift; ( . "$mg" >/dev/null 2>&1; "$fn" "$@" ) 2>/dev/null; }
esc() { mgfn tree_escapes "$1"; }
tr1="$stub_dir/tree1"; mkdir -p "$tr1/docs/images" "$tr1/assets"
printf 'png\n' > "$tr1/assets/social.png"
ln -sf ../../assets/social.png "$tr1/docs/images/social.png"
[ -z "$(esc "$tr1")" ] && ok "an in-tree relative symlink is allowed" \
    || bad "a repository's own docs symlink is refused: $(esc "$tr1")"
outside="$stub_dir/outside-key"; printf 'CANARY\n' > "$outside"
ln -sf "$outside" "$tr1/harness.sh"
printf '%s' "$(esc "$tr1")" | grep -q 'harness.sh' \
    && ok "a symlink to an absolute path outside the tree is reported" \
    || bad "an escaping symlink was not reported"
rm -f "$tr1/harness.sh"
ln -sf ../../../../etc/passwd "$tr1/docs/images/trav.sh"
printf '%s' "$(esc "$tr1")" | grep -q 'trav.sh' \
    && ok "a ../ traversal out of the tree is reported" \
    || bad "a traversing symlink was not reported"
rm -f "$tr1/docs/images/trav.sh"
[ -z "$(esc "$tr1")" ] && ok "and the tree reads clean once it is removed" \
    || bad "the scan reports an escape that is no longer there"
grep -q 'find . -type f -name' "$mg" && ok "the mutation touches regular files only" \
    || bad "the mutation step would still follow a symlink"
# Demonstrated: sed -i through a symlink materialises the target.
sl="$stub_dir/symlinkdemo"; mkdir -p "$sl"; secret="$stub_dir/fake-key"
printf 'CANARY-KEY-MATERIAL\n' > "$secret"; ln -sf "$secret" "$sl/evil.sh"
( cd "$sl" && find . -type f -name '*.sh' -print0 | xargs -0 -r sed -i 's/x/y/' )
grep -q CANARY "$sl/evil.sh" && [ -L "$sl/evil.sh" ] \
    && ok "with -type f the symlink is left alone" \
    || bad "the symlink was dereferenced even with -type f"

echo "== the shellcheck sweep runs locally, or says it did not =="
# It lived inline in ci.yml, so the pre-commit hook could not run it and a push
# was the first thing to report SC1090 on four lines that had passed every gate
# this machine knows about. A local-first project whose linter is CI-only is not
# local-first.
sw="$root/scripts/shellcheck-sweep.sh"
[ -x "$sw" ] && ok "the sweep is a script, not a workflow step" \
    || bad "the shellcheck sweep is not runnable outside CI"
grep -q 'shellcheck-sweep.sh' "$root/.githooks/pre-commit" \
    && ok "the pre-commit hook runs the same sweep" \
    || bad "the local gate still skips shellcheck"
grep -q 'shellcheck-sweep.sh' "$root/.github/workflows/ci.yml" \
    && ok "CI runs the same sweep, not a second copy of it" \
    || bad "CI has its own copy of the sweep, which will drift"
# And it must fail when the linter is absent. A gate that reports success over
# code nothing inspected is the shape docs/lessons.md keeps recording.
# A PATH with everything the sweep needs EXCEPT shellcheck. Stripping PATH
# entirely proves nothing: the shell then cannot find `bash` either.
noshell="$stub_dir/nolinter"; mkdir -p "$noshell"
for t in git head tr sort bash readlink dirname grep sed; do
    src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$noshell/$t"
done
out=$(PATH="$noshell" bash "$sw" 2>&1); rc=$?
[ "$rc" = 127 ] && ok "with no shellcheck on PATH the sweep exits 127" \
    || bad "the sweep reported rc=$rc with no linter installed"
printf '%s' "$out" | grep -q 'inspected nothing' \
    && ok "and it says the gate inspected nothing" \
    || bad "the sweep failed silently: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80)"

echo "== the container runtime's own noise is not evidence =="
# Measured on sysknife#365: podman writes
#   time="..." level=warning msg="Error validating CNI config file ..."
# to the same stderr the container uses, on every run. It became the receipt's
# `observed_failure`, and it is enough bytes on its own to satisfy the shell
# suite's proof that the test ran at all.
noise="$stub_dir/noise.log"
{ printf 'time="2026-09-04T06:43:41-06:00" level=warning msg="Error validating CNI config file"\n'
  printf 'time="2026-09-04T06:43:41-06:00" level=error msg="failed to find plugin bridge"\n'
  printf 'FAIL  story-7.sh header claims story 97\n'
  printf 'some later error\n'; } > "$noise"
ffl="$(mgfn first_failure_line "$noise")"
[ "$ffl" = "FAIL  story-7.sh header claims story 97" ] \
    && ok "the runtime's logfmt is skipped and the test's own line is taken" \
    || bad "the receipt would record '$ffl'"
printf 'time="x" level=warning msg="Error validating CNI config"\n' > "$noise"
[ -z "$(mgfn first_failure_line "$noise")" ] \
    && ok "a log that is only runtime noise yields no observed failure" \
    || bad "runtime noise alone was recorded as the observed failure"
# A failure that matches no Rust-shaped keyword still has to leave evidence.
# sysknife's prose claim screen reports a mismatched figure in plain English, and
# the receipt for #366 recorded an empty observed_failure the first time.
{ printf 'Published figures match the evidence artifacts.\n'
  printf 'README.md claims 9,999 Rust tests; the artifact records 1,837.\n'; } > "$noise"
[ "$(mgfn first_failure_line "$noise")" = \
  "README.md claims 9,999 Rust tests; the artifact records 1,837." ] \
    && ok "a plain-English failure falls back to the last line printed" \
    || bad "a failure with no Rust keyword left the receipt with no evidence"
grep -q '"\$rt" --log-level=error run' "$mg" \
    && ok "the runtime is told to keep its warnings out of the log" \
    || bad "runtime warnings still land in the log the byte count reads"

echo "== every profile declares a budget for every task it runs =="
# The template grew THINKING_<task> after profiles/magent had been generated
# from it, so magent ran without one and the agent maintaining the merge gate
# thought less about it than the agent maintaining the target repository did.
# Nothing said so: a missing budget is not an error, it is a default.
for pe in "$root"/profiles/*/profile.env; do
    pn="$(basename "$(dirname "$pe")")"
    tasks="$(sed -n 's/^TASKS="\(.*\)"/\1/p' "$pe")"
    [ -n "$tasks" ] || { bad "$pn declares no TASKS"; continue; }
    missing=""
    for tk in $tasks; do
        grep -q "^THINKING_$tk=" "$pe" || missing="$missing $tk"
        grep -q "^MODEL_$tk=" "$pe" || missing="$missing $tk(model)"
    done
    [ -z "$missing" ] && ok "$pn budgets every task it runs" \
        || bad "$pn runs$missing with no declared thinking budget or model"
done

echo "== what a run cost is recorded, not estimated =="
# The first version of this logged `in=<input_tokens>` and nothing else, so a
# full review of a Rust workspace was recorded as "in=48". Almost every input
# token in an agent run is a cache read or a cache write, and both are separate
# fields, so 48 was true and useless. It read as a measurement, which is worse
# than printing nothing.
#
# Not tiktoken. It is OpenAI's tokenizer, it undercounts Claude by 15-20% on
# prose and by more on code, and Anthropic publishes none. Counting is the wrong
# move anyway: the exact figures are already in the stream Claude Code emits.
tw="$stub_dir/usagerun"; mkdir -p "$tw"
cat > "$tw/ev.jsonl" <<'EVENTS'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":42,"duration_ms":1085000,"total_cost_usd":4.486383,"result":"done","usage":{"input_tokens":98,"output_tokens":38343,"cache_creation_input_tokens":412000,"cache_read_input_tokens":9800000},"modelUsage":{"opus":{"inputTokens":98,"outputTokens":38343,"cacheCreationInputTokens":412000,"cacheReadInputTokens":9800000,"costUSD":4.30},"haiku":{"inputTokens":10,"outputTokens":900,"cacheCreationInputTokens":0,"cacheReadInputTokens":52000,"costUSD":0.186383}}}
EVENTS
python3 "$root/scripts/transcript.py" "$tw/r.log" "$tw/r.commands" < "$tw/ev.jsonl"
[ -f "$tw/r.usage.json" ] && ok "the transcript writes a usage record beside the log" \
    || bad "nothing records what the run spent"
python3 - "$tw/r.usage.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); t = d["totals"]
fail = []
if t["cache_read_input_tokens"] != 9852000:
    fail.append(f"cache reads not summed across models: {t['cache_read_input_tokens']}")
if t["cache_creation_input_tokens"] != 412000:
    fail.append("cache writes missing")
if t["input_tokens"] == 98:
    fail.append("only the main loop counted; subagent models are excluded from usage")
if t["billable_input_tokens"] <= t["input_tokens"]:
    fail.append("billable input ignores the cache fields, which is the in=48 bug")
if d["subtype"] != "success" or d["num_turns"] != 42:
    fail.append("the result subtype or turn count was dropped")
sys.exit("; ".join(fail) if fail else 0)
PYEOF
[ $? = 0 ] && ok "cache reads, cache writes and every model are in the totals" \
    || bad "the usage record repeats the in=48 mistake"
# An error result carries usage too. A failed run that spent four dollars must
# not be recorded as having spent nothing.
printf '%s\n' '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":2.5,"usage":{"input_tokens":5,"output_tokens":10,"cache_read_input_tokens":900}}' \
    > "$tw/err.jsonl"
python3 "$root/scripts/transcript.py" "$tw/e.log" "$tw/e.commands" < "$tw/err.jsonl"
python3 -c "
import json,sys
d=json.load(open('$tw/e.usage.json'))
sys.exit(0 if d['is_error'] and d['cost_usd_estimate']==2.5 and d['subtype']=='error_max_budget_usd' else 1)" \
    && ok "a failed run still records what it spent" \
    || bad "a run that errored was recorded as having spent nothing"

echo "== the digest reads THIS run's files, and says so when they are absent =="
# Same shape as lessons.md 30, for the third time: the first version took the
# newest *.commands in the directory and printed another run's command count
# under this one.
dg="$stub_dir/dgstate"; mkdir -p "$dg/runs" "$dg/logs" "$dg/state"
printf '# report\nline two\n' > "$dg/runs/2026-01-01T00-00-review.md"
printf '$ a\n$ b\n$ c\n' > "$dg/logs/2026-01-01T00-00-review.commands"
printf '$ x\n' > "$dg/logs/2026-09-09T09-09-review.commands"
cp "$tw/r.usage.json" "$dg/logs/2026-01-01T00-00-review.usage.json"
dgrun() { MAINTAINER_STATE="$dg" MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp \
    MAINTAINER_ACCOUNT=t MAINTAINER_PROFILE=dg python3 "$root/bin/maintainer" digest "$@" 2>&1; }
out="$(dgrun 2026-01-01T00-00-review --compact)"
printf '%s' "$out" | grep -q '3 commands run' \
    && ok "the digest counts this run's commands" \
    || bad "the digest read the wrong commands file: $(printf '%s' "$out" | tr '\n' ' ')"
printf '%s' "$out" | grep -q '4.49' \
    && ok "and reports the run's cost estimate" || bad "the cost is missing from the digest"
printf '%s' "$out" | grep -qE 'cache read 9.9M' \
    && ok "in units a person reads, not 9852000" || bad "raw token counts reached the digest"
# A run with no usage record must say unknown, never zero.
printf '# r\n' > "$dg/runs/2026-02-02T00-00-review.md"
out="$(dgrun 2026-02-02T00-00-review --compact)"
printf '%s' "$out" | grep -q 'spend unknown' \
    && ok "a run with no usage record reports unknown, not zero" \
    || bad "an unrecorded cost was printed as a number: $(printf '%s' "$out" | tr '\n' ' ')"
printf '%s' "$out" | grep -q 'command record missing' \
    && ok "and says its command record is missing rather than borrowing one" \
    || bad "the digest borrowed another run's command count"

echo "== a notification is written for a person =="
# What used to reach the desktop was the raw shell error, absolute path and all,
# with no next step: "backend claude unusable: missing /home/.../settings.json".
# And nothing was sent at all when a run SUCCEEDED, so the agent only ever spoke
# to its owner to complain.
grep -q 'humanise()' "$root/lib/run.sh" && ok "failures are translated before they are shown" \
    || bad "the raw shell error still goes straight to the desktop"
grep -q 'notify normal' "$root/lib/run.sh" \
    && ok "a successful run notifies too" \
    || bad "the agent only speaks when it fails"
grep -q 'HELPER" digest' "$root/lib/run.sh" \
    && ok "and what it says is the measured digest" \
    || bad "the success notification is not built from the run's own record"
# The last-resort alert must leave a trace on disk. A popup at 03:00 is gone by
# morning, and it was the only record.
grep -q 'alerts.log' "$root/platform/linux/alert.sh" \
    && ok "the systemd OnFailure alert writes to the state directory" \
    || bad "a failure nobody was awake for leaves no trace"
grep -q 'sort -u' "$root/platform/linux/alert.sh" \
    && ok "and writes it once, not once per matching glob" \
    || bad "both state globs match the same directory, so alerts are double-counted"
grep -q 'ExecStart=%h/.local/share/maintainer/alert.sh' "$root/platform/linux/maintainer-alert@.service" \
    && ok "the unit calls a script rather than quoting shell into ExecStart" \
    || bad "systemd refuses the inline version with Unbalanced quoting"
grep -q 'alert.sh' "$root/install.sh" \
    && ok "install.sh deploys it, so the unit's ExecStart resolves" \
    || bad "the alert unit points at a file the installer never copies"

echo "== the trail says what happened, including when nothing did =="
tr1="$stub_dir/trail"; mkdir -p "$tr1/runs" "$tr1/logs" "$tr1/state" "$tr1/drafts"
trrun() { MAINTAINER_STATE="$tr1" MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp \
    MAINTAINER_ACCOUNT=t MAINTAINER_PROFILE=tr MAINTAINER_TASKS="review ci" \
    python3 "$root/bin/maintainer" "$@" 2>&1; }

# 1. A fixture is not a report. runs/2026-09-02T14-39-review.md in this
# project's own trail is "baseline promotion test", indexed like a real run.
printf '# 2026-01-01T00-00-review\n\nbaseline promotion test\n' \
    > "$tr1/runs/2026-01-01T00-00-review.md"
out="$(trrun finish 2026-01-01T00-00-review)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'fixture rather than a report' \
    && ok "a three-line fixture is refused rather than indexed" \
    || bad "a fixture was indexed as a run (rc=$rc)"
grep -q '2026-01-01T00-00-review' "$tr1/index.md" 2>/dev/null \
    && bad "the refused fixture reached the index anyway" \
    || ok "and it did not reach the index"
# A real report still passes.
printf '# 2026-01-02T00-00-review\n\nQueue empty. Checked five PRs.\n\nNothing posted.\n\nNothing merged.\n' \
    > "$tr1/runs/2026-01-02T00-00-review.md"
trrun finish 2026-01-02T00-00-review >/dev/null 2>&1
grep -q '2026-01-02T00-00-review' "$tr1/index.md" 2>/dev/null \
    && ok "a real report is still indexed" || bad "the fixture check refuses real reports"

# 2. A run that died leaves an ABORTED line, not a gap. A gap reads as a run
# that never started; 2026-09-03T07-52-review is the real case, and fifteen
# comments went out under the same account in the hour after it.
trrun abort 2026-01-03T00-00-review "the run wrote no usable report" >/dev/null 2>&1
grep -q 'ABORTED' "$tr1/index.md" 2>/dev/null \
    && ok "a run that produced nothing is recorded as ABORTED" \
    || bad "a dead run leaves the index silent"

# 3. The failure marker, the layer that cannot fail. notify-send guesses a
# display and ends in `|| true`, so on a headless box a nightly failure reaches
# nobody and says nothing about it.
trrun failed review "backend claude unusable" /tmp/x.log >/dev/null 2>&1
[ -f "$tr1/state/failed-review.json" ] && ok "a failure is written to disk" \
    || bad "the only record of a failure is a desktop popup"
trrun status 2>/dev/null | head -8 | grep -q 'FAILED' \
    && ok "and maintainer status prints it without being asked" \
    || bad "a recorded failure is invisible to the front door"
# Driven through `finish`, not through `ok`. The first version of this called
# `maintainer ok review`, which is a different code path, so deleting the
# clear_failure call out of cmd_finish left the test green.
printf '# 2026-01-04T00-00-review\n\nQueue empty.\n\nNothing posted.\n\nNothing merged.\n' \
    > "$tr1/runs/2026-01-04T00-00-review.md"
trrun finish 2026-01-04T00-00-review >/dev/null 2>&1
[ -f "$tr1/state/failed-review.json" ] \
    && bad "a run that finished properly left the previous failure marker standing" \
    || ok "a run that finishes clears its own task's failure marker"
# And only its own. A review succeeding says nothing about the ci sweep.
trrun failed ci "postgres contract went red" >/dev/null 2>&1
printf '# 2026-01-05T00-00-review\n\nQueue empty.\n\nNothing posted.\n\nNothing merged.\n' \
    > "$tr1/runs/2026-01-05T00-00-review.md"
trrun finish 2026-01-05T00-00-review >/dev/null 2>&1
[ -f "$tr1/state/failed-ci.json" ] \
    && ok "and leaves another task's failure alone" \
    || bad "a review clearing the ci failure hides a red sweep"
trrun ok ci >/dev/null 2>&1
grep -q 'HELPER" failed' "$root/lib/run.sh" \
    && ok "run.sh records the marker before it tries any channel" \
    || bad "run.sh still bets everything on notify-send"
grep -v '^[[:space:]]*#' "$root/lib/run.sh" | grep -q 'DISPLAY:-:1' \
    && bad "run.sh still hardcodes DISPLAY=:1" \
    || ok "the display is read from the session rather than assumed"
grep -q 'MAINTAINER_ALERT_CMD' "$root/lib/run.sh" \
    && ok "a profile can name its own escalation channel" \
    || bad "there is no way to reach ntfy, mail or a webhook"

echo "== a report is a claim; the transcript is the record =="
# lessons.md 12: a report read `sysknife-maint screen 348 -> DO NOT EXECUTE` for
# a command that had been renamed out of existence. Nothing compared the two.
au="$stub_dir/audit"; mkdir -p "$au/runs" "$au/logs"
aurun() { MAINTAINER_STATE="$au" MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp \
    MAINTAINER_ACCOUNT=t MAINTAINER_PROFILE=au python3 "$root/bin/maintainer" audit "$@" 2>&1; }
printf '# r\n\n```\n$ gh pr list --state open\n$ cargo nextest run --workspace\n```\n' \
    > "$au/runs/2026-01-01T00-00-review.md"
printf '$ gh pr list --state open\n' > "$au/logs/2026-01-01T00-00-review.commands"
out="$(aurun 2026-01-01T00-00-review)"
printf '%s' "$out" | grep -q '1 of 2 quoted command' \
    && ok "a command the report quotes and the record lacks is named" \
    || bad "the audit did not notice a quoted command that never ran: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80)"
printf '%s' "$out" | grep -q 'cargo nextest run --workspace' \
    && ok "and it prints which one" || bad "the audit says a count and not which command"
# Commands the report RECOMMENDS are not claims. Only `$ ` inside a fence is.
printf '# r\n\nRun `gh pr merge 7` yourself.\n\n```\n$ gh pr list --state open\n```\n' \
    > "$au/runs/2026-01-02T00-00-review.md"
printf '$ gh pr list --state open\n' > "$au/logs/2026-01-02T00-00-review.commands"
aurun 2026-01-02T00-00-review | grep -q 'all 1 quoted command' \
    && ok "a command the report recommends is not counted as one it ran" \
    || bad "the audit treats a recommendation as a claim, which fires on every report"
# No record at all must read differently from a record that matched.
rm -f "$au/logs/2026-01-02T00-00-review.commands"
aurun 2026-01-02T00-00-review | grep -q 'no command record' \
    && ok "a run with no transcript says so rather than passing" \
    || bad "a missing transcript read as a clean audit"

echo "== the state directory does not grow forever =="
gcd="$stub_dir/gc"; mkdir -p "$gcd/logs" "$gcd/drafts/old" "$gcd/runs"
printf 'x\n' > "$gcd/logs/ancient.log"; printf 'x\n' > "$gcd/logs/fresh.log"
printf 'x\n' > "$gcd/drafts/old/d.md"; printf 'keep\n' > "$gcd/runs/report.md"
touch -d '200 days ago' "$gcd/logs/ancient.log" "$gcd/drafts/old"
gcrun() { MAINTAINER_STATE="$gcd" MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp \
    MAINTAINER_ACCOUNT=t MAINTAINER_PROFILE=gc python3 "$root/bin/maintainer" gc "$@" 2>&1; }
gcrun --dry-run | grep -q 'would remove.*ancient.log' \
    && ok "a dry run names what it would remove" || bad "gc --dry-run said nothing"
[ -f "$gcd/logs/ancient.log" ] && ok "and removes nothing" || bad "the dry run deleted a file"
gcrun >/dev/null 2>&1
[ -f "$gcd/logs/ancient.log" ] && bad "gc kept a log past the window" \
    || ok "a log past the window is removed"
[ -f "$gcd/logs/fresh.log" ] && ok "a log inside the window is kept" \
    || bad "gc deleted a recent log"
[ -d "$gcd/drafts/old" ] && bad "gc kept a drafts directory past the window" \
    || ok "a drafts directory past the window is removed"
[ -f "$gcd/runs/report.md" ] \
    && ok "runs/ is never pruned: it records what was published in your name" \
    || bad "gc DELETED A RUN REPORT, which is the record of what was posted"
for pe in "$root"/profiles/*/profile.env; do
    pn="$(basename "$(dirname "$pe")")"
    grep -q '^RETENTION_DAYS=' "$pe" && ok "$pn declares a retention window" \
        || bad "$pn has no RETENTION_DAYS, so gc falls back to a default nobody chose"
done

echo "== a task that fans out declares the model its subagents get =="
# A review fans out across files and dimensions. Running that on the main
# loop's model pays opus prices for independent work sonnet does as well, and
# the thinking budget is spent in the main loop, not in the fan-out.
# Comments stripped first, for the fourth time today. The paragraph explaining
# why _FORCE is NOT used contains the word _FORCE, and a bare grep failed the
# check that enforces the decision. docs/lessons.md 31 is this exact shape.
code() { grep -v '^[[:space:]]*#' "$1"; }
code "$root/lib/backends/claude.sh" | grep -q 'export CLAUDE_CODE_SUBAGENT_MODEL=' \
    && ok "the claude backend exports a subagent model" \
    || bad "SUBAGENT_MODEL_<task> is declared and never reaches the process"
code "$root/lib/backends/claude.sh" | grep -q 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE' \
    && bad "the backend FORCES every subagent onto one model, overriding definitions that chose their own" \
    || ok "it sets a default, so an agent definition's own model still wins"
for pe in "$root"/profiles/*/profile.env; do
    pn="$(basename "$(dirname "$pe")")"
    tasks="$(sed -n 's/^TASKS="\(.*\)"/\1/p' "$pe")"
    # Declared only where it means something. A sweep that spawns nothing must
    # not carry a setting that reads as though it does.
    bogus=""
    while read -r line; do
        tk="${line#SUBAGENT_MODEL_}"; tk="${tk%%=*}"
        case " $tasks " in *" $tk "*) ;; *) bogus="$bogus $tk" ;; esac
    done < <(grep '^SUBAGENT_MODEL_' "$pe" || true)
    [ -z "$bogus" ] && ok "$pn declares a subagent model only for tasks it runs" \
        || bad "$pn sets SUBAGENT_MODEL for$bogus, which is not in its TASKS"
done
# Driven, not grepped: the backend must actually put it in the environment.
sm="$stub_dir/submodel"; mkdir -p "$sm"
cat > "$sm/probe.sh" <<'PROBE'
PROFILE_DIR=/dev/null
MAINTAINER_TASK=review
THINKING_review=31999
SUBAGENT_MODEL_review=sonnet
MAINTAINER_SETTINGS=/dev/null
backend_run() { :; }
PROBE
out=$(bash -c '
    . "'"$sm"'/probe.sh"
    . "'"$root"'/lib/backends/claude.sh"
    # Re-run just the exporting prologue by calling backend_run with a stub claude.
    export PATH="'"$stub_dir"':$PATH"
    backend_run /dev/null opus /dev/null /tmp >/dev/null 2>&1
    echo "MAX_THINKING_TOKENS=$MAX_THINKING_TOKENS"
    echo "CLAUDE_CODE_SUBAGENT_MODEL=$CLAUDE_CODE_SUBAGENT_MODEL"' 2>&1)
printf '%s' "$out" | grep -q 'CLAUDE_CODE_SUBAGENT_MODEL=sonnet' \
    && ok "SUBAGENT_MODEL_review reaches the process as sonnet" \
    || bad "the subagent model never reached the environment: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90)"
printf '%s' "$out" | grep -q 'MAX_THINKING_TOKENS=31999' \
    && ok "and the main loop keeps its own budget" \
    || bad "the thinking budget was lost"

echo "== a subagent finding is a lead, and the doctrine says so =="
# The env var alone would make the agent WORSE: fan-out produces findings that
# arrive already written up, in the agent's own voice, and one taken at face
# value would have published a retraction of a correct result.
pc="$root/lib/preamble-core.md"
grep -q 'lead, not a result' "$pc" \
    && ok "the core preamble carries the subagent rule" \
    || bad "subagents are configured and the doctrine never mentions them"
grep -q 'Never delegate the decision' "$pc" \
    && ok "and says the decision is never delegated" \
    || bad "nothing stops a subagent's conclusion becoming a merge"
# Every profile gets it, because the preamble is shared and run.sh concatenates it.
grep -q 'preamble-core.md' "$root/lib/run.sh" \
    && ok "run.sh assembles that preamble into every prompt" \
    || bad "the doctrine is a file nothing reads"

echo "== the doctor reports on the profile it was asked about =="
# It globbed `maintainer@*` in systemctl, so with MAINTAINER_PROFILE=magent it
# counted sysknife's four timers and printed "4 systemd timer(s) registered, ok"
# while magent had two timer files, both disabled, and had never fired once.
# Same shape as the hardcoded profile default in bin/maintainer.
md="$root/bin/maintainer-doctor"
grep -q "maintainer@\$profile-\*" "$md" \
    && ok "the scheduler check names the profile" \
    || bad "the doctor counts every profile's timers and calls them this one's"
grep -q "list-timers 'maintainer@\*'" "$md" \
    && bad "an unscoped timer glob is still in maintainer-doctor" \
    || ok "no unscoped timer glob remains"
# list-timers shows loaded units only, so a disabled timer is absent rather than
# listed as off. Counting the unit FILES is what separates "none installed" from
# "installed and never enabled", and those need different fixes.
grep -q 'list-unit-files' "$md" \
    && ok "it separates a missing timer from a disabled one" \
    || bad "a disabled timer reads the same as a missing one"
grep -q 'none enabled: nothing runs unattended' "$md" \
    && ok "and it says out loud that nothing runs unattended" \
    || bad "a profile with no enabled timer is not told so"

echo "== a skip is not a pass =="
# The container cases used to `bad` when no runtime was installed, so the suite
# could never be green on a machine without podman or docker, which is every
# container. Counting them as passes would be worse: docs/lessons.md already has
# an entry where a missing optional dependency turned a gate green over seven
# real errors. They are their own count, printed, and CI requires it to be zero.
grep -q 'skip=$((skip+1))' "$root/tests/run-tests.sh" \
    && ok "a skip has its own counter" || bad "a skip is folded into pass or fail"
grep -q 'skipped' "$root/.github/workflows/ci.yml" \
    && ok "CI fails when the suite skips anything" \
    || bad "CI would accept a run that skipped half the cases"
# Proved by driving the summary: a suite with a skip must say so in its last line.
probe="$stub_dir/skipprobe.sh"
{ sed -n '1,/^check(){/p' "$root/tests/run-tests.sh"
  printf 'noenv "a deliberate skip"\n'
  sed -n '/^if \[ "\$skip" -gt 0 \]/,$p' "$root/tests/run-tests.sh"; } > "$probe"
out=$(bash "$probe" 2>&1)
printf '%s' "$out" | grep -qE '0 passed, 0 failed, 1 skipped' \
    && ok "and the summary line names the skipped count" \
    || bad "a skipped case left no trace in the summary: $(printf '%s' "$out" | tail -1)"

echo "== the gate needs nothing that is not already required =="
# Run inside python:3.12, five tests failed with `jq: command not found`, and
# the refusal read "#7 has  failing check(s)" with a blank where the number
# goes. jq was the only dependency the gate had that nothing else here needs.
# Whole-line comments dropped first. The paragraph explaining why jq is gone
# matched a grep for jq, which is the same over-match that made the "CI reads no
# secrets" check fail on the comment describing the policy.
if grep -v '^[[:space:]]*#' "$mg" | grep -qE '\| *jq |\$\( *jq |^ *jq '; then
    bad "maintainer-merge still shells out to jq"
else
    ok "maintainer-merge needs no jq; gh's own --jq is not a second binary"
fi
# And a count that is not a number must say so rather than interpolate a blank.
make_stub gh "case \"\$*\" in
      *'auth switch'*) exit 0;;
      *'api user'*) echo testuser;;
      *reviewDecision*) echo APPROVED;;
      *headRefOid*) echo abcdef1234567890;;
      *mergeStateStatus*) echo CLEAN;;
      *'pr checks'*) printf 'not json at all';;
    esac"
PATH="$stub_dir:$PATH" MAINTAINER_STATE="$forge" MAINTAINER_ACCOUNT=testuser \
    MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp \
    bash "$mg" receipt 9 abcdef1234567890 'proved' >/dev/null 2>&1
out=$(PATH="$stub_dir:$PATH" MAINTAINER_STATE="$forge" MAINTAINER_ACCOUNT=testuser \
      MAINTAINER_SLUG=o/r MAINTAINER_REPO=/tmp PROD_GLOBS="bin/*" \
      bash "$mg" merge 9 2>&1); rc=$?
[ "$rc" != 0 ] && ok "an unreadable check list refuses the merge" \
    || bad "the gate merged on a check list it could not read"
printf '%s' "$out" | grep -qE 'could not read the check list|not a number' \
    && ok "and it names the check list rather than reporting a blank count" \
    || bad "the refusal blamed something else: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90)"

echo "== the merge is pinned to the head that was checked =="
grep -q 'match-head-commit' "$mg" && ok "gh pr merge is pinned to the verified head" \
    || bad "a push landing mid-merge would be merged unchecked"
echo "== naming a suite does not skip the coverage check =="
grep -q 'does not cover every changed path' "$mg" \
    && ok "an explicitly named suite must still cover the changed paths" \
    || bad "naming a suite bypasses coverage, and the name is reachable from MCP"

if [ "$skip" -gt 0 ]; then
    printf '\n  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
    printf '  A skip is a case this machine could not run. CI requires zero.\n'
else
    printf '\n  %d passed, %d failed\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
