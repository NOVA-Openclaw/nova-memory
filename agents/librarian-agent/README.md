# Librarian Agent (Libby)

**Role:** Media Curation  
**Type:** Ephemeral (spawned on-demand)  
**Model:** claude-sonnet-4-20250514  
**Agent ID:** 7

## Purpose

Dedicated agent for ingesting, organizing, and storing media (podcasts, books, articles, videos) into searchable knowledge.

## Core Capabilities

| Capability | Description |
|------------|-------------|
| **Transcription** | Audio/video → text via Whisper API |
| **Text Extraction** | PDF, EPUB, web pages → structured text |
| **Summarization** | Three-tier summaries (one-liner, key points, full) |
| **Metadata Extraction** | Auto-detect title, creator, duration, topics |
| **Duplicate Detection** | Prevents re-processing same content |
| **Full-Text Search** | PostgreSQL tsvector search across all media |
| **Tag Generation** | Auto-generate relevant tags with confidence scores |

## Files

| File | Purpose |
|------|---------|
| `SOUL.md` | Agent personality and processing standards |
| `WORKFLOW.md` | Detailed processing pipeline documentation |
| `schema-additions.sql` | Database schema extensions (run once) |
| `insert-agent.sql` | Agent and SOP registration (run once) |

## Database Objects Created

### Tables Modified
- `media_consumed` — Added: summary, metadata, source_file, status, ingested_by, ingested_at, search_vector

### New Tables
- `media_queue` — Ingestion request queue
- `media_tags` — Topic tags for media items

### Views
- `v_media_queue_pending` — Pending queue items with requester info
- `v_media_with_tags` — Media records with aggregated tags

### Functions
- `search_media(query, limit)` — Full-text search across all media
- `update_media_search_vector()` — Trigger function for search indexing

### SOPs
- `librarian-agent-instantiation` — How to spawn Libby
- `media-transcription` — Audio/video transcription procedure
- `pdf-text-extraction` — PDF processing procedure

## Quick Start

### Ingest a single URL

```sql
-- Check for duplicates first
SELECT id, title FROM media_consumed WHERE url = 'https://example.com/podcast';

-- If not duplicate, spawn Libby
-- (via main agent)
```

```
"Hey NOVA, ingest this podcast: https://youtube.com/watch?v=abc123"
```

### Queue media for batch processing

```sql
INSERT INTO media_queue (url, media_type, requested_by)
VALUES (
    'https://youtube.com/watch?v=abc123',
    'podcast',
    (SELECT id FROM entities WHERE name = 'NOVA')
);
```

### Search ingested media

```sql
-- Full-text search
SELECT * FROM search_media('artificial intelligence');

-- By type
SELECT * FROM media_consumed WHERE media_type = 'podcast';

-- By tag
SELECT mc.* FROM media_consumed mc
JOIN media_tags mt ON mc.id = mt.media_id
WHERE mt.tag = 'technology';
```

## Instantiation Example

```python
# 1. Fetch agent config
agent = query("SELECT * FROM agents WHERE name = 'librarian-agent'")

# 2. Read seed context files
soul = read_file("~/clawd/nova-memory/agents/librarian-agent/SOUL.md")
workflow = read_file("~/clawd/nova-memory/agents/librarian-agent/WORKFLOW.md")

# 3. Check pending queue
pending = query("SELECT * FROM v_media_queue_pending LIMIT 5")

# 4. Spawn
sessions_spawn(
    task=f"{agent.seed_context.context_template}\n\n{soul}\n\n{workflow}\n\nTask: {user_request}",
    model="claude-sonnet-4-20250514",
    label="librarian:podcast-ingest",
    cleanup="delete"
)
```

## Integration with Other Agents

| Agent | Integration |
|-------|-------------|
| **Main (NOVA)** | Queues media, receives completion reports |
| **Research Agent** | Requests transcription, queries stored content |
| **NHR Agent** | Designed Libby's specification |

## Output Format

### Successful Ingestion
```
✅ Ingested: Episode 42: The Future of AI
📂 Type: podcast
👤 Creator: Tech Talk Podcast
⏱️ Duration: 45:32
🏷️ Topics: artificial-intelligence, technology, future-of-work
📝 Summary: A deep dive into how AI will reshape work...

Stored as media_consumed.id = 847
```

### Duplicate Detected
```
⏭️ Already ingested: Episode 42: The Future of AI
📂 Existing record: media_consumed.id = 847
📅 Ingested: 2026-02-01
```

### Error
```
❌ Failed to ingest: https://example.com/video
🔍 Reason: Video is geo-blocked
💡 Suggestion: Use VPN or provide local file
```

---

*Created by NHR Agent (Newhart) on 2026-02-05*
