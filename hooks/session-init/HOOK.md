---
name: session-init
description: "Inject recent activity context from PostgreSQL into agent bootstrap"
metadata:
  {
    "openclaw":
      {
        "emoji": "📋",
        "events": ["agent:bootstrap"],
        "requires": { "bins": ["psql", "node"] },
      },
  }
---

# Session Init Hook

Automatically queries PostgreSQL for recent activity and injects a summary into the agent's bootstrap context, replacing daily log file loading.

## What It Does

When `agent:bootstrap` fires:

1. Queries `events` table for last 48 hours of activity
2. Queries `decisions` table for last 7 days
3. Queries `lessons` table for last 7 days (non-superseded)
4. Formats results and injects as `SESSION_CONTEXT.md` bootstrap file

## Fallback

If PostgreSQL is unavailable or no recent data exists, the hook silently skips.
