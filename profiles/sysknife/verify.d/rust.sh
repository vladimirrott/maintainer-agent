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
    esac
    return 1
}

suite_image() { printf 'docker.io/library/rust:1-slim'; }

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
suite_command() { printf 'cargo test --offline %s\n' "$1"; }

# Print how many tests executed. Anything less than 1 refuses the receipt.
suite_ran() {  # $1 = the clean log
    awk '/^test result:/ { for (i=1;i<=NF;i++) if ($i=="passed;") s+=$(i-1) } END { print s+0 }' "$1"
}
