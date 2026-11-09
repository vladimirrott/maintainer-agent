# Differential recorder

Runs one set of scenarios against two trees (the bash tree today, a Rust tree later) and diffs the calls each program makes to every stub tool, exit code, stdout, stderr and the state tree.

    record.sh <tree> scenarios <out>     one result directory per scenario
    compare.sh <out-old> <out-new>       unified diff per scenario and field; exit 0 same, 1 differ, 2 harness error
    selftest.sh                          normaliser rules, compare exit codes, record guards, blind spots, determinism
    prove.sh <tree>                      detection mutants, the normaliser bite, and a mutant of every recorder guard

A scenario is one bash file in `scenarios/` with a shebang and no `. lib.sh` line. `record.sh` sources `lib.sh`, then the file, under `env -i`. The file builds stubs and state with the `mx_*` helpers and ends with exactly one `mx_run <program-in-tree> [args]`. PATH holds the stubs and symlinks to real tools only, so a tree may be bash or Rust.

Each result directory holds:

- `calls.log`: one line per call to any stub, stub name then argv, in call order across all stubs.
- `argv.<stub>.log`, `env.<stub>.log`, `stdin.<stub>.log`: one line per call to that stub. The env line lists `GH_HOST`, `GH_CONFIG_DIR`, `HOME`, `LC_ALL`, `LANG`, `TZ`, every `MAINTAINER_*` variable, and `GH_TOKEN` and `GITHUB_TOKEN` as `<set>` or `<unset>`. A `MAINTAINER_*` name containing KEY, TOKEN, SECRET or PASSWORD is logged the same way, never by value. The stdin line holds the bytes the program piped into the stub, which the stub then hands to its own body unchanged.
- `rc`, `stdout`, `stderr`, `state.tree` (one line per file: path, kind, mode, sha256 of the normalised content) and `state.files/` (the normalised text behind those hashes).

A log a stub never wrote is empty. `compare.sh` treats a field that one recording lacks and the other holds as a difference (exit 1, naming the field), never as an empty file.

At the top of the out directory `record.sh` writes `tree.abspath`: the distinct absolute paths to a stubbed tool (`/usr/bin/gh`, `/usr/local/bin/podman`, ...) found in the program text under `bin lib scripts platform profiles evals install.sh new-profile.sh`, scripts and compiled binaries alike. A program that runs `/usr/bin/gh` reaches the host's gh and no stub sees the call, so `compare.sh` holds `tree.abspath` equal across the two trees. The scan reads text, so a path assembled at run time is not found by it; the missing line in `calls.log` shows the effect of that case.

`normalise.py rules` lists every substitution with its reason, and `normalise.py selftest` runs the examples each rule must change and the text it must leave alone. The timestamp rule replaces only the digits: `2026-01-01T00:00:00Z` and `2026-01-01 00:00:00+00:00` stay different, and so do a fraction and its absence. The scenarios use fixed git dates, `TZ=UTC` and `LC_ALL=C`. A program that exits non-zero is data. A harness fault (a scenario with no program run, a tree modified by a run, an unfinished recording) exits 2. Environment: `MX_SCRATCH` moves the scratch base (default `~/.cache/magent-diff-scratch`, never /tmp), `MX_KEEP=1` keeps it, `MX_TIMEOUT` sets seconds per program (default 120).
