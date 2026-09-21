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
# CARGO_BUILD_JOBS is bounded on purpose. Unbounded, cargo takes one rustc per
# core, each holding around a gigabyte while it links, and two verify runs of
# this workspace on one 16-core host put it far enough into swap that the
# supervisor killed both mid-build. A verify that takes the machine down with it
# proves nothing and costs the whole run. Raise it with MAINTAINER_CARGO_JOBS on
# a bigger machine; CI is unaffected, this is the local gate only.
#
# $2 is the extracted tree on the host, and it carries the overlay's upperdir.
# Without one, podman discards the overlay when the container exits, so a crate
# downloaded by the fetch below is gone by the time the offline run wants it.
# With one, the host's ~/.cargo stays the read-only lower layer, every newly
# downloaded crate lands under the extracted tree, and the whole thing is
# deleted with that tree when the verify ends.
suite_podman_args() {  # $1 = the container runtime, $2 = the extracted tree
    local ovl="$HOME/.cargo:/cargo:O" work="${2:-}"
    if [ -n "$work" ]; then
        mkdir -p "$work/.cargo-upper" "$work/.cargo-work"
        ovl="$ovl,upperdir=$work/.cargo-upper,workdir=$work/.cargo-work"
    fi
    printf '%s\n' -v "$ovl" \
        -e CARGO_HOME=/cargo -e CARGO_TARGET_DIR=/repo/.container-target \
        -e CARGO_NET_OFFLINE=true \
        -e "CARGO_BUILD_JOBS=${MAINTAINER_CARGO_JOBS:-4}"
}

# A dependency bump is a version the host cache does not hold, so `cargo test
# --offline` died on it and no dependabot pull request could earn a receipt at
# all: #437, #438 and #439 each sat six days on that. Populating the host cache
# was the obvious fix and the wrong one, because `maintainer screen 438` names
# running the pull request's manifests against the real ~/.cargo as the risk.
#
# What makes fetching in a container acceptable is what `cargo fetch` does not
# do. It compiles nothing, so no build script from the pull request runs.
# --locked refuses to resolve anything the committed lockfile does not already
# pin, so it downloads what the reviewed diff says and not a resolution of its
# own. CARGO_NET_OFFLINE is overridden here and only here; the run that
# executes the tests still has --network=none.
suite_prefetch_command() { printf 'CARGO_NET_OFFLINE=false cargo fetch --locked\n'; }

# Runs on the host, before the fetch container is given a network.
#
# Cargo.lock lists every source a fetch can reach, so it is the whole question:
# a pull request that adds a git dependency or an alternate registry would
# otherwise point a networked container at a host of its choosing. sysknife's
# lockfile names one source across 657 packages.
suite_prefetch_guard() {  # $1 = the extracted tree
    local lock="$1/Cargo.lock" srcs offenders="" line
    if [ ! -f "$lock" ]; then
        printf 'no Cargo.lock in the extracted tree, so nothing pins what a fetch would download\n'
        return 1
    fi
    # Captured first, then inspected. A pipeline ending in grep reports the
    # grep, and "no offending source" and "the file could not be read" then
    # look identical.
    srcs="$(grep -h '^source = ' "$lock" 2>/dev/null | sort -u)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            'source = "registry+https://github.com/rust-lang/crates.io-index"') ;;
            *) offenders="$offenders  $line"$'\n' ;;
        esac
    done <<<"$srcs"
    if [ -n "$offenders" ]; then
        printf 'the lockfile names a source that is not crates.io, and the fetch has network:\n%s' "$offenders"
        return 1
    fi
    return 0
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
