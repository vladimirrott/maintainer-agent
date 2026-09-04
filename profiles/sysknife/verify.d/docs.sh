# shellcheck shell=bash
# Docs suite. A pull request that changes only prose could not earn a receipt at
# all, and therefore could never be merged through this gate: the rust suite
# covers *.rs, the shell suite covers *.sh, and CONTRIBUTING.md matched neither.
# That is issue #11 again in a third language, found on a live pull request.
#
# Prose is verifiable here because sysknife screens it. Every published figure
# is checked against the artifact that produced it, so a mutation that changes a
# figure in any .md must turn the screen red. A docs pull request whose changed
# file the screen never reads still gets a receipt saying only that the screen
# runs, which is the honest bound and is written into the receipt as such.

suite_covers() {
    case "$1" in
        *.md|LICENSE|.github/ISSUE_TEMPLATE/*) return 0 ;;
    esac
    return 1
}

# python:3.12-slim carries bash and a stdlib python, which is all
# check_evidence_claims.py imports. No pip install, no network: the container
# runs with --network=none and would fail anyway.
suite_image() { printf 'docker.io/library/python:3.12-slim'; }

suite_mutate_glob() { printf '*.md'; }

suite_command() { printf 'bash scripts/check_public_claims.sh\n'; }

# The screen prints one line per artifact it reconciled. Nothing printed means
# it did not run, which is the vacuous pass this whole file exists to refuse.
suite_ran() {  # $1 = the clean log
    local n; n="$(grep -c . "$1" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}
