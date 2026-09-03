#!/usr/bin/env python3
"""Turn a Claude Code stream-json run into a readable log and a command list.

    claude -p --output-format stream-json --verbose ... | transcript.py LOG COMMANDS

Why this exists: the audit trail used to record what the agent SAID it did.
On 2026-09-03 a run report read

    sysknife-maint screen 348 -> DO NOT EXECUTE

for a command that is not installed under that name. Whether the agent ran the
real one and mistyped the report, or ran nothing at all, the trail could not
say. A report is a claim; this file is the record.

Defensive by construction. Any line that is not JSON, and any shape that is not
recognised, is passed through verbatim: losing a run's output to a parser bug
would be a worse failure than the one this fixes.
"""
from __future__ import annotations

import json
import sys


def summarise(block: dict) -> str:
    name = block.get("name", "?")
    args = block.get("input", {}) or {}
    if name == "Bash":
        return f"$ {args.get('command', '').strip()}"
    for key in ("file_path", "path", "pattern", "url", "prompt"):
        if key in args:
            return f"{name}: {args[key]}"
    return name


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    log = open(sys.argv[1], "a", buffering=1)
    cmds = open(sys.argv[2], "a", buffering=1)
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            log.write(line + "\n")
            continue
        try:
            kind = ev.get("type")
            if kind == "assistant":
                for block in ev.get("message", {}).get("content", []):
                    if block.get("type") == "text" and block.get("text", "").strip():
                        log.write(block["text"] + "\n")
                    elif block.get("type") == "tool_use":
                        cmds.write(summarise(block) + "\n")
            elif kind == "result":
                log.write("\n=== result ===\n")
                log.write(str(ev.get("result", "")) + "\n")
                usage = ev.get("usage") or {}
                if usage:
                    log.write(f"[tokens in={usage.get('input_tokens')} "
                              f"out={usage.get('output_tokens')} "
                              f"cost_usd={ev.get('total_cost_usd')}]\n")
        except Exception as exc:  # noqa: BLE001 - never lose output to a parse bug
            log.write(f"[transcript.py could not read an event: {exc}]\n{line}\n")
    log.close()
    cmds.close()


if __name__ == "__main__":
    main()
