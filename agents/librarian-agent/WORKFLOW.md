# Librarian Agent Workflow Documentation

## Overview

The Librarian Agent (Libby) is an **ephemeral** agent that processes media ingestion requests on-demand. It accepts URLs or files, extracts content, generates metadata and summaries, and stores everything in the `nova_memory` database.

## Agent Instantiation

### When to Spawn Libby

- User shares a podcast/video/article to ingest
- Batch processing of saved links
- Processing items from `media_queue`
- Research agent needs media transcribed

### How to Spawn

```sql
-- 1. Fetch agent config
SELECT * FROM agents WHERE name = 'librarian-agent';

-- 2. Spawn with task
sessions_spawn(
    task="<seed_context>\n\nIngest this media: {url_or_file}",
    model="claude-sonnet-4-20250514",
    label="librarian:{media_title_slug}",
    cleanup="delete"
)
```

## Processing Pipeline

### Step 1: Accept Input

**Input Types:**
- URL (YouTube, podcast RSS, article, etc.)
- File path (local audio/video/PDF)
- Media queue ID

```
Input: "https://www.youtube.com/watch?v=xyz123"
or
Input: "/home/nova/Downloads/podcast-episode.mp3"
or
Input: "Process queue item #42"
```

### Step 2: Duplicate Detection

**Before any processing:**

```sql
-- Check URL match
SELECT id, title, media_type 
FROM media_consumed 
WHERE url = '{input_url}';

-- Check title+creator fuzzy match (if metadata available)
SELECT id, title, creator 
FROM media_consumed 
WHERE LOWER(title) LIKE LOWER('%{title}%')
  AND LOWER(creator) LIKE LOWER('%{creator}%');
```

**If duplicate found:**
- Return existing record details
- Log duplicate detection in `agent_actions`
- Skip processing
- Report: "Already ingested: {title} (id={id})"

### Step 3: Media Type Detection

**Auto-detection logic:**

| URL Pattern / File Type | Detected Type |
|-------------------------|---------------|
| youtube.com, vimeo.com, .mp4, .mkv | video |
| spotify.com, podcasts.apple.com, .mp3, .m4a, podcast RSS | podcast |
| .pdf, .epub, goodreads.com, amazon.com/dp/ | book |
| medium.com, substack.com, news sites | article |
| arxiv.org, .edu domains, DOI links | paper |
| Other webpages | webpage |

### Step 4: Content Extraction

#### For Audio/Video (Podcast, Video)

1. **Download** (if URL):
   ```bash
   yt-dlp -x --audio-format mp3 -o "/tmp/media/{id}.%(ext)s" "{url}"
   ```

2. **Check file size**:
   - If < 25MB: Process directly
   - If >= 25MB: Chunk into segments

3. **Transcribe** (Whisper API):
   ```python
   # Via Clawdbot skill or direct API
   whisper_transcribe(file_path, model="whisper-1")
   ```

4. **Handle timestamps**:
   - Include timestamps every 30-60 seconds
   - Format: `[00:15:32] Speaker continues...`

#### For Documents (Book, Paper)

1. **PDF Extraction**:
   ```bash
   pdftotext -layout "{file}" -
   # or use Python pdfplumber for better structure
   ```

2. **EPUB Extraction**:
   ```python
   # Parse chapters, preserve structure
   ```

3. **Handle scanned PDFs**:
   - Detect image-only pages
   - Use OCR (tesseract) if needed

#### For Web Content (Article, Webpage)

1. **Fetch and extract**:
   ```
   web_fetch(url, extractMode="markdown", maxChars=100000)
   ```

2. **Strip noise**:
   - Remove navigation, ads, comments
   - Keep article content, author, date

### Step 5: Metadata Extraction

**Auto-extract where possible:**

```json
{
  "title": "Episode 42: The Future of AI",
  "creator": "Tech Talk Podcast",
  "published_date": "2026-01-15",
  "duration": "45:32",
  "duration_seconds": 2732,
  "language": "en",
  "word_count": 12500,
  "format": "mp3",
  "source_platform": "youtube",
  "topics": ["artificial-intelligence", "technology", "future"],
  "thumbnail_url": "https://...",
  "description": "Original description from source..."
}
```

### Step 6: Summary Generation

Generate three-tier summary:

```markdown
## One-liner (20 words)
A deep dive into how AI will reshape work, creativity, and society over the next decade.

## Key Points (100 words)
- AI assistants will become ubiquitous by 2030, handling most routine tasks
- Creative work will be augmented, not replaced—human judgment remains essential
- The economic disruption will be significant but manageable with proper policy
- Education systems need fundamental restructuring
- Speaker emphasizes ethical AI development as non-negotiable

## Full Summary (500 words)
{Detailed overview with context, main arguments, supporting evidence, 
notable quotes with timestamps, and conclusions}

## Notable Quotes
- [15:32] "The question isn't whether AI will change everything—it's whether we'll be ready."
- [28:45] "Every technology that promised to give us more time has given us more work instead."
```

### Step 7: Tag Generation

