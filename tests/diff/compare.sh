#!/usr/bin/env bash
# Compare two recordings made by record.sh.
#
#   compare.sh <out-old> <out-new>
#
# Prints, for every scenario and field that differs, a header line
#   DIFF scenario=<name> field=<file>
# followed by a unified diff. Fields are argv.<stub>.log, rc, stdout, stderr,
# state.tree and every file under state.files/.
# Exit: 0 zero differences, 1 at least one difference, 2 harness error.
# A missing, empty or unfinished result directory is a harness error: a recording
# that holds nothing must never read as "no differences".
set -uo pipefail

die() { printf 'compare.sh: %s\n' "$1" >&2; exit 2; }
[ $# -eq 2 ] || die "usage: compare.sh <out-old> <out-new>"
old="$1"; new="$2"

check_dir() {  # $1 = label, $2 = path; sets nothing, dies on any problem
    [ -e "$2" ] || die "$1 result directory '$2' does not exist"
    [ -d "$2" ] || die "$1 result '$2' is not a directory"
    [ -f "$2/.complete" ] || die "$1 result '$2' has no .complete marker: the recording is empty or was interrupted"
    local listed
    listed="$(LC_ALL=C find "$2" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')" || die "cannot list $2"
    [ -n "$listed" ] || die "$1 result '$2' holds no scenario directories"
    local n d
    n="$(tr -d '[:space:]' < "$2/.complete")"
    case "$n" in ''|*[!0-9]*|0) die "$1 result '$2' has a bad .complete count '$n'" ;; esac
    [ "$(printf '%s\n' "$listed" | wc -l)" = "$n" ] \
        || die "$1 result '$2' says $n scenarios but holds $(printf '%s\n' "$listed" | wc -l)"
    while IFS= read -r d; do
        [ -f "$2/$d/rc" ] || die "$1 scenario '$d' has no rc file; the result is incomplete"
    done <<<"$listed"
}
check_dir old "$old"
check_dir new "$new"

names="$( { LC_ALL=C find "$old" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
            LC_ALL=C find "$new" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'; } | LC_ALL=C sort -u )" \
    || die "cannot list scenarios"

scn_total=0; scn_diff=0; fld_total=0; fld_diff=0
while IFS= read -r name; do
    scn_total=$((scn_total + 1))
    if [ ! -d "$old/$name" ] || [ ! -d "$new/$name" ]; then
        side=old; [ -d "$old/$name" ] && side=new
        printf 'DIFF scenario=%s field=<scenario> missing in %s\n' "$name" "$side"
        scn_diff=$((scn_diff + 1)); fld_diff=$((fld_diff + 1)); fld_total=$((fld_total + 1))
        continue
    fi
    fields="$( { ( cd "$old/$name" && find . -type f -printf '%P\n' )
                 ( cd "$new/$name" && find . -type f -printf '%P\n' ); } | LC_ALL=C sort -u )" \
        || die "cannot list the fields of $name"
    this_diff=0
    while IFS= read -r field; do
        [ -n "$field" ] || continue
        fld_total=$((fld_total + 1))
        a="$old/$name/$field"; b="$new/$name/$field"
        # A field one side never wrote is not an empty field. Comparing it with
        # /dev/null made "no argv log at all" equal "a stub nobody called".
        if [ ! -f "$a" ] || [ ! -f "$b" ]; then
            side=old; [ -f "$a" ] && side=new
            printf 'DIFF scenario=%s field=%s\nfield missing in %s\n' "$name" "$field" "$side"
            fld_diff=$((fld_diff + 1)); this_diff=1
            continue
        fi
        d="$(diff -u --label "old/$name/$field" --label "new/$name/$field" "$a" "$b" 2>&1)"; drc=$?
        case "$drc" in
            0) ;;
            1) printf 'DIFF scenario=%s field=%s\n%s\n' "$name" "$field" "$d"
               fld_diff=$((fld_diff + 1)); this_diff=1 ;;
            *) die "diff failed on $name/$field (exit $drc): $d" ;;
        esac
    done <<<"$fields"
    [ "$this_diff" = 0 ] || scn_diff=$((scn_diff + 1))
done <<<"$names"

# What the program text says about absolute tool paths (record.sh writes it once
# per tree). A path such as /usr/bin/gh bypasses the stubs, so the set of paths a
# tree names must match; a file one side never wrote is a difference, not empty.
fld_total=$((fld_total + 1))
if [ ! -f "$old/tree.abspath" ] || [ ! -f "$new/tree.abspath" ]; then
    side=old; [ -f "$old/tree.abspath" ] && side=new
    printf 'DIFF scenario=<tree> field=tree.abspath\nfield missing in %s\n' "$side"
    fld_diff=$((fld_diff + 1))
else
    d="$(diff -u --label old/tree.abspath --label new/tree.abspath "$old/tree.abspath" "$new/tree.abspath" 2>&1)"; drc=$?
    case "$drc" in
        0) ;;
        1) printf 'DIFF scenario=<tree> field=tree.abspath\n%s\n' "$d"; fld_diff=$((fld_diff + 1)) ;;
        *) die "diff failed on tree.abspath (exit $drc): $d" ;;
    esac
fi

if [ "$fld_diff" -eq 0 ]; then
    printf 'identical: %d scenarios, %d fields compared, 0 differences\n' "$scn_total" "$fld_total"
    exit 0
fi
printf 'DIFFERENT: %d of %d scenarios differ, %d of %d fields\n' "$scn_diff" "$scn_total" "$fld_diff" "$fld_total"
exit 1
