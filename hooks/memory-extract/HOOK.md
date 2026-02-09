---
name: memory-extract
description: "Extract and store memories from assistant responses after each turn"
metadata:
  {
    "openclaw":
      {
        "emoji": "🧠",
        "events": ["message:sent"],
        "requires": { "bins": ["node"] },
      },
  }
---

# Memory Extraction Hook

Automatically extracts facts, events, decisions, and lessons from conversation turns and stores them in the PostgreSQL memory database via `memory-db` CLI.

## How It Works

When `message:sent` fires:

1. Reads the last few messages from the session transcript
2. Applies lightweight heuristics to detect extractable content (skips heartbeats, short messages, routine responses)
3. If heuristics pass, calls the Anthropic API (Claude Haiku) to parse structured memory entries
4. Shells out to `memory-db` CLI to store extracted facts, events, and lessons

## Safeguards

- **Cooldown:** Minimum 5 minutes between extractions per session
- **Heuristic gate:** LLM is only called when keywords/patterns suggest extractable content
- **Graceful failure:** All errors are caught and logged; never blocks message delivery
- **Skips:** Heartbeats, commands, short messages, isolated/spawn sessions
