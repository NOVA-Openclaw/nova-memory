# NOVA Memory Architecture

## Overview

NOVA uses a multi-layer memory system designed to handle different types of information with appropriate persistence and access patterns.

```
┌─────────────────────────────────────────────────────────────────┐
│                     MEMORY HIERARCHY                            │
├─────────────────────────────────────────────────────────────────┤
│  PERMANENT (PERMANENT.md)     │ Core context, refreshed every   │
│  - Critical facts             │ 30 min via cron. Never forget.  │
│  - Memory architecture        │                                 │
│  - SOPs reminder              │                                 │
├───────────────────────────────┼─────────────────────────────────┤
│  LONG-TERM (PostgreSQL)       │ Structured data, queryable,     │
│  - Entities & relationships   │ survives indefinitely.          │
│  - Events & timeline          │ PRIMARY source of truth.        │
│  - SOPs & procedures          │                                 │
│  - Lessons learned            │                                 │
│  - Vocabulary for STT         │                                 │
├───────────────────────────────┼─────────────────────────────────┤
│  SHORT-TERM (MEMORY.md)       │ Working notes, curated context. │
│  - Recent decisions           │ Migrated to DB over time.       │
│  - Active context             │                                 │
├───────────────────────────────┼─────────────────────────────────┤
│  DAILY (memory/YYYY-MM-DD.md) │ Raw session logs, scratch.      │
│  - Session notes              │ Reviewed and archived.          │
│  - Temporary context          │                                 │
├───────────────────────────────┼─────────────────────────────────┤
│  SEMANTIC (Clawdbot SQLite)   │ Embeddings for memory_search.   │
│  - Vector search over files   │ Auto-indexed by Clawdbot.       │
│  - Full-text search           │                                 │
└─────────────────────────────────────────────────────────────────┘
```

## PERMANENT Memory (PERMANENT.md)

**Purpose:** Core context that must never be forgotten, even after context compaction.

**Location:** `~/clawd/PERMANENT.md`

**Refresh:** Cron job every 30 minutes triggers a system event to re-read this file.

**Contents:**
- Memory architecture overview (PostgreSQL = primary, MEMORY.md = secondary)
- Reminder that SOPs table exists
- Critical entity IDs (I)ruid, NOVA)
- Key behaviors (database first, log events, check SOPs)

This prevents the failure mode where the AI "forgets" it has extended memory capabilities.

## Long-Term Memory (PostgreSQL)

**Database:** `nova_memory` on localhost

**Priority:** PRIMARY — always check database before flat files.

### Core Tables

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

### SOPs (Standard Operating Procedures)

The `sops` table stores documented procedures for recurring tasks.

```sql
SELECT name, description FROM sops;
SELECT * FROM sops WHERE name ILIKE '%keyword%';
```

Before performing any recurring task, check if an SOP exists.

### Vocabulary (STT Correction)

The `vocabulary` table helps speech-to-text correct unusual words.

```sql
-- Words with their misheard variants
SELECT word, misheard_as FROM vocabulary;
```

When the memory extraction pipeline finds new vocabulary, it adds them here and the STT service auto-restarts to load them.

## Short-Term Memory (MEMORY.md)

**Location:** `~/clawd/MEMORY.md`

**Purpose:** Curated working notes, active context.

**Lifecycle:** Information here should eventually migrate to the database.

Only loaded in main sessions (direct chats with the human). Not loaded in group chats or shared contexts for security.

## Daily Notes (memory/YYYY-MM-DD.md)

**Location:** `~/clawd/memory/YYYY-MM-DD.md`

**Purpose:** Raw session logs, scratch space.

**Lifecycle:** Reviewed periodically, significant items extracted to database, then archived.

## Semantic Memory (Clawdbot SQLite)

**Location:** `~/.clawdbot/memory/main.sqlite`

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
```

## Key Principles

1. **Database first** — PostgreSQL is the source of truth
2. **SOPs exist** — Check before improvising recurring tasks  
3. **PERMANENT refreshes** — Core context reloads every 30 min
4. **Log important events** — Use `events` table, not just markdown
5. **Vocabulary grows** — New words auto-extracted and loaded to STT
