#!/usr/bin/env bash
# Run scenarios against ONE tree and write one result directory per scenario.
#
#   record.sh <tree> <scenario-dir-or-file> <out-dir>
#
# <tree> has the magent layout (bin/, lib/, profiles/, ...). Today it is the bash
# tree; later bin/maintainer-merge and friends may be Rust binaries. The programs
# are executed through their own path, never through `bash FILE`, so the harness
# does not care which language a tree is written in.
#
# Exit: 0 every scenario ran and was recorded, 2 a harness error. The exit code
# of the program under test is data, written to <out>/<scenario>/rc.
set -uo pipefail
# Directory and file modes are part of the recorded state; the host umask must not leak in.
umask 022

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
die() { printf 'record.sh: %s\n' "$1" >&2; exit 2; }

# The pre-commit hook exports GIT_DIR and GIT_INDEX_FILE for the commit in
# progress, and a scratch repository made under them writes into the caller's
# index. Nothing here unsets them: every scenario starts under `env -i`, and
# normalise.py builds its own environment for git, so they never arrive.
# selftest.sh runs a recording under a decoy GIT_DIR and checks the decoy.

[ $# -eq 3 ] || die "usage: record.sh <tree> <scenario-dir-or-file> <out-dir>"
tree_arg="$1"; scen_arg="$2"; out_arg="$3"
[ -d "$tree_arg" ] || die "tree '$tree_arg' is not a directory"
tree="$(cd "$tree_arg" && pwd)"
tree_real="$(readlink -f "$tree")"
for need in bin lib profiles; do
    [ -d "$tree/$need" ] || die "tree '$tree' has no $need/ directory; it is not a magent tree"
done

scenarios=()
if [ -f "$scen_arg" ]; then
    scenarios=("$scen_arg")
elif [ -d "$scen_arg" ]; then
    list="$(LC_ALL=C find "$scen_arg" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)" \
        || die "could not list $scen_arg"
    [ -n "$list" ] && mapfile -t scenarios <<<"$list"
else
    die "scenario path '$scen_arg' is neither a file nor a directory"
fi
[ "${#scenarios[@]}" -gt 0 ] || die "no scenarios (*.sh) in '$scen_arg'"

if [ -e "$out_arg" ]; then
    [ -d "$out_arg" ] || die "out-dir '$out_arg' exists and is not a directory"
    [ -z "$(ls -A "$out_arg")" ] || die "out-dir '$out_arg' is not empty; remove it first so no old result is mistaken for this one"
fi
mkdir -p "$out_arg" || die "cannot create out-dir '$out_arg'"
out="$(cd "$out_arg" && pwd)"

scratch_base="${MX_SCRATCH:-${XDG_CACHE_HOME:-$HOME/.cache}/magent-diff-scratch}"
mkdir -p "$scratch_base" || die "cannot create $scratch_base"
S="$(mktemp -d "$scratch_base/rec.XXXXXX")" || die "cannot create a scratch directory in $scratch_base"
cleanup() { [ "${MX_KEEP:-0}" = 1 ] && { printf 'record.sh: kept scratch %s\n' "$S" >&2; return 0; }; rm -rf "$S"; }
trap cleanup EXIT

# The real tools the programs may run. A name missing here is "command not found".
tools="bash sh env git python3 sed timeout tar grep awk find xargs sort uniq head tail cat cp mv rm mkdir rmdir ln ls
       chmod touch date sleep wc tr cut paste printf tee stat readlink realpath dirname basename mktemp id uname
       sha256sum od diff cmp expr seq true false test"
resolved=()
for t in $tools; do
    p="$(type -P "$t" 2>/dev/null)" || die "required tool '$t' is not on PATH; the real-tool directory cannot be built"
    case "$p" in /*) ;; *) die "'$t' resolves to '$p', which is not a file" ;; esac
    resolved+=("$t=$p")
done

tree_fingerprint() { ( cd "$tree" && find . -path ./.git -prune -o -type f -printf '%p %s %T@\n' | LC_ALL=C sort ); }
before="$(tree_fingerprint)" || die "cannot read the tree"

# Absolute paths to the tools the scenarios stub. A program that runs /usr/bin/gh
# reaches the host's real gh and no stub ever sees the call, so the argv logs of a
# tree that does it simply lack a line. This scan reads what the program TEXT
# says (scripts, and strings in a compiled binary) and writes the distinct paths
# to tree.abspath, which compare.sh holds equal across trees. It cannot see a
# path built at run time; the argv logs and calls.log catch the effect of that.
stub_tools="$(sed -n 's/^MX_STUB_TOOLS="\(.*\)"$/\1/p' "$here/lib.sh")"
[ -n "$stub_tools" ] || die "cannot read MX_STUB_TOOLS from $here/lib.sh"
alt="$(printf '%s' "$stub_tools" | sed 's/ /|/g; s/-/\\-/g')"
abs_pat='(?<![A-Za-z0-9_.~$/-])(?:/usr/local/bin|/usr/bin|/usr/sbin|/bin|/sbin|/snap/bin|/opt/homebrew/bin)/(?:'"$alt"')(?![A-Za-z0-9_.-])'
scan_roots=()
for r in bin lib scripts platform profiles evals install.sh new-profile.sh; do
    [ -e "$tree/$r" ] && scan_roots+=("$tree/$r")
done
[ "${#scan_roots[@]}" -gt 0 ] || die "tree '$tree' has nothing to scan for absolute tool paths"
abs_out="$(LC_ALL=C grep -RhaoP -e "$abs_pat" -- "${scan_roots[@]}")"; abs_rc=$?
case "$abs_rc" in 0|1) ;; *) die "the absolute-path scan of '$tree' failed (grep exit $abs_rc)" ;; esac
printf '%s\n' "$abs_out" | LC_ALL=C sed '/^$/d' | LC_ALL=C sort -u > "$out/tree.abspath" \
    || die "cannot write $out/tree.abspath"

count=0
for scen in "${scenarios[@]}"; do
    name="$(basename "$scen" .sh)"
    W="$S/$name"
    mkdir -p "$W"/{home,stubs,realbin,tmp,cwd,raw} || die "cannot create $W"
    for pair in "${resolved[@]}"; do ln -s "${pair#*=}" "$W/realbin/${pair%%=*}" || die "cannot link ${pair%%=*}"; done

    env -i PATH="$W/realbin" HOME="$W/home" \
        MX_TREE="$tree" MX_WORK="$W" MX_RAW="$W/raw" MX_HOME="$W/home" MX_STUBS="$W/stubs" \
        MX_REALBIN="$W/realbin" MX_TMP="$W/tmp" MX_CWD="$W/cwd" MX_TIMEOUT="${MX_TIMEOUT:-120}" \
        MX_LIB="$here/lib.sh" MX_SCENARIO="$scen" \
        "$W/realbin/bash" -c '. "$MX_LIB"; . "$MX_SCENARIO"' \
        >"$W/raw/setup.log" 2>&1
    src=$?
    if [ "$src" -ne 0 ]; then
        printf 'record.sh: scenario %s failed in setup or harness (exit %d):\n' "$name" "$src" >&2
        sed 's/^/    /' "$W/raw/setup.log" >&2
        exit 2
    fi
    [ -f "$W/raw/rc" ] || die "scenario $name finished without running a program (no mx_run)"

    fin="$(python3 -I "$here/normalise.py" finalise --work "$W" --tree "$tree" --tree "$tree_real" \
            --out "$out/$name" 2>&1)" || die "could not write the result for $name: $fin"
    count=$((count + 1))
done

after="$(tree_fingerprint)" || die "cannot read the tree after the run"
[ "$before" = "$after" ] || die "a scenario changed files under the tree being tested; the recording is not trustworthy"
printf '%s\n' "$count" > "$out/.complete" || die "cannot write $out/.complete"
printf 'recorded %d scenarios from %s into %s\n' "$count" "$tree" "$out"
