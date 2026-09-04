#!/usr/bin/env python3
"""Turn a Claude Code stream-json run into a readable log and a command list.

    claude -p --output-format stream-json --verbose ... | transcript.py LOG COMMANDS

It also writes LOG-without-.log + `.usage.json`: what the run actually spent.

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
import pathlib
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


# What a run spent, recorded rather than estimated.
#
# The first version of this logged `in=<input_tokens> out=<output_tokens>` and
# nothing else, which is how a full sysknife review came to be recorded as
# "in=48". Almost every input token in an agent run is a cache read or a cache
# write, and both are separate fields:
#
#   input_tokens                  uncached input, full price
#   cache_creation_input_tokens   written to the cache, charged ABOVE input
#   cache_read_input_tokens       served from cache, charged BELOW input
#
# So `in=48` was true and useless. Reporting it as the run's input was worse
# than reporting nothing, because it read as a measurement.
#
# Three more things the API docs are explicit about, each of which this gets
# wrong if taken naively:
#
#  - `usage` EXCLUDES subagent tokens. `total_cost_usd` and `modelUsage`
#    include them. So the per-model map is the honest token total whenever the
#    run spawned anything, and `usage` is the main loop only.
#  - `total_cost_usd` is a CLIENT-SIDE ESTIMATE from a price table bundled with
#    the CLI, not billing truth. It drifts when prices change or the CLI does
#    not recognise a model. Every surface that prints it says so.
#  - An error result carries usage too, and a crash (`error_during_execution`)
#    may carry it zeroed. A failed run that spent four dollars must not be
#    recorded as having spent nothing, so the subtype is kept.
#
# Not tiktoken. It is OpenAI's tokenizer, it undercounts Claude by 15-20% on
# prose and by more on code, and Anthropic publishes none. Counting is the wrong
# move regardless: the exact billed figures are already in this stream.
def record_usage(ev: dict, log) -> None:
    usage = ev.get("usage") or {}
    models = ev.get("modelUsage") or ev.get("model_usage") or {}
    rec = {
        "subtype": ev.get("subtype"),
        "is_error": bool(ev.get("is_error")),
        "duration_ms": ev.get("duration_ms"),
        "duration_api_ms": ev.get("duration_api_ms"),
        "num_turns": ev.get("num_turns"),
        "cost_usd_estimate": ev.get("total_cost_usd"),
        "session_id": ev.get("session_id"),
        # Main loop only. Subagents are not in here; see modelUsage below.
        "main_loop": {
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0),
            "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
        },
        "by_model": {},
    }
    for name, mu in (models.items() if isinstance(models, dict) else []):
        if not isinstance(mu, dict):
            continue
        # The CLI uses camelCase here and snake_case in `usage`. Accept both
        # rather than depending on which one this version emits.
        pick = lambda *k: next((mu[x] for x in k if x in mu), 0)  # noqa: E731
        rec["by_model"][name] = {
            "input_tokens": pick("inputTokens", "input_tokens"),
            "output_tokens": pick("outputTokens", "output_tokens"),
            "cache_creation_input_tokens": pick("cacheCreationInputTokens",
                                                "cache_creation_input_tokens"),
            "cache_read_input_tokens": pick("cacheReadInputTokens",
                                            "cache_read_input_tokens"),
            "cost_usd_estimate": pick("costUSD", "cost_usd"),
        }
    src = rec["by_model"] or {"(main loop only)": rec["main_loop"]}
    tot = {k: sum(m.get(k, 0) for m in src.values())
           for k in ("input_tokens", "output_tokens",
                     "cache_creation_input_tokens", "cache_read_input_tokens")}
    rec["totals"] = tot
    rec["totals"]["billable_input_tokens"] = (
        tot["input_tokens"] + tot["cache_creation_input_tokens"] + tot["cache_read_input_tokens"])

    log.write(
        "[usage] in={i} cache_write={w} cache_read={r} out={o} "
        "turns={t} cost~${c} ({sub})\n".format(
            i=tot["input_tokens"], w=tot["cache_creation_input_tokens"],
            r=tot["cache_read_input_tokens"], o=tot["output_tokens"],
            t=rec["num_turns"],
            c=("%.2f" % rec["cost_usd_estimate"]) if isinstance(
                rec["cost_usd_estimate"], (int, float)) else "?",
            sub=rec["subtype"] or "?"))

    # Beside the log, machine-readable, so `maintainer finish` can put it in the
    # report and `maintainer status` can add it up without parsing prose.
    out = pathlib.Path(sys.argv[1])
    out = out.with_suffix("") if out.suffix == ".log" else out
    try:
        (out.parent / (out.name + ".usage.json")).write_text(
            json.dumps(rec, indent=2) + "\n")
    except OSError as exc:  # a run must not die because its receipt file did
        log.write(f"[usage] could not write the usage file: {exc}\n")


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
                record_usage(ev, log)
        except Exception as exc:  # noqa: BLE001 - never lose output to a parse bug
            log.write(f"[transcript.py could not read an event: {exc}]\n{line}\n")
    log.close()
    cmds.close()


if __name__ == "__main__":
    main()
