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

# bash:5 rather than a distribution image: the tests need bash, git and nothing
# else, and a smaller image is a smaller thing to trust.
suite_image() { printf 'docker.io/library/bash:5'; }

# What that image has to contain. maintainer-doctor runs the image and checks
# each of these resolves, because nothing else ties the image to what the suite
# runs inside it. sysknife's shell suite sat in bash:5 with no python3; when
# sysknife#386 made a test drive a python script the clean run began failing,
# no receipt was earnable, and the merge gate reported it as the pull request
# failing its own test rather than as itself being broken.
#
# the template's suite_command runs `bash <script>` and nothing else. A suite
# that grows a dependency adds it here, or maintainer-doctor cannot see it.
suite_needs() { printf 'bash'; }

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
