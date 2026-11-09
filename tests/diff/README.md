# Differential recorder

Runs one set of scenarios against two trees (the bash tree today, a Rust tree later) and diffs argv per stub tool, exit code, stdout, stderr and the state tree.

    record.sh <tree> scenarios <out>     one result directory per scenario
    compare.sh <out-old> <out-new>       unified diff per scenario and field; exit 0 same, 1 differ, 2 harness error
    selftest.sh                          normaliser rules, compare exit codes, record guards, determinism
    prove.sh <tree>                      four detection mutants and the normaliser bite

A scenario is one bash file in `scenarios/` with a shebang and no `. lib.sh` line. `record.sh` sources `lib.sh`, then the file, under `env -i`. The file builds stubs and state with the `mx_*` helpers and ends with exactly one `mx_run <program-in-tree> [args]`. PATH holds the stubs and symlinks to real tools only, so a tree may be bash or Rust.

Each result directory holds `argv.<stub>.log`, `rc`, `stdout`, `stderr`, `state.tree` (one line per file: path, kind, mode, sha256 of the normalised content) and `state.files/` (the normalised text behind those hashes).

`normalise.py rules` lists every substitution with its reason, and `normalise.py selftest` runs the examples each rule must change and the text it must leave alone. The scenarios use fixed git dates, `TZ=UTC` and `LC_ALL=C`. A program that exits non-zero is data. A harness fault (a scenario with no program run, a tree modified by a run, an unfinished recording) exits 2. Environment: `MX_SCRATCH` moves the scratch base (default `~/.cache/magent-diff-scratch`, never /tmp), `MX_KEEP=1` keeps it, `MX_TIMEOUT` sets seconds per program (default 120).
