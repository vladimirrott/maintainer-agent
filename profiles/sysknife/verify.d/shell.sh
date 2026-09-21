# shellcheck shell=bash
# Shell suite. sysknife's release scripts and end-to-end tests are bash, and a
# pull request touching only those had no way to earn a receipt until this
# existed: see issue #11.
#
# The filter is the path of a script to run, relative to the repository root.

suite_covers() {
    case "$1" in
        *.sh|.githooks/*) return 0 ;;
        # Python, packaging helpers and the Makefile, because the release tests
        # this suite runs are what drive them. Named, so the claim can be
        # checked rather than believed:
        #
        #   scripts/check_evidence_claims.py  <- tests/release/public-claims.test.sh,
        #                                        tests/e2e/story-metadata.test.sh
        #   scripts/record_test_baseline.py   <- tests/release/test-baseline-provenance.test.sh
        #   scripts/record_story_run.py       <- tests/e2e/story-runner-verdicts.test.sh
        #   packaging/sysknife-*-edit         <- tests/release/{grub-kargs,log,mount}-edit.test.sh
        #   packaging/*.service, sysknife-sudoers
        #                                     <- tests/release/systemd-directory-modes.test.sh
        #   Makefile                          <- tests/release/install-paths.test.sh
        #
        # A coverage claim that is wrong for a particular filter cannot buy a
        # receipt: the mutation lands on the file, the named test does not
        # exercise it, the mutated run passes, and the gate refuses with THE
        # GUARD DOES NOT BITE. That backstop is why this list can be this wide.
        #   .github/workflows/*.yml           <- tests/release/postgres-contract-guard.test.sh,
        #                                        release-rehearsal.test.sh,
        #                                        markdown-link-files.test.sh, node-eol.test.sh
        #
        # The workflows are covered, and a receipt is not a substitute for
        # reading a workflow diff. Those are separate controls and the doctrine's
        # human read is unchanged. Leaving them uncovered was the other option
        # and it is worse: every workflow-touching pull request would then have
        # to be merged around the gate, and a gate a whole class routes around
        # is decorative. The tests above read those files and assert properties
        # of their contents, so a mutation to a workflow does flip them.
        *.py|packaging/*|Makefile|.github/*) return 0 ;;
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
# started driving a python script.
#
# And the third. python:3.12 carries bash 5.2, python3 and git and none of
# cargo, node or npm, so tests/release/release-rehearsal.test.sh could not run
# unmutated at all: it drives scripts/release_rehearsal.sh, whose preflight is
#
#     for tool in cargo node npm sha256sum file; do
#
# Three consecutive review runs reported the same `ERROR: required tool is
# missing: cargo`, and #443, #435 and #446 each sat unmergeable because of it.
#
# So the image is built here rather than picked, from shell.Containerfile
# beside this file. That costs the shared base docs.sh had, which was worth
# something, and buys a suite whose image is derived from what its scripts
# declare they need. maintainer-doctor refuses when the image is absent and
# prints the build command, because an image that exists only on the host that
# built it is not a reproducible gate.
#
# MAINTAINER_SHELL_IMAGE overrides it, and exists for one caller: this
# repository's own offline suite drives maintainer-merge end to end against
# this profile, and it runs on GitHub runners where a locally built image does
# not exist. Those cases exercise the gate's machinery on a four-line
# check.sh, not sysknife's release scripts, so a registry image is the honest
# thing for them to use. maintainer-doctor prints whichever image is in
# effect, so an override left set is visible rather than silent.
suite_image() { printf '%s' "${MAINTAINER_SHELL_IMAGE:-localhost/sk-rehearsal:1}"; }

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
suite_needs() { printf 'bash python3 git cargo node npm sha256sum file'; }

# One glob per line. The extensionless entry is the point: every privileged
# helper in packaging/ is a python script with no .py suffix, so a single
# `-name '*.py'` could not reach the trust boundary this repository calls
# non-negotiable.
suite_mutate_glob() { printf '%s\n' '*.sh' '*.py' 'sysknife-*' 'Makefile' '*.yml'; }

# Run the pull request's scripts as a normal uid, not as root.
#
# The verify container defaulted to uid 0 because the image does. Two things
# were wrong with that. Running untrusted pull-request code as root inside a
# container is a worse posture than running it as nobody, for no benefit: these
# scripts install nothing and own nothing.
#
# And it broke a real proof. sysknife#429 adds a release test whose credential
# drop case carries `skipUnless(os.geteuid() == 0)`. As root that case stops
# skipping and runs for real, its chown wants CAP_CHOWN, --cap-drop=ALL has
# taken it, and the run dies with `PermissionError: [Errno 1] Operation not
# permitted`. The gate then reported that as the pull request failing its own
# test. That is the fourth time this suite's container has failed and been
# described as the contributor's fault: an image with no python3, an image with
# no git, /tmp mounted noexec, and now this.
#
# As uid 1000 the skip fires, which is exactly what the test does on a
# developer's machine and in CI's unprivileged jobs, and the other ten
# assertions still run and still bite. CI runs the root case separately, under
# sudo, which is where a real credential drop belongs.
#
# 1000 rather than `nobody`: the extracted tree on the host belongs to the uid
# running the gate, so the scripts have to be able to read it.
# How to stop being uid 0 differs by runtime, and getting it wrong locks the
# suite out of its own checkout. Under ROOTLESS podman container uid 0 is
# already the host user, so `--user 1000` maps into the subuid range instead and
# the mounted tree becomes unreadable: measured, `bash: tests/release/
# action-steps.test.sh: Permission denied`. `--userns=keep-id` keeps uid 1000
# mapped to uid 1000, which is what the extracted tree belongs to. Under docker
# the container really is root and `--user` is the flag that means this.
suite_podman_args() {  # $1 = the container runtime
    printf '%s\n' -e "BASH_ENV=/dev/null"
    case "${1:-podman}" in
        *podman*) printf '%s\n' --userns=keep-id ;;
        *)        printf '%s\n' --user "$(id -u):$(id -g)" ;;
    esac
}

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
