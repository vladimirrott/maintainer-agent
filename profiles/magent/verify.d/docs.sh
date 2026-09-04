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

suite_mutate_glob() { printf '*.md'; }

suite_command() { printf 'cp -r /repo /tmp/w && cd /tmp/w && ./scripts/check_claims.sh\n'; }

# check_claims prints one line per figure it reconciled, and refuses outright
# when it cannot measure one. Nothing printed means it never ran.
suite_ran() {  # $1 = the clean log
    local n; n="$(grep -c '^  ok: ' "$1" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}
