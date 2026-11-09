#!/usr/bin/env bash
# The Rust gate. Four steps, in this order, stopping at the first failure:
#   1. cargo fmt --all --check
#   2. cargo clippy --workspace --all-targets --locked -- -D warnings
#   3. cargo test --workspace --locked, and a floor on how many tests ran
#   4. a probe that proves the "only mx-ports starts a process" rule still bites
# Each step prints one `[rust-gate]` line. Exit 0 with `no rust workspace` only
# when rust/Cargo.toml does not exist: a missing tool or a missing file inside an
# existing workspace is a failure, never a skip.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ws="$root/rust"

# A run that executed this few tests did not run the suite. 15 or fewer fails.
MIN_TESTS=15

say() { printf '[rust-gate] %s\n' "$*"; }

# Print what the failing step said, then name the step, then stop.
fail() {
    local step="$1" detail="${2:-}"
    [ -z "$detail" ] || printf '%s\n' "$detail" >&2
    say "FAILED: $step"
    exit 1
}

probe=""
cleanup() { [ -z "$probe" ] || rm -rf "$probe"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$ws/Cargo.toml" ]; then
    say "no rust workspace"
    exit 0
fi
command -v cargo >/dev/null 2>&1 || fail "cargo is not installed, so nothing was checked"
cd "$ws" || fail "cannot enter $ws"
export CARGO_TERM_COLOR=never

# 1. format
out="$(cargo fmt --all --check 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "fmt (cargo fmt --all --check exited $rc)" "$out"
say "fmt: ok"

# 2. clippy, every target, warnings are errors
out="$(cargo clippy --workspace --all-targets --locked -- -D warnings 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "clippy (exited $rc)" "$out"
say "clippy: ok"

# 3. tests. The count comes from cargo's own "test result:" lines, summed.
out="$(cargo test --workspace --locked 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "test (cargo test exited $rc)" "$out"
if ! counts="$(awk '
    /^test result: / {
        results++
        for (i = 2; i <= NF; i++) {
            if ($i == "passed;")  passed  += $(i - 1)
            if ($i == "failed;")  failed  += $(i - 1)
            if ($i == "ignored;") ignored += $(i - 1)
        }
    }
    END { printf "%d %d %d %d", results, passed, failed, ignored }
' <<<"$out")"; then
    fail "test (could not read the result lines)" "$out"
fi
read -r results passed failed ignored <<<"$counts"
[ "${results:-0}" -gt 0 ] || fail "test (cargo printed no 'test result:' line, so nothing ran)" "$out"
[ "${failed:-1}" = 0 ] || fail "test ($failed failed)" "$out"
[ "${ignored:-1}" = 0 ] || fail "test ($ignored ignored; an ignored test reads as green)" "$out"
[ "${passed:-0}" -gt "$MIN_TESTS" ] \
    || fail "test (only ${passed:-0} tests ran; more than $MIN_TESTS must)" "$out"
say "test: ok ($passed passed, $failed failed, $ignored ignored, in $results test binaries)"

# 4. the disallowed-call probe. Copy the workspace, add a crate that calls
# Command::new, and demand that clippy refuses it. A control run on the clean
# copy comes first, so a refusal can only come from the added crate.
for f in Cargo.toml Cargo.lock clippy.toml; do
    [ -f "$ws/$f" ] || fail "probe (rust/$f is missing, so the process-spawn rule is not in force)"
done
probe="$(mktemp -d "${TMPDIR:-/tmp}/rust-gate-probe.XXXXXX")" || fail "probe (cannot make a scratch directory)"
cp "$ws/Cargo.toml" "$ws/Cargo.lock" "$ws/clippy.toml" "$probe/" || fail "probe (cannot copy the workspace files)"
cp -R "$ws/crates" "$probe/crates" || fail "probe (cannot copy the crates)"
# Share the target directory so the dependencies are not built twice.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ws/target}"

out="$(cd "$probe" && cargo clippy --workspace --all-targets --locked --offline -- -D warnings 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "probe (the clean copy does not pass clippy, so the probe proves nothing; exited $rc)" "$out"

mkdir -p "$probe/crates/mx-probe-violation/src" || fail "probe (cannot add the probe crate)"
cat > "$probe/crates/mx-probe-violation/Cargo.toml" <<'TOML'
[package]
name = "mx-probe-violation"
version = "0.0.0"
edition.workspace = true
rust-version.workspace = true
publish = false

[lints]
workspace = true
TOML
cat > "$probe/crates/mx-probe-violation/src/lib.rs" <<'RS'
//! Starts a process outside mx-ports. The workspace lints must refuse this.
pub fn spawn() {
    let _ = std::process::Command::new("true");
}
RS
out="$(cd "$probe" && cargo clippy --workspace --all-targets --offline -- -D warnings 2>&1)"; rc=$?
[ "$rc" != 0 ] || fail "probe (clippy ACCEPTED Command::new outside mx-ports, so the rule is off)" "$out"
want="disallowed method \`std::process::Command::new\`"
grep -qF "$want" <<<"$out" \
    || fail "probe (clippy failed, but not on the disallowed-method rule)" "$out"
say "probe: ok (Command::new outside mx-ports is refused by clippy)"
