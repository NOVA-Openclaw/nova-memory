---
name: session-init
description: "Generate privacy-filtered context when session starts"
metadata:
  {
    "clawdbot":
      {
        "emoji": "🔐",
        "events": ["message:received"],
      },
  }
---

# Session Init Hook

Generates privacy-filtered context based on session participants.

## What It Does

When a message is received:
1. Checks if session context file is stale (>5 min old or participants changed)
2. Resolves participant phone numbers to entity IDs
3. Queries entity_facts with privacy filtering
4. Writes filtered context to `~/clawd/SESSION_CONTEXT.md`

## Privacy Filtering

Only includes facts where:
- `visibility = 'public'`, OR
- `source_entity_id` matches a participant (their own data), OR
- `privacy_scope` includes a participant (explicitly shared)

## Output

`SESSION_CONTEXT.md` contains:
- Participant names and entity IDs
- Privacy-filtered facts from database
- Timestamp for staleness checking
