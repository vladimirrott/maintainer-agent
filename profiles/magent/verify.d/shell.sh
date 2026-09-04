# shellcheck shell=bash
# This project's own suite, in a container.
#
# The magent profile had no verify.d at all, so the merge gate could not verify
# a single pull request against the repository that contains the merge gate. It
# was found by trying: "no suite in .../verify.d covers every changed path".

suite_covers() {
    case "$1" in
        *.sh|bin/*|lib/*|tests/*|evals/*|scripts/*|.githooks/*|profiles/*) return 0 ;;
    esac
    return 1
}

# python:3.12, not -slim: the suite builds real git fixtures to test the
# production-diff rule, and the slim image has no git. Measured, not assumed --
# the first attempt used -slim and eight cases failed on missing binaries.
suite_image() { printf 'docker.io/library/python:3.12'; }

suite_mutate_glob() { printf '*.sh'; }

# Copied out of the read-only mount first. The suite writes fixtures next to
# itself, and /repo is mounted ro.
suite_command() { printf 'cp -r /repo /tmp/w && cd /tmp/w && ./tests/run-tests.sh\n'; }

# The suite prints its own count. A skip is not a pass here either: a run that
# skipped everything would report "0 passed" and get no receipt.
suite_ran() {  # $1 = the clean log
    local n; n="$(sed -n 's/^ *\([0-9]\+\) passed.*/\1/p' "$1" | tail -1)"
    printf '%s' "${n:-0}"
}
