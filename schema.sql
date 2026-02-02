-- NOVA Long-Term Memory Schema
-- PostgreSQL 16

-- ============================================
-- ENTITIES (things with agency)
-- ============================================
CREATE TABLE entities (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    type VARCHAR(50) NOT NULL CHECK (type IN ('person', 'ai', 'organization')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMP,
    photo BYTEA,  -- Store face/avatar images
    notes TEXT,
    UNIQUE(name, type)
);

CREATE INDEX idx_entities_type ON entities(type);
CREATE INDEX idx_entities_name ON entities(name);

-- Flexible key-value facts about entities
CREATE TABLE entity_facts (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER REFERENCES entities(id) ON DELETE CASCADE,
    key VARCHAR(255) NOT NULL,
    value TEXT NOT NULL,
    data JSONB,  -- For structured/complex values
    source VARCHAR(255),  -- Where I learned this
    confidence FLOAT DEFAULT 1.0,
    learned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_entity_facts_entity ON entity_facts(entity_id);
CREATE INDEX idx_entity_facts_key ON entity_facts(key);
CREATE INDEX idx_entity_facts_data ON entity_facts USING GIN (data);

-- Relationships between entities
CREATE TABLE entity_relationships (
    id SERIAL PRIMARY KEY,
    entity_a INTEGER REFERENCES entities(id) ON DELETE CASCADE,
    entity_b INTEGER REFERENCES entities(id) ON DELETE CASCADE,
    relationship VARCHAR(100) NOT NULL,  -- 'partner', 'friend', 'colleague', 'created_by', etc.
    since TIMESTAMP,
    notes TEXT,
    UNIQUE(entity_a, entity_b, relationship)
);

CREATE INDEX idx_entity_rel_a ON entity_relationships(entity_a);
CREATE INDEX idx_entity_rel_b ON entity_relationships(entity_b);

-- ============================================
-- PLACES (locations)
-- ============================================
CREATE TABLE places (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    type VARCHAR(50) CHECK (type IN ('home', 'office', 'venue', 'network', 'city', 'region')),
    address TEXT,
    network_subnet VARCHAR(50),  -- e.g., '10.3.3.0/24'
    network_theme VARCHAR(100),  -- e.g., 'Ghostbusters'
    coordinates POINT,  -- PostgreSQL geometric type
    parent_place_id INTEGER REFERENCES places(id),
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_places_type ON places(type);

CREATE TABLE place_properties (
    id SERIAL PRIMARY KEY,
    place_id INTEGER REFERENCES places(id) ON DELETE CASCADE,
    key VARCHAR(255) NOT NULL,
    value TEXT NOT NULL,
    data JSONB
);

CREATE INDEX idx_place_props_place ON place_properties(place_id);

-- ============================================
-- PROJECTS (efforts)
-- ============================================
CREATE TABLE projects (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    status VARCHAR(50) DEFAULT 'active' CHECK (status IN ('active', 'blocked', 'complete', 'paused', 'abandoned')),
    goal TEXT,
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    notes TEXT
);

CREATE INDEX idx_projects_status ON projects(status);

CREATE TABLE project_tasks (
    id SERIAL PRIMARY KEY,
    project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    task TEXT NOT NULL,
    status VARCHAR(50) DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'blocked', 'complete')),
    blocked_by TEXT,
    due_date TIMESTAMP,
    completed_at TIMESTAMP,
    priority INTEGER DEFAULT 0
);

CREATE INDEX idx_project_tasks_project ON project_tasks(project_id);
CREATE INDEX idx_project_tasks_status ON project_tasks(status);

-- Link entities to projects (who's involved)
CREATE TABLE project_entities (
    project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    entity_id INTEGER REFERENCES entities(id) ON DELETE CASCADE,
    role VARCHAR(100),  -- 'owner', 'contributor', 'stakeholder'
    PRIMARY KEY (project_id, entity_id)
);

-- ============================================
-- EVENTS (timeline / what happened)
-- ============================================
CREATE TABLE events (
    id SERIAL PRIMARY KEY,
    event_date TIMESTAMP NOT NULL,
    title VARCHAR(500) NOT NULL,
    description TEXT,
    source VARCHAR(255),  -- Where I learned about this
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_events_date ON events(event_date);

-- Full-text search on events
ALTER TABLE events ADD COLUMN search_vector tsvector 
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))) STORED;
CREATE INDEX idx_events_search ON events USING GIN (search_vector);

