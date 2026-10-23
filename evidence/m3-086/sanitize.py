"""Keeps of a Claude Code subagent transcript (JSONL) the run's own
exchange: the author's prompt, each assistant message (text, thinking text,
tool calls) and each tool result, with their timestamps and working
directory. It drops what the harness attached (account, organization,
system prompt, tool and skill listings, model) and per-entry metadata.

    python3 -I sanitize.py IN.jsonl OUT.jsonl
"""
import json
import sys

KEEP = ("type", "uuid", "parentUuid", "timestamp", "cwd")

with open(sys.argv[1]) as src, open(sys.argv[2], "w") as out:
    for line in src:
        e = json.loads(line)
        if e.get("type") not in ("user", "assistant"):
            continue
        kept = {k: e[k] for k in KEEP if k in e}
        msg = e.get("message", {})
        content = msg.get("content")
        if isinstance(content, list):
            content = [{k: v for k, v in c.items() if k != "signature"} if isinstance(c, dict) else c
                       for c in content]
        kept["message"] = {"role": msg.get("role"), "content": content}
        if "toolUseResult" in e:
            pass  # the same result is in message.content
        out.write(json.dumps(kept, ensure_ascii=False) + "\n")
