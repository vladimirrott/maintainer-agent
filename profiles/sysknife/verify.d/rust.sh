# shellcheck shell=bash
# Rust suite. The one `maintainer-merge verify` used to assume every repository
# was.
#
# Four functions, and every suite needs all four. The fourth is the one that
# matters: without a way to tell that the command really ran something, a clean
# run that matched no tests "passes", a mutation that merely breaks compilation
# "fails", and the receipt records a proof that never happened.

suite_covers() {  # $1 = a path from the pull request
    case "$1" in
        *.rs|*/Cargo.toml|Cargo.toml|Cargo.lock) return 0 ;;
        # The evidence artifact holds the Rust test count and nothing else that
        # a Rust pull request moves. CONTRIBUTING.md requires it to change on
        # any added or removed test, so every test-adding pull request carried a
        # path no suite claimed, and the gate refused to write a receipt for the
        # whole class. This suite runs the tests whose count that file records,
        # which is what covering a path means here.
        #
        # It does not run vitest, so the `frontend_tests` field in that file is
        # outside what a receipt from this suite proves.
        tests/evidence/*.json) return 0 ;;
    esac
    return 1
}

suite_image() { printf 'docker.io/library/rust:1-slim'; }

# What that image has to contain. maintainer-doctor runs the image and checks
# each of these resolves, because nothing else ties the image to what the suite
# runs inside it. sysknife's shell suite sat in bash:5 with no python3; when
# sysknife#386 made a test drive a python script the clean run began failing,
# no receipt was earnable, and the merge gate reported it as the pull request
# failing its own test rather than as itself being broken.
#
# cargo drives the tests; bash runs the command line this file builds.
suite_needs() { printf 'bash cargo rustc'; }

# The cargo cache is mounted with podman's :O overlay so writes stay in an
# overlay and never touch the host's ~/.cargo. docker has no equivalent, and
# mounting it writable there would let a contributor's build write to the real
# cache, so this suite says podman or nothing.
suite_requires() { [ "$1" = podman ]; }
suite_requires_name() { printf 'podman (for the :O overlay mount on ~/.cargo)'; }

# Files the sed mutation is applied to inside the extracted tree.
suite_mutate_glob() { printf '*.rs'; }

# Extra podman arguments. The cargo cache is mounted with :O so writes stay in
# an overlay and never reach the host's ~/.cargo.
suite_podman_args() {
    printf '%s\n' -v "$HOME/.cargo:/cargo:O" \
        -e CARGO_HOME=/cargo -e CARGO_TARGET_DIR=/repo/.container-target \
        -e CARGO_NET_OFFLINE=true
}

# $1 = the filter the caller passed.
#
# sysknife-shell is excluded. It is the Tauri app, its dependency tree reaches
# glib-sys, and rust:1-slim carries neither pkg-config nor glib, so a plain
# --workspace build dies in a build script before a single test runs:
#
#   The system library `glib-2.0` required by crate `glib-sys` was not found.
#   error: failed to run custom build command for `glib-sys v0.18.1`
#
# That is the third time this suite's image has been the thing that failed, and
# adding GTK to the image to compile a paused desktop app nobody is changing is
# the wrong trade. GUI development is paused and apps/sysknife-shell is out of
# scope for contributions; CI still builds it on a runner that has the
# libraries. A receipt from this suite says nothing about that crate.
#
# The cost is worth stating: sysknife-shell is the sole consumer of several
# items that look dead elsewhere in the workspace, so a pull request deleting
# one of them can earn a receipt here and still break that crate. CI catches it;
# the receipt does not. Read a deletion, do not merge it on the receipt alone.
suite_command() { printf 'cargo test --offline --workspace --exclude sysknife-shell %s\n' "$1"; }

# Print how many tests executed. Anything less than 1 refuses the receipt.
suite_ran() {  # $1 = the clean log
    awk '/^test result:/ { for (i=1;i<=NF;i++) if ($i=="passed;") s+=$(i-1) } END { print s+0 }' "$1"
}
