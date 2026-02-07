-- Librarian Agent Schema Additions
-- Run against nova_memory database
-- Created: 2026-02-05

-- ============================================
-- 1. EXTEND media_consumed TABLE
-- ============================================

-- Add summary field for generated summaries
ALTER TABLE media_consumed 
ADD COLUMN IF NOT EXISTS summary TEXT;

COMMENT ON COLUMN media_consumed.summary IS 'AI-generated summary (multi-tier: one-liner, key points, full)';

-- Add metadata JSONB for flexible storage
ALTER TABLE media_consumed 
ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}';

COMMENT ON COLUMN media_consumed.metadata IS 'Flexible metadata: duration, language, format, topics, word_count, etc.';

-- Add source file path for downloaded content
ALTER TABLE media_consumed 
ADD COLUMN IF NOT EXISTS source_file TEXT;

COMMENT ON COLUMN media_consumed.source_file IS 'Local file path if media was downloaded';

-- Add processing status
ALTER TABLE media_consumed 
ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'completed';

COMMENT ON COLUMN media_consumed.status IS 'Processing status: pending, processing, completed, failed, queued';

-- Add ingestion tracking
ALTER TABLE media_consumed 
ADD COLUMN IF NOT EXISTS ingested_by INTEGER REFERENCES agents(id);

COMMENT ON COLUMN media_consumed.ingested_by IS 'Agent ID that processed this media';

ALTER TABLE media_consumed 
ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;

COMMENT ON COLUMN media_consumed.ingested_at IS 'Timestamp when media was ingested/processed';

-- Add searchable text vector for full-text search
ALTER TABLE media_consumed 
ADD COLUMN IF NOT EXISTS search_vector TSVECTOR;

COMMENT ON COLUMN media_consumed.search_vector IS 'Full-text search vector (title + notes + transcript + summary)';

-- Create index for full-text search
CREATE INDEX IF NOT EXISTS idx_media_search 
ON media_consumed USING GIN(search_vector);

-- Create index for status lookups
CREATE INDEX IF NOT EXISTS idx_media_status 
ON media_consumed(status);

-- Create function to update search vector
CREATE OR REPLACE FUNCTION update_media_search_vector()
RETURNS TRIGGER AS $$
BEGIN
    NEW.search_vector := 
        setweight(to_tsvector('english', COALESCE(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', COALESCE(NEW.creator, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(NEW.summary, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(NEW.notes, '')), 'C') ||
        setweight(to_tsvector('english', COALESCE(LEFT(NEW.transcript, 50000), '')), 'D');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to auto-update search vector
DROP TRIGGER IF EXISTS media_search_vector_update ON media_consumed;
CREATE TRIGGER media_search_vector_update
    BEFORE INSERT OR UPDATE ON media_consumed
    FOR EACH ROW
    EXECUTE FUNCTION update_media_search_vector();

-- ============================================
-- 2. CREATE media_queue TABLE
-- ============================================

CREATE TABLE IF NOT EXISTS media_queue (
    id SERIAL PRIMARY KEY,
    url TEXT,
    file_path TEXT,
    media_type VARCHAR(50),  -- Can be NULL for auto-detect
    title VARCHAR(500),       -- Optional hint
    creator VARCHAR(255),     -- Optional hint
    priority INTEGER DEFAULT 5,  -- 1=highest, 10=lowest
    status VARCHAR(20) DEFAULT 'pending',
    requested_by INTEGER REFERENCES entities(id),
    requested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    processing_started_at TIMESTAMP,
    completed_at TIMESTAMP,
    result_media_id INTEGER REFERENCES media_consumed(id),
    error_message TEXT,
    metadata JSONB DEFAULT '{}',
    
    CONSTRAINT media_queue_has_source CHECK (url IS NOT NULL OR file_path IS NOT NULL)
);

COMMENT ON TABLE media_queue IS 'Queue for media ingestion requests awaiting processing by Librarian Agent';
COMMENT ON COLUMN media_queue.priority IS '1=urgent, 5=normal, 10=low priority';
COMMENT ON COLUMN media_queue.status IS 'pending, processing, completed, failed, duplicate';
COMMENT ON COLUMN media_queue.result_media_id IS 'Foreign key to resulting media_consumed record';

-- Indexes for queue management
CREATE INDEX IF NOT EXISTS idx_media_queue_status ON media_queue(status);
CREATE INDEX IF NOT EXISTS idx_media_queue_priority ON media_queue(priority, requested_at);

-- ============================================
-- 3. CREATE media_tags TABLE (for categorization)
-- ============================================

CREATE TABLE IF NOT EXISTS media_tags (
    id SERIAL PRIMARY KEY,
    media_id INTEGER NOT NULL REFERENCES media_consumed(id) ON DELETE CASCADE,
    tag VARCHAR(100) NOT NULL,
    source VARCHAR(20) DEFAULT 'auto',  -- 'auto' or 'manual'
    confidence DECIMAL(3,2),  -- 0.00-1.00 for auto-generated
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    UNIQUE(media_id, tag)
);

COMMENT ON TABLE media_tags IS 'Tags/topics associated with media items';
COMMENT ON COLUMN media_tags.source IS 'auto=AI-generated, manual=user-added';
COMMENT ON COLUMN media_tags.confidence IS 'AI confidence score for auto-generated tags';

CREATE INDEX IF NOT EXISTS idx_media_tags_tag ON media_tags(tag);
CREATE INDEX IF NOT EXISTS idx_media_tags_media ON media_tags(media_id);

-- ============================================
-- 4. HELPER VIEWS
-- ============================================

-- View for pending queue items
CREATE OR REPLACE VIEW v_media_queue_pending AS
SELECT 
    mq.*,
    e.name as requested_by_name
FROM media_queue mq
LEFT JOIN entities e ON mq.requested_by = e.id
WHERE mq.status = 'pending'
ORDER BY mq.priority ASC, mq.requested_at ASC;

-- View for media with tags
CREATE OR REPLACE VIEW v_media_with_tags AS
SELECT 
    mc.*,
    ARRAY_AGG(mt.tag) FILTER (WHERE mt.tag IS NOT NULL) as tags
FROM media_consumed mc
LEFT JOIN media_tags mt ON mc.id = mt.media_id
GROUP BY mc.id;

-- Full-text search function
CREATE OR REPLACE FUNCTION search_media(query_text TEXT, result_limit INTEGER DEFAULT 20)
RETURNS TABLE (
    id INTEGER,
    media_type VARCHAR(50),
    title VARCHAR(500),
    creator VARCHAR(255),
    summary TEXT,
    rank REAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        mc.id,
        mc.media_type,
        mc.title,
        mc.creator,
        mc.summary,
        ts_rank(mc.search_vector, plainto_tsquery('english', query_text)) as rank
    FROM media_consumed mc
    WHERE mc.search_vector @@ plainto_tsquery('english', query_text)
    ORDER BY rank DESC
    LIMIT result_limit;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 5. UPDATE EXISTING RECORDS
-- ============================================

-- Set search vectors for existing records
UPDATE media_consumed SET 
    search_vector = 
        setweight(to_tsvector('english', COALESCE(title, '')), 'A') ||
        setweight(to_tsvector('english', COALESCE(creator, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(summary, '')), 'B') ||
        setweight(to_tsvector('english', COALESCE(notes, '')), 'C') ||
        setweight(to_tsvector('english', COALESCE(LEFT(transcript, 50000), '')), 'D')
WHERE search_vector IS NULL;
