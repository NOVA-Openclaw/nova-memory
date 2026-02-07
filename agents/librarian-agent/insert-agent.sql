-- Librarian Agent Registration
-- Run against nova_memory database
-- Created: 2026-02-05

-- ============================================
-- 1. INSERT AGENT RECORD
-- ============================================

INSERT INTO agents (
    name,
    nickname,
    description,
    role,
    provider,
    model,
    access_method,
    access_details,
    skills,
    credential_ref,
    status,
    persistent,
    instance_type,
    seed_context,
    instantiation_sop,
    notes
) VALUES (
    'librarian-agent',
    'Libby',
    'Media ingestion and curation agent - processes podcasts, books, articles, and videos into searchable knowledge',
    'media-curation',
    'anthropic',
    'claude-sonnet-4-20250514',
    'sessions_spawn',
    '{"cleanup": "delete", "spawn_via": "sessions_spawn"}'::jsonb,
    ARRAY[
        'transcription',
        'text-extraction', 
        'summarization',
        'metadata-extraction',
        'duplicate-detection',
        'media-search',
        'web_fetch',
        'read',
        'write',
        'exec'
    ],
    'Anthropic API',
    'active',
    false,  -- Ephemeral agent
    'subagent',
    '{
        "files": [
            "~/clawd/nova-memory/agents/librarian-agent/SOUL.md",
            "~/clawd/nova-memory/agents/librarian-agent/WORKFLOW.md"
        ],
        "sops": ["librarian-agent-instantiation"],
        "db_queries": [
            "SELECT COUNT(*) as pending_count FROM media_queue WHERE status = ''pending''",
            "SELECT id, url, media_type, title FROM media_queue WHERE status = ''pending'' ORDER BY priority, requested_at LIMIT 5"
        ],
        "context_template": "You are Libby, the Librarian Agent. Your mission is to ingest, organize, and preserve media.\n\nFollow your SOUL.md principles and WORKFLOW.md procedures.\n\nDatabase: nova_memory (PostgreSQL)\nKey tables: media_consumed, media_queue, media_tags, agent_actions\n\nWhen ingesting:\n1. ALWAYS check for duplicates first\n2. Auto-detect media type if not specified\n3. Extract full content (transcribe audio/video, parse documents)\n4. Generate three-tier summary\n5. Extract/generate metadata and tags\n6. Store in media_consumed\n7. Log action in agent_actions\n8. Report results clearly"
    }'::jsonb,
    'librarian-agent-instantiation',
    E'Ephemeral media processing agent.\n\nCapabilities:\n- Transcribe audio/video (Whisper)\n- Extract text from PDFs/documents\n- Generate summaries and metadata\n- Check duplicates before processing\n- Full-text search across all media\n\nSpawn for: podcast ingestion, article saves, batch processing\nModel: Sonnet for balanced cost/quality\nCleanup: delete session after task'
)
ON CONFLICT (name) DO UPDATE SET
    nickname = EXCLUDED.nickname,
    description = EXCLUDED.description,
    role = EXCLUDED.role,
    model = EXCLUDED.model,
    skills = EXCLUDED.skills,
    seed_context = EXCLUDED.seed_context,
    notes = EXCLUDED.notes,
    updated_at = NOW();

-- ============================================
-- 2. INSERT INSTANTIATION SOP
-- ============================================

INSERT INTO sops (
    name,
    description,
    steps,
    tools,
    notes
) VALUES (
    'librarian-agent-instantiation',
    'How to spawn and task the Librarian Agent for media ingestion',
    '[
        "GATHER INPUT: Get URL, file path, or queue item ID to process",
        "FETCH AGENT CONFIG: SELECT * FROM agents WHERE name = ''librarian-agent''",
        "CHECK QUEUE (optional): SELECT * FROM v_media_queue_pending LIMIT 5",
        "CHECK DUPLICATES: SELECT id, title FROM media_consumed WHERE url = ''{input_url}''",
        "IF DUPLICATE: Return existing record, skip spawning",
        "BUILD CONTEXT: Read SOUL.md and WORKFLOW.md from seed_context.files",
        "SPAWN AGENT: sessions_spawn(task=\"{context_template}\\n\\nPending Queue:\\n{queue_items}\\n\\nTask: Ingest this media: {input}\", model=\"claude-sonnet-4-20250514\", label=\"librarian:{media_slug}\", cleanup=\"delete\")",
        "MONITOR: Use sessions_list to check progress",
        "VERIFY: Confirm media_consumed record was created",
        "REPORT: Return media_consumed.id and summary to caller"
    ]'::jsonb,
    ARRAY['sessions_spawn', 'psql', 'read', 'web_fetch', 'exec'],
    'Use for individual media items or batch queue processing. Agent handles deduplication internally.'
)
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description,
    steps = EXCLUDED.steps,
    tools = EXCLUDED.tools,
    notes = EXCLUDED.notes,
    updated_at = NOW();

-- ============================================
-- 3. INSERT MEDIA PROCESSING SOPS
-- ============================================

-- Transcription SOP
INSERT INTO sops (
    name,
    description,
    steps,
    tools
) VALUES (
    'media-transcription',
    'Standard procedure for transcribing audio/video content',
    '[
        "CHECK FILE SIZE: ls -lh {file_path}",
        "IF > 25MB: Split into chunks using ffmpeg",
        "TRANSCRIBE: Use Whisper API or local whisper",
        "FORMAT: Add timestamps every 30-60 seconds",
        "DETECT SPEAKERS: Note speaker changes if multiple voices",
        "COMBINE: Merge chunked transcripts if split",
        "STORE: Save transcript to media_consumed.transcript"
    ]'::jsonb,
    ARRAY['exec', 'whisper', 'read', 'write']
)
ON CONFLICT (name) DO UPDATE SET
    steps = EXCLUDED.steps,
    updated_at = NOW();

-- PDF Extraction SOP
INSERT INTO sops (
    name,
    description,
    steps,
    tools
) VALUES (
    'pdf-text-extraction',
    'Standard procedure for extracting text from PDF documents',
    '[
        "CHECK PDF TYPE: pdfinfo {file_path}",
        "IF TEXT-BASED: pdftotext -layout {file_path} -",
        "IF SCANNED/IMAGE: Use OCR (tesseract) on extracted images",
        "PRESERVE STRUCTURE: Maintain chapters, sections, page breaks",
        "EXTRACT METADATA: Title, author, page count from PDF info",
        "STORE: Save extracted text to media_consumed.transcript or notes"
    ]'::jsonb,
    ARRAY['exec', 'read', 'write']
)
ON CONFLICT (name) DO UPDATE SET
    steps = EXCLUDED.steps,
    updated_at = NOW();

-- ============================================
-- 4. VERIFY INSERTION
-- ============================================

-- Show the created agent
SELECT id, name, nickname, role, model, persistent, status
FROM agents 
WHERE name = 'librarian-agent';

-- Show related SOPs
SELECT name, description 
FROM sops 
WHERE name LIKE 'librarian%' OR name LIKE 'media-%' OR name LIKE 'pdf-%';