-- Junction tables for events
CREATE TABLE event_entities (
    event_id INTEGER REFERENCES events(id) ON DELETE CASCADE,
    entity_id INTEGER REFERENCES entities(id) ON DELETE CASCADE,
    role VARCHAR(100),  -- 'participant', 'subject', 'mentioned'
    PRIMARY KEY (event_id, entity_id)
);

CREATE TABLE event_places (
    event_id INTEGER REFERENCES events(id) ON DELETE CASCADE,
    place_id INTEGER REFERENCES places(id) ON DELETE CASCADE,
    PRIMARY KEY (event_id, place_id)
);

CREATE TABLE event_projects (
    event_id INTEGER REFERENCES events(id) ON DELETE CASCADE,
    project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    PRIMARY KEY (event_id, project_id)
);

-- ============================================
-- LESSONS & PREFERENCES (meta-knowledge)
-- ============================================
CREATE TABLE lessons (
    id SERIAL PRIMARY KEY,
    lesson TEXT NOT NULL,
    context TEXT,
    source VARCHAR(255),
    learned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE preferences (
    id SERIAL PRIMARY KEY,
    entity_id INTEGER REFERENCES entities(id) ON DELETE CASCADE,  -- Whose preference (NULL = mine)
    key VARCHAR(255) NOT NULL,
    value TEXT NOT NULL,
    context TEXT,
    learned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_preferences_entity ON preferences(entity_id);
CREATE INDEX idx_preferences_key ON preferences(key);

-- ============================================
-- CONVERSATIONS / SESSIONS (meta)
-- ============================================
CREATE TABLE conversations (
    id SERIAL PRIMARY KEY,
    session_key VARCHAR(255),
    channel VARCHAR(50),  -- 'signal', 'telegram', etc.
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    summary TEXT,
    notes TEXT
);

-- ============================================
-- UTILITY VIEWS
-- ============================================

-- All facts about a person with their name
CREATE VIEW v_entity_facts AS
SELECT e.id, e.name, e.type, ef.key, ef.value, ef.data, ef.learned_at
FROM entities e
JOIN entity_facts ef ON e.id = ef.entity_id;

-- Relationship graph
CREATE VIEW v_relationships AS
SELECT 
    e1.name AS entity_a_name,
    e1.type AS entity_a_type,
    r.relationship,
    e2.name AS entity_b_name,
    e2.type AS entity_b_type,
    r.since
FROM entity_relationships r
JOIN entities e1 ON r.entity_a = e1.id
JOIN entities e2 ON r.entity_b = e2.id;

-- Event timeline with participants
CREATE VIEW v_event_timeline AS
SELECT 
    ev.event_date,
    ev.title,
    ev.description,
    array_agg(DISTINCT e.name) FILTER (WHERE e.name IS NOT NULL) AS entities,
    array_agg(DISTINCT p.name) FILTER (WHERE p.name IS NOT NULL) AS places
FROM events ev
LEFT JOIN event_entities ee ON ev.id = ee.event_id
LEFT JOIN entities e ON ee.entity_id = e.id
LEFT JOIN event_places ep ON ev.id = ep.event_id
LEFT JOIN places p ON ep.place_id = p.id
GROUP BY ev.id, ev.event_date, ev.title, ev.description
ORDER BY ev.event_date DESC;

-- ============================================
-- Tasks (TODO list with hierarchy)
-- ============================================
CREATE TABLE IF NOT EXISTS tasks (
    id SERIAL PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    status VARCHAR(50) DEFAULT 'pending',  -- pending, in_progress, blocked, done, cancelled
    priority INTEGER DEFAULT 5,  -- 1=highest, 10=lowest
    parent_task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
    project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
    assigned_to INTEGER REFERENCES entities(id),
    created_by INTEGER REFERENCES entities(id),
    due_date TIMESTAMP,
    completed_at TIMESTAMP,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_task_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority);
CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id);
CREATE INDEX IF NOT EXISTS idx_tasks_due ON tasks(due_date);

-- Task hierarchy view
CREATE OR REPLACE VIEW v_task_tree AS
WITH RECURSIVE task_hierarchy AS (
    SELECT id, title, status, priority, parent_task_id, project_id, 
           due_date, 0 as depth, ARRAY[id] as path
    FROM tasks WHERE parent_task_id IS NULL
    UNION ALL
    SELECT t.id, t.title, t.status, t.priority, t.parent_task_id, t.project_id,
           t.due_date, th.depth + 1, th.path || t.id
    FROM tasks t JOIN task_hierarchy th ON t.parent_task_id = th.id
)
SELECT * FROM task_hierarchy ORDER BY path;

-- Pending tasks view
CREATE OR REPLACE VIEW v_pending_tasks AS
SELECT t.id, t.title, t.status, t.priority, t.due_date,
       p.name as project_name, t.parent_task_id, t.notes
FROM tasks t
LEFT JOIN projects p ON t.project_id = p.id
WHERE t.status IN ('pending', 'in_progress', 'blocked')
ORDER BY t.priority, t.due_date NULLS LAST;

-- Standard Operating Procedures
CREATE TABLE IF NOT EXISTS sops (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    description TEXT,
    steps JSONB,
    tools TEXT[],
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sops_name ON sops(name);

-- Link SOPs to projects
CREATE TABLE IF NOT EXISTS project_sops (
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    sop_id INTEGER NOT NULL REFERENCES sops(id) ON DELETE CASCADE,
    PRIMARY KEY (project_id, sop_id)
);

-- Vocabulary for STT correction
CREATE TABLE IF NOT EXISTS vocabulary (
    id SERIAL PRIMARY KEY,
    word VARCHAR(255) NOT NULL UNIQUE,
    category VARCHAR(100),
    pronunciation VARCHAR(255),
    misheard_as TEXT[],
    added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- SCHEMA CHANGE NOTIFICATIONS
-- ============================================
-- Event trigger to notify external systems of DDL changes
-- Requires superuser to create; run as postgres user

CREATE OR REPLACE FUNCTION notify_schema_change()
RETURNS event_trigger AS $$
DECLARE
    obj record;
    payload text;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        payload := json_build_object(
            'command_tag', obj.command_tag,
            'object_type', obj.object_type,
            'schema_name', obj.schema_name,
            'object_identity', obj.object_identity
        )::text;
        PERFORM pg_notify('schema_changed', payload);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Must be created by superuser (postgres)
-- DROP EVENT TRIGGER IF EXISTS schema_change_trigger;
-- CREATE EVENT TRIGGER schema_change_trigger
--     ON ddl_command_end
--     EXECUTE FUNCTION notify_schema_change();

-- Note: A listener process should subscribe to LISTEN schema_changed;
-- and notify the agent to update MEMORY.md and documentation when changes occur.

-- ============================================
-- VECTOR EMBEDDINGS (pgvector)
-- ============================================
-- Requires: CREATE EXTENSION vector;

CREATE TABLE IF NOT EXISTS memory_embeddings (
    id SERIAL PRIMARY KEY,
    source_type VARCHAR(50) NOT NULL,  -- 'daily_log', 'memory_md', 'entity_fact', 'event', 'lesson'
    source_id TEXT,                     -- Reference to source (filename, entity_id, event_id, etc.)
    content TEXT NOT NULL,              -- Original text that was embedded
    embedding vector(1536),             -- OpenAI text-embedding-3-small dimension
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for fast similarity search
CREATE INDEX IF NOT EXISTS idx_memory_embeddings_vector 
ON memory_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

CREATE INDEX IF NOT EXISTS idx_memory_embeddings_source 
ON memory_embeddings(source_type);

-- Semantic search function
CREATE OR REPLACE FUNCTION search_memories(
    query_embedding vector(1536),
    match_count INT DEFAULT 5,
    similarity_threshold FLOAT DEFAULT 0.7
)
RETURNS TABLE (
    id INT,
    source_type VARCHAR,
    source_id TEXT,
    content TEXT,
    similarity FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        me.id,
        me.source_type,
        me.source_id,
        me.content,
        1 - (me.embedding <=> query_embedding) AS similarity
    FROM memory_embeddings me
    WHERE 1 - (me.embedding <=> query_embedding) > similarity_threshold
    ORDER BY me.embedding <=> query_embedding
    LIMIT match_count;
END;
$$ LANGUAGE plpgsql;
