---
name: memory-extract
description: "Extracts memories from incoming messages and stores in database"
metadata: {"clawdbot":{"emoji":"🧠","events":["message:received"]}}
---

# Memory Extraction Hook

Automatically extracts entities, facts, opinions, and relationships from incoming messages 
and stores them in the PostgreSQL memory database.

## Requirements
- Anthropic API key in `~/.secrets/anthropic-api-key`
- PostgreSQL database `nova_memory` with schema from `schema.sql`
- Scripts in `~/clawd/scripts/` (process-input.sh, extract-memories.sh, store-memories.sh)
