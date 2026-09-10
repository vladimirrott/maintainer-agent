# shellcheck shell=bash
# Shell suite. sysknife's release scripts and end-to-end tests are bash, and a
# pull request touching only those had no way to earn a receipt until this
# existed: see issue #11.
#
# The filter is the path of a script to run, relative to the repository root.

suite_covers() {
    case "$1" in
        *.sh|.githooks/*) return 0 ;;
    esac
    return 1
}

# python:3.12-slim, not bash:5. The original choice reasoned that these tests
# need bash and nothing else, which stopped being true when sysknife#386 made
# tests/e2e/story-metadata.test.sh drive scripts/check_evidence_claims.py. It
# was also wrong on its own terms: bash:5 carries no git either, so the "bash,
# git and nothing else" it claimed to provide was never provided.
#
# The -slim variant carried bash and python3 and no git, and on 2026-09-10
# sysknife#410 added a release test that does `git init`, `git add` and
# `git update-index` to prove the pre-commit secret scanner fails closed. The
# gate would have run that test, watched git fail, and reported the contributor
# as failing their own test.
#
# That is the second time this suite's image was chosen for what the scripts
# needed on the day it was written: bash:5 carried no python3 when sysknife#386
# started driving a python script. python:3.12 carries bash 5.2, python3 and
# git, and docs.sh shares the same base, so this is one trust surface, not two.
suite_image() { printf 'docker.io/library/python:3.12'; }

# What that image has to contain. maintainer-doctor runs the image and checks
# each of these resolves, because nothing else ties the image to what the suite
# runs inside it. sysknife's shell suite sat in bash:5 with no python3; when
# sysknife#386 made a test drive a python script the clean run began failing,
# no receipt was earnable, and the merge gate reported it as the pull request
# failing its own test rather than as itself being broken.
#
# bash for the scripts themselves, python3 because tests/e2e/story-metadata.test.sh
# drives scripts/check_evidence_claims.py, git because tests/release/no-secrets.test.sh
# builds a throwaway repository to exercise the --staged path the pre-commit
# hook runs. maintainer-doctor runs the image and checks each one resolves.
suite_needs() { printf 'bash python3 git'; }

suite_mutate_glob() { printf '*.sh'; }

suite_podman_args() { printf '%s\n' -e "BASH_ENV=/dev/null"; }

suite_command() { printf 'bash %s\n' "$1"; }

# These scripts have no common "N passed" line; what they share is that each
# one prints its own diagnostic and exits non-zero when its guard fires. So the
# evidence that the run was not vacuous is that the script produced output at
# all. A script that prints nothing and exits 0 proves nothing, and gets no
# receipt.
suite_ran() {  # $1 = the clean log
    local bytes; bytes="$(wc -c < "$1" | tr -d ' ')"
    [ "${bytes:-0}" -gt 0 ] && printf '1' || printf '0'
}
