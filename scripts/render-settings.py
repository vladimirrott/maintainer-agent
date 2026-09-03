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
import sys
from pathlib import Path

# Prefixes a shell can put in front of a verb and still run it.
PREFIXES = ("", "/bin/", "/usr/bin/", "/usr/local/bin/")
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


def wall(spec: dict, home: str) -> list[str]:
    rules: set[str] = set()
    for verb in spec.get("spelled_everywhere", []):
        for p in PREFIXES:
            rules.add(f"Bash({p}{verb}:*)")
    for verb in spec.get("bare", []):
        rules.add(f"Bash({verb}:*)")
    for verb in spec.get("bare_exact", []):
        rules.add(f"Bash({verb})")
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
    rehearsal = sorted(set(live) | {f"Bash({p}{v}:*)" for v in POSTING for p in PREFIXES})
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
            for p in PREFIXES:
                bash[f"{p}{verb}*"] = "deny"
        (pdir / "opencode-rehearsal.json").write_text(json.dumps(cfg, indent=1) + "\n")

    print(f"  {pdir.name}: {len(live)} deny rules, {len(rehearsal)} in rehearsal")


if __name__ == "__main__":
    main()
