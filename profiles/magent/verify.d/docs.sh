# shellcheck shell=bash
# Prose, checked against the tree it describes.
#
# Every number in the README is derived by scripts/check_claims.sh from the
# suite, the scenario files, the backends and the generated deny wall. So a
# mutation that changes a published figure in any .md must turn it red, which is
# what makes a docs-only pull request verifiable here at all.

suite_covers() {
    case "$1" in
        *.md|LICENSE|.github/ISSUE_TEMPLATE/*) return 0 ;;
    esac
    return 1
}

suite_image() { printf 'docker.io/library/python:3.12'; }

# What that image has to contain. maintainer-doctor runs the image and checks
# each of these resolves, because nothing else ties the image to what the suite
# runs inside it. sysknife's shell suite sat in bash:5 with no python3; when
# sysknife#386 made a test drive a python script the clean run began failing,
# no receipt was earnable, and the merge gate reported it as the pull request
# failing its own test rather than as itself being broken.
#
# check_claims.sh is bash driving python, and it reads the repository with git.
suite_needs() { printf 'bash python3 git'; }

suite_mutate_glob() { printf '*.md'; }

suite_command() { printf 'cp -r /repo /tmp/w && cd /tmp/w && ./scripts/check_claims.sh\n'; }

# check_claims prints one line per figure it reconciled, and refuses outright
# when it cannot measure one. Nothing printed means it never ran.
suite_ran() {  # $1 = the clean log
    local n; n="$(grep -c '^  ok: ' "$1" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}