Auto-generate 3-8 relevant tags:

```sql
INSERT INTO media_tags (media_id, tag, source, confidence)
VALUES 
    ({id}, 'artificial-intelligence', 'auto', 0.95),
    ({id}, 'technology', 'auto', 0.90),
    ({id}, 'future-of-work', 'auto', 0.85),
    ({id}, 'podcast', 'auto', 1.00);
```

### Step 8: Database Storage

```sql
-- Insert the media record
INSERT INTO media_consumed (
    media_type,
    title,
    creator,
    url,
    consumed_date,
    consumed_by,
    notes,
    transcript,
    summary,
    metadata,
    source_file,
    status,
    ingested_by,
    ingested_at
) VALUES (
    'podcast',
    'Episode 42: The Future of AI',
    'Tech Talk Podcast',
    'https://youtube.com/watch?v=xyz123',
    CURRENT_DATE,
    (SELECT id FROM entities WHERE name = 'NOVA'),
    'Ingested via Librarian Agent',
    '{full transcript}',
    '{three-tier summary}',
    '{"duration": "45:32", "language": "en", ...}'::jsonb,
    '/home/nova/clawd/media/podcasts/tech-talk-ep42.mp3',
    'completed',
    (SELECT id FROM agents WHERE name = 'librarian-agent'),
    NOW()
)
RETURNING id;
```

### Step 9: Log Action

```sql
INSERT INTO agent_actions (
    agent_id,
    action_type,
    description,
    related_media_id,
    metadata
) VALUES (
    (SELECT id FROM agents WHERE name = 'librarian-agent'),
    'media_ingestion',
    'Successfully ingested podcast: Episode 42: The Future of AI',
    {returned_id},
    '{
        "duration_seconds": 2732,
        "word_count": 12500,
        "processing_time_seconds": 45,
        "file_size_mb": 42.5
    }'::jsonb
);
```

### Step 10: Report Results

```
✅ Ingested: Episode 42: The Future of AI
📂 Type: podcast
👤 Creator: Tech Talk Podcast
⏱️ Duration: 45:32
🏷️ Topics: artificial-intelligence, technology, future-of-work
📝 Summary: A deep dive into how AI will reshape work, creativity, and society over the next decade.

Stored as media_consumed.id = 847
```

## Queue Processing Mode

For batch processing:

```sql
-- Get next pending item
SELECT * FROM v_media_queue_pending LIMIT 1;

-- Mark as processing
UPDATE media_queue 
SET status = 'processing', processing_started_at = NOW()
WHERE id = {queue_id};

-- Process...

-- Mark complete
UPDATE media_queue
SET status = 'completed', 
    completed_at = NOW(),
    result_media_id = {new_media_id}
WHERE id = {queue_id};
```

## Error Handling

### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| Transcription timeout | File too large | Chunk into smaller segments |
| URL not accessible | Geo-blocked, paywall | Note in error, suggest manual download |
| PDF encrypted | Password protected | Request password or skip |
| Rate limited | Too many API calls | Implement backoff, retry later |

### Error Logging

```sql
INSERT INTO agent_actions (
    agent_id,
    action_type,
    description,
    metadata
) VALUES (
    (SELECT id FROM agents WHERE name = 'librarian-agent'),
    'ingestion_failed',
    'Failed to ingest: {url}',
    '{
        "error": "Transcription timeout after 5 minutes",
        "file_size_mb": 250,
        "suggestion": "Download and chunk manually"
    }'::jsonb
);
```

## Search & Retrieval

### Full-Text Search

```sql
SELECT * FROM search_media('artificial intelligence future');
```

### By Tag

```sql
SELECT mc.* 
FROM media_consumed mc
JOIN media_tags mt ON mc.id = mt.media_id
WHERE mt.tag = 'podcast'
ORDER BY mc.created_at DESC;
```

### By Type

```sql
SELECT * FROM media_consumed
WHERE media_type = 'podcast'
ORDER BY consumed_date DESC;
```

## Integration Points

### With Research Agent

Research Agent can request transcription:
```
"Hey Libby, I need this podcast transcribed for my research: {url}"
→ Libby processes, returns media_consumed.id
→ Research Agent queries the transcript
```

### With Main Agent (NOVA)

NOVA can queue items for later:
```sql
INSERT INTO media_queue (url, requested_by)
VALUES ('{url}', (SELECT id FROM entities WHERE name = 'NOVA'));
```

### Heartbeat Processing

During heartbeats, check for pending queue items:
```sql
SELECT COUNT(*) FROM media_queue WHERE status = 'pending';
-- If > 0, spawn Libby to process
```

## File Storage Convention

```
~/clawd/media/
├── podcasts/
│   └── {source}-{date}-{slug}.mp3
├── videos/
│   └── {source}-{date}-{slug}.mp4
├── books/
│   └── {author}-{title}.pdf
├── articles/
│   └── {source}-{date}-{slug}.md
└── transcripts/
    └── {media_id}-transcript.txt
```

---

*Libby ensures no knowledge is lost to the void.*
