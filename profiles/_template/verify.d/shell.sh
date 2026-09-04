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
