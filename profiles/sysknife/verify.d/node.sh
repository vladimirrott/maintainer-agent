# shellcheck shell=bash
# Node suite. `packages/setup` is an npm package with 127 tests of its own, it
# ships to users as `sysknife-setup`, and until this existed no suite claimed a
# line of it: rust covers *.rs, shell covers *.sh and the python helpers, docs
# covers *.md, and the JavaScript matched none of them. So the gate refused
# every pull request touching the installer, which is issue #11 in a fourth
# language. Found on sysknife#468, which raised the package's Node floor.

suite_covers() {  # $1 = a path from the pull request
    case "$1" in
        packages/setup/*) return 0 ;;
    esac
    return 1
}

# node:24-slim, matching what CI runs. The package declares no dependencies at
# all and its test script is `node --test tests/*.test.mjs`, so there is no
# install step and nothing to fetch: the container runs with --network=none and
# an `npm install` would fail there anyway. That property is worth keeping. If
# packages/setup ever takes a dependency, this suite needs a prefetch phase the
# way the rust suite has one, and the clean run will say so rather than pass.
suite_image() { printf 'docker.io/library/node:24-slim'; }

# What that image has to contain. maintainer-doctor runs the image and checks
# each of these resolves, because nothing else ties the image to what the suite
# runs inside it. sysknife's shell suite sat in an image with no cargo for three
# review runs and the gate reported it as the pull request failing its own test.
suite_needs() { printf 'node npm'; }

# JSON is in the list because the support floor lives in package.json's
# `engines.node` as well as in the preflight, and a mutation that moves one and
# not the other is exactly the drift these tests are written to catch.
suite_mutate_glob() { printf '%s\n' '*.js' '*.mjs' '*.json'; }

# Run the pull request's code as a normal uid rather than as root. These tests
# install nothing and own nothing, so root buys nothing and costs the usual
# posture. Under rootless podman container uid 0 IS the host user, so
# --userns=keep-id is what keeps the extracted tree readable; under docker the
# container really is root and --user is the flag that means this.
suite_podman_args() {  # $1 = the container runtime
    case "${1:-podman}" in
        *podman*) printf '%s\n' --userns=keep-id ;;
        *)        printf '%s\n' --user "$(id -u):$(id -g)" ;;
    esac
}

# $1 = a node test-name pattern. `npm test` forwards what follows `--` to the
# script, and `node --test` takes --test-name-pattern.
suite_command() {
    printf 'npm test --prefix packages/setup -- --test-name-pattern %s\n' "$1"
}

# node --test prints a TAP summary. `# pass N` is the count of tests that ran
# and passed; a pattern matching nothing prints `# pass 0`, which is the
# vacuous run this whole file exists to refuse.
suite_ran() {  # $1 = the clean log
    awk '/^# pass /{s+=$3} END{print s+0}' "$1"
}
