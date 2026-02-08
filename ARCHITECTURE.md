# NOVA Memory Architecture

## Overview

NOVA uses a multi-layer memory system designed to handle different types of information with appropriate persistence and access patterns.

```
┌─────────────────────────────────────────────────────────────────┐
│                     MEMORY HIERARCHY                            │
├─────────────────────────────────────────────────────────────────┤
│  LONG-TERM (PostgreSQL)       │ Structured data, queryable,     │
│  - Entities & relationships   │ survives indefinitely.          │
│  - Events & timeline          │ PRIMARY source of truth.        │
│  - SOPs & procedures          │                                 │
│  - Lessons learned            │                                 │
│  - Vocabulary for STT         │                                 │
├───────────────────────────────┼─────────────────────────────────┤
│  SHORT-TERM (MEMORY.md)       │ Working notes loaded every turn │
│  - Quick reference            │ Behavioral reminders included.  │
│  - Active context             │ Keep lean (~2-3KB).             │
│  - Key preferences            │                                 │
├───────────────────────────────┼─────────────────────────────────┤
│  DAILY (memory/YYYY-MM-DD.md) │ Raw session logs, scratch.      │
│  - Session notes              │ Reviewed and archived.          │
│  - Temporary context          │                                 │
├───────────────────────────────┼─────────────────────────────────┤
│  PERIODIC (REMINDERS.md)      │ Actions executed every 30 min   │
│  - Scan 1Password vault       │ via cron. Keeps memory fresh.   │
│  - Check SOPs from database   │                                 │
│  - Review pending tasks       │                                 │
├───────────────────────────────┼─────────────────────────────────┤
│  SEMANTIC (Clawdbot SQLite)   │ Embeddings for memory_search.   │
│  - Vector search over files   │ Auto-indexed by Clawdbot.       │
│  - Full-text search           │                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Memory Tiers Explained

### 1. Long-Term Memory (PostgreSQL) — PRIMARY

**Database:** `nova_memory` on localhost

**Priority:** ALWAYS check database first before flat files.

This is the source of truth for persistent information.

#### Core Tables

| Table | Purpose |
|-------|---------|
| `entities` | People, AIs, organizations — things with agency |
| `entity_facts` | Key-value facts about entities |
| `entity_relationships` | Connections between entities |
| `places` | Locations, networks, venues |
| `projects` | Active efforts with goals |
| `tasks` | Actionable items linked to projects |
| `events` | Timeline of what happened |
| `lessons` | Things learned from experience |
| `sops` | Standard Operating Procedures |
| `vocabulary` | Words for STT correction |
| `preferences` | User and system preferences |

#### SOPs (Standard Operating Procedures)

The `sops` table stores documented procedures for recurring tasks.

```sql
SELECT name, description FROM sops;
SELECT * FROM sops WHERE name ILIKE '%keyword%';
```

Before performing any recurring task, check if an SOP exists.

### 2. Short-Term Memory (MEMORY.md) — Every Turn

**Location:** `~/clawd/MEMORY.md` (workspace root)

**Purpose:** Quick-reference context and behavioral reminders.

**How it works:** Clawdbot automatically loads workspace files (MEMORY.md, AGENTS.md, etc.) into the system prompt at the start of every turn. This survives context compaction because it's re-read from disk each time.

**Contents should include:**
- Key entity IDs (e.g., I)ruid = Entity 2)
- Important behaviors ("database first", "check SOPs")
- Account/service quick reference
- Active project status
- Communication preferences

**Keep it lean** — this loads every turn, so ~2-3KB is ideal.

**Security:** Only loaded in main sessions (direct chats). Not loaded in group chats or shared contexts.

### 3. Daily Notes (memory/YYYY-MM-DD.md)

**Location:** `~/clawd/memory/YYYY-MM-DD.md`

**Purpose:** Raw session logs and scratch space.

**Lifecycle:** 
1. Log notable events during the day
2. Review periodically
3. Extract significant items to database
4. Archive old daily files

### 4. Periodic Reminders (REMINDERS.md) — Every 30 Minutes

**Location:** `~/clawd/REMINDERS.md`

**Purpose:** Actions to EXECUTE periodically, not just read.

**How it works:** A cron job fires every 30 minutes, sending a system event that tells the agent to read REMINDERS.md and execute the listed actions.

**Typical actions:**
- Scan 1Password vault (`op item list`) to remember available accounts
- Query SOPs from database to refresh procedural knowledge
- Check pending tasks to stay on track

See `REMINDERS.md` in this repo for the template.

### 5. Semantic Memory (Clawdbot SQLite)

**Location:** `~/.openclaw/memory/main.sqlite`

**Purpose:** Powers the `memory_search` tool.

Clawdbot automatically indexes workspace markdown files and stores embeddings for semantic search. This is separate from the PostgreSQL long-term memory.

## Memory Extraction Pipeline

A cron job runs every minute to extract memories from chat:

```
Chat transcript → memory-catchup.sh (every 1 min)
               → extract-memories.sh (Claude extracts 8 categories)
               → store-memories.sh (inserts to PostgreSQL)
               → New vocabulary? → STT service restarts
```

### Extraction Categories

1. **entities** — People, AIs, organizations
2. **places** — Locations, venues
3. **facts** — Objective information
4. **opinions** — Subjective views (with holder)
5. **preferences** — Likes/dislikes
6. **events** — Things that happened
7. **relationships** — Connections
8. **vocabulary** — Words for STT

## Data Flow

```
User speaks → STT (Whisper + vocabulary corrections)
           → Chat → Response
           → Memory extraction (async, 1/min)
           → PostgreSQL

Query needed → Check PostgreSQL first
            → Then MEMORY.md
            → Then memory_search (semantic)

Every 30 min → Cron fires
            → Read REMINDERS.md
            → Execute scans (1Password, SOPs, tasks)
            → Log findings to daily notes
```

## Key Principles

1. **Database first** — PostgreSQL is the source of truth
2. **SOPs exist** — Check `sops` table before improvising recurring tasks
3. **MEMORY.md is lean** — Quick reference only, loaded every turn
4. **REMINDERS.md is active** — Execute actions, don't just read
5. **Log important events** — Use `events` table, not just markdown
6. **Vocabulary grows** — New words auto-extracted and loaded to STT

## Modifications from Default Clawdbot

This setup extends the default Clawdbot memory with:

1. **PostgreSQL database** — Structured long-term storage (entities, events, SOPs, etc.)
2. **Memory extraction pipeline** — Auto-extracts memories from chat every minute
3. **REMINDERS.md + cron** — Periodic active scans to refresh memory
4. **Vocabulary table** — STT correction words, auto-loaded on restart

The default Clawdbot provides:
- MEMORY.md/AGENTS.md workspace file injection
- Semantic memory search via SQLite embeddings
- Heartbeat system for periodic check-ins
