#!/usr/bin/env python3
"""Generate a profile's deny walls from its deny.json.

    render-settings.py <profile-dir> <home>

Writes, beside deny.json:
    settings.json             the live wall
    settings-rehearsal.json   the live wall plus every verb that writes to GitHub
    opencode-rehearsal.json   the same, for the opencode backend (if configured)

Generated rather than hand-written for one measured reason. The wall was once
40 hand-listed rules, and `/usr/bin/touch /tmp/mt-y` succeeded against a rule
denying `touch /tmp/mt-y`, because the matcher keys on the command as written.
Every absolute spelling had to be added by hand, one line at a time, and the
next verb someone adds would have the same hole. Here a verb is written once
and comes out spelled four ways.

The bound is stated honestly and does not move: enumeration cannot be complete,
so this stops a cooperative agent from reaching a destructive verb by accident
or by being talked into it. It does not contain a hostile one.

Two things that look like typos and are not:

  * `Read(~/x)` is the documented home-relative form and is measured to deny.
    A single leading slash anchors to the SETTINGS directory, not the
    filesystem root, so `Read(/home/you/.ssh/**)` would deny nothing at all.
  * The same credential path is denied to `cat` three ways (`~/`, `$HOME/`,
    and expanded). One string per spelling is the whole point.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

# Directories a verb can be spelled from.
#
# This was three FHS paths until a run against this repository probed the wall
# against where the binaries actually live. On that machine `cargo` was in
# ~/.cargo/bin, `npm` under ~/.local/lib/nodejs/.../bin, and `maintainer-merge`
# in ~/.local/bin. None had an absolute-path rule, so the single rule protecting
# the merge gate's receipt was bypassable by writing the full path, and the two
# publishing verbs had no absolute form at all.
#
# /opt/homebrew/bin earns its place on Apple Silicon: Homebrew puts `gh` there,
# and without it a POST=off rehearsal on a Mac would not block posting.
STATIC_DIRS = ("", "/bin/", "/usr/bin/", "/usr/local/bin/", "/usr/local/sbin/",
               "/opt/homebrew/bin/", "/snap/bin/")
# Under the home directory, spelled the three ways a shell accepts.
HOME_DIRS = (".local/bin/", "bin/", ".cargo/bin/", "go/bin/",
             ".npm-global/bin/", ".local/share/npm/bin/")
# Commands that read a file's bytes. Not exhaustive, and not claimed to be.
READERS = ("cat", "head", "tail")
# Every verb that can reach a human. Rehearsal denies these on top of the wall.
POSTING = (
    "gh pr review", "gh pr comment", "gh pr edit", "gh pr close", "gh pr reopen",
    "gh pr ready", "gh issue comment", "gh issue create", "gh issue edit",
    "gh issue close", "gh issue reopen", "gh issue develop", "gh issue pin",
    "gh issue transfer", "gh label", "gh api --method POST", "gh api -X POST",
    "gh api --method PATCH", "gh api -X PATCH",
    "maintainer-merge merge", "maintainer-merge verify",
)


def prefixes(home: str, verbs) -> list[str]:
    """Every prefix a verb might be written with on THIS machine.

    The static list, plus the directory each verb's binary actually resolves to,
    both as PATH found it and as the symlink points. Enumeration is still
    incomplete and the README says so; missing the directory a tool is installed
    in is not an edge case, it is the main case.
    """
    home = home.rstrip("/")
    out = set(STATIC_DIRS)
    for d in HOME_DIRS:
        out.update((f"{home}/{d}", f"~/{d}", f"$HOME/{d}"))
    for verb in verbs:
        real = shutil.which(verb.split()[0])
        if not real:
            continue
        for d in {os.path.dirname(real) + "/", os.path.dirname(os.path.realpath(real)) + "/"}:
            out.add(d)
            if d.startswith(home + "/"):
                rest = d[len(home) + 1:]
                out.update((f"~/{rest}", f"$HOME/{rest}"))
    return sorted(out)


def wall(spec: dict, home: str) -> list[str]:
    rules: set[str] = set()
    # One list. There used to be a `spelled_everywhere` set and a `bare` set,
    # with no written rule for which verb went where, and the bare ones got a
    # single spelling. `gh repo delete`, `gh repo edit`, `gh secret` and
    # `gh pr create` were all bare, and the preamble promises the agent cannot
    # delete anything, change repository settings, or open a pull request
    # elsewhere. Those promises rested on rules that `/usr/bin/gh repo delete`
    # walks straight past. `bare` is still read for older profiles.
    verbs = list(spec.get("spelled_everywhere", [])) + list(spec.get("bare", []))
    pref = prefixes(home, verbs)
    for verb in verbs:
        for p in pref:
            rules.add(f"Bash({p}{verb}:*)")
    for verb in spec.get("bare_exact", []):
        for p in pref:
            rules.add(f"Bash({p}{verb})")
    for path in spec.get("credential_paths", []):
        rules.add(f"Read({path})")
        tail = path[2:]                      # strip the leading "~/"
        for reader in READERS:
            for form in (f"~/{tail}", f"$HOME/{tail}", f"{home}/{tail}"):
                rules.add(f"Bash({reader} {form})")
    return sorted(rules)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    pdir, home = Path(sys.argv[1]), sys.argv[2].rstrip("/")
    spec_file = pdir / "deny.json"
    if not spec_file.exists():
        raise SystemExit(f"render-settings: no deny.json in {pdir}")
    spec = json.loads(spec_file.read_text())

    live = wall(spec, home)
    # The gate's own tool must be unreachable by every spelling, or the receipt
    # it protects is a formality. maintainer-merge lives in ~/.local/bin.
    if "maintainer-merge receipt" in json.dumps(spec):
        # `which` returns None on a first install, before the tool is on PATH,
        # so keying the check on it made the guard inert exactly when the wall
        # is first written. Check the directory install.sh deploys into, which
        # is known regardless, and the resolved one when there is one.
        wanted = {f"Bash({home.rstrip('/')}/.local/bin/maintainer-merge receipt:*)"}
        found = shutil.which("maintainer-merge")
        if found:
            wanted.add(f"Bash({os.path.dirname(found)}/maintainer-merge receipt:*)")
        missing = sorted(w for w in wanted if w not in live)
        if missing:
            raise SystemExit("render-settings: the receipt can be forged by writing "
                             "the full path; missing " + ", ".join(missing))
    if not any(r.startswith("Read(~/") for r in live):
        raise SystemExit("render-settings: no credential path is denied; refusing to "
                         "write a wall that protects nothing")
    if home in json.dumps(spec):
        raise SystemExit("render-settings: deny.json contains a literal home path; "
                         "use ~/ so nothing personal is committed")

    def write(name: str, deny: list[str]) -> None:
        (pdir / name).write_text(json.dumps(
            {"permissions": {"deny": deny}, "enableAllProjectMcpServers": False},
            indent=1, sort_keys=True) + "\n")

    write("settings.json", live)
    post_pref = prefixes(home, POSTING)
    rehearsal = sorted(set(live) | {f"Bash({p}{v}:*)" for v in POSTING for p in post_pref})
    if len(rehearsal) <= len(live):
        raise SystemExit("render-settings: the rehearsal wall added nothing")
    write("settings-rehearsal.json", rehearsal)

    oc = pdir / "opencode.json"
    if oc.exists():
        cfg = json.loads(oc.read_text())
        bash = cfg.setdefault("permission", {}).setdefault("bash", {})
        # Appended last on purpose: opencode evaluates last-match-wins, so a
        # deny added at the end sits on top of any broad allow above it.
        for verb in POSTING:
            for p in post_pref:
                bash[f"{p}{verb}*"] = "deny"
        (pdir / "opencode-rehearsal.json").write_text(json.dumps(cfg, indent=1) + "\n")

    # Cursor takes the same shape under a different name, and CURSOR_CONFIG_DIR
    # points it at a directory of our choosing, which is what makes a
    # per-profile wall possible at all.
    #
    # lib/backends/cursor.sh used to say Cursor has "no per-command deny list",
    # so the backend was restricted to read-only tasks on that premise. The
    # documented configuration has carried `permissions.allow` and
    # `permissions.deny` with Shell(), Read() and Write() patterns for some
    # time. The claim was stale, and a stale claim about containment makes a
    # tool less capable than it is while reading like caution.
    cur = pdir / "cursor"
    cur.mkdir(exist_ok=True)
    def cursor_cfg(verbs):
        return {
            "version": 1,
            "permissions": {
                "allow": [],
                # Shell(<verb>) matches the base command; the args form is
                # Shell(cmd:*). Both are emitted, for the same reason the Claude
                # wall spells every install directory: one spelling is not a wall.
                # The bare form only for a single-word verb. `Shell(git)` denies
                # EVERY git, including the `git log` and `git diff` a review is
                # made of, so deriving it from "git push" would ship a wall that
                # blocks the work rather than the damage. Caught by reading the
                # rendered file rather than by trusting the generator.
                "deny": sorted(
                    {f"Shell({v})" for v in verbs if " " not in v}
                    | {f"Shell({v}:*)" for v in verbs}
                    | {f"Read({c})" for c in spec.get("credential_paths", [])}
                    | {f"Write({c})" for c in spec.get("credential_paths", [])}),
            },
        }
    verbs = spec.get("spelled_everywhere", []) + spec.get("bare_exact", [])
    (cur / "cli-config.json").write_text(json.dumps(cursor_cfg(verbs), indent=1) + "\n")
    (pdir / "cursor-rehearsal").mkdir(exist_ok=True)
    (pdir / "cursor-rehearsal" / "cli-config.json").write_text(
        json.dumps(cursor_cfg(verbs + list(POSTING)), indent=1) + "\n")

    print(f"  {pdir.name}: {len(live)} deny rules, {len(rehearsal)} in rehearsal")


if __name__ == "__main__":
    main()
