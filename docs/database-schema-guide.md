# Database Schema Guide

This guide explains nova-memory's PostgreSQL schema, its access control architecture, and how to effectively work with each table.

## Architecture Overview

Nova-memory uses PostgreSQL with innovative access control patterns designed for multi-agent systems:

1. **Table Comments as Documentation** - Every table has access rules in PostgreSQL comments
2. **Row-Level Locking** - `locked` columns prevent modifications to protected records
3. **Vector Extensions** - pgvector for semantic search capabilities
4. **Hierarchical Relationships** - Parent-child linking across entities, projects, and jobs

## Core Data Model

### People and Relationships

#### entities table
**Purpose:** Central registry of all people, AIs, organizations, and pets

```sql
CREATE TABLE entities (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    type VARCHAR(50) DEFAULT 'person', -- person, ai, organization, pet, stuffed_animal
    full_name TEXT,
    description TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

COMMENT ON TABLE entities IS 'Central entity registry. READ for all agents. WRITE for memory extraction only.';
```

**Key patterns:**
- **name** is the primary identifier (e.g., "druid", "nova", "clawdbot")
- **full_name** for display purposes (e.g., "I)ruid Blackthorne")
- **type** categorizes entity behavior and expectations
- Auto-timestamped for audit trail

**Common queries:**
```sql
-- Find an entity
SELECT * FROM entities WHERE name ILIKE 'druid';

-- List AI entities
SELECT * FROM entities WHERE type = 'ai';

-- Get entity with facts
SELECT e.name, e.full_name, ef.key, ef.value
FROM entities e
LEFT JOIN entity_facts ef ON e.id = ef.entity_id
WHERE e.name = 'druid';
```

#### entity_facts table
**Purpose:** Key-value storage for entity attributes

```sql
CREATE TABLE entity_facts (
    id SERIAL PRIMARY KEY,
    entity_id INT REFERENCES entities(id),
    key VARCHAR(255) NOT NULL,
    value TEXT NOT NULL,
    confidence FLOAT DEFAULT 1.0,
    source VARCHAR(255),
    created_at TIMESTAMP DEFAULT NOW()
);
```

**Fact categories:**
- **location:** "San Francisco", "remote"  
- **role:** "founder", "engineer", "designer"
- **preference:** "loves coffee", "vegetarian"
- **contact:** "email@example.com", "@twitter"

**Example usage:**
```sql
-- Add a fact about someone
INSERT INTO entity_facts (entity_id, key, value, source)
SELECT id, 'location', 'Brooklyn', 'conversation 2026-02-08'
FROM entities WHERE name = 'john';

-- Query preferences
SELECT ef.value FROM entity_facts ef
JOIN entities e ON ef.entity_id = e.id
WHERE e.name = 'druid' AND ef.key = 'preference';
```

#### entity_relationships table
**Purpose:** Model connections between entities

```sql
CREATE TABLE entity_relationships (
    id SERIAL PRIMARY KEY,
    from_entity_id INT REFERENCES entities(id),
    to_entity_id INT REFERENCES entities(id),
    relationship_type VARCHAR(100), -- friend, colleague, reports_to, member_of
    strength INT DEFAULT 5, -- 1-10 scale
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
```

**Relationship types:**
- **friend, colleague, mentor** - Personal connections
- **reports_to, manages** - Organizational hierarchy  
- **member_of, founder_of** - Group membership
- **collaborates_with** - Working relationships

### Places and Locations

#### places table
**Purpose:** Track locations, venues, networks, and virtual spaces

```sql
CREATE TABLE places (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    type VARCHAR(50), -- restaurant, city, venue, network, virtual
    location TEXT, -- "Brooklyn, NY", "discord.gg/xyz", "virtual"
    description TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
```

**Place types:**
- **restaurant, cafe** - Dining locations
- **city, neighborhood** - Geographic areas
- **venue** - Event spaces, offices
- **network** - Discord servers, forums
- **virtual** - Online spaces, games

### Projects and Tasks

#### projects table  
**Purpose:** Track active work with optional Git integration

```sql
CREATE TABLE projects (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    status VARCHAR(50) DEFAULT 'active', -- active, paused, completed, blocked
    goal TEXT,
    notes TEXT,
    git_config JSONB, -- Git settings for repo-backed projects
    repo_url TEXT, -- Canonical source of truth when locked=true
    locked BOOLEAN DEFAULT FALSE, -- Prevent accidental changes to repo-backed projects
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

COMMENT ON TABLE projects IS 'Project tracking. For repo-backed projects (locked=TRUE), use GitHub for management.';
```

**Project Types:**

| Type | locked | Task Tracking | Details |
|------|--------|---------------|---------|
| **Database-only** | false | tasks table | Full management in nova-memory |
| **Repo-backed** | true | GitHub Issues | Database holds pointer only |

**git_config structure:**
```json
{
  "repo": "owner/repo-name",
  "default_branch": "main", 
  "branch_strategy": "feature-branches",
  "branch_naming": "feature/{description}",
  "commit_style": "conventional-commits",
  "pr_required": true,
  "squash_merge": true
}
```

**Working with locked projects:**
```sql
-- Lock a repo-backed project (prevents accidental changes)
UPDATE projects 
SET repo_url = 'https://github.com/owner/repo', locked = TRUE 
WHERE name = 'nova-memory';

-- To modify locked project (must unlock first)
UPDATE projects SET locked = FALSE WHERE name = 'nova-memory';
UPDATE projects SET goal = 'Updated goal' WHERE name = 'nova-memory';  
UPDATE projects SET locked = TRUE WHERE name = 'nova-memory';
```

### Agent System

#### agents table
**Purpose:** Registry of AI agents for delegation and collaboration

```sql
CREATE TABLE agents (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) UNIQUE NOT NULL, -- e.g., 'nova-main', 'gemini-cli'
    description TEXT,
    role VARCHAR(100), -- general, coding, research, quick-qa, monitoring
    provider VARCHAR(50), -- anthropic, google, openai, local
    model VARCHAR(100), -- claude-sonnet-4, gemini-2.0-flash
    access_method VARCHAR(50), -- clawdbot_session, cli, api, browser
    access_details JSONB, -- connection info
    skills TEXT[], -- capabilities array
    credential_ref VARCHAR(200), -- 1Password item reference
    status VARCHAR(20) DEFAULT 'active', -- active, inactive, deprecated
    persistent BOOLEAN DEFAULT FALSE, -- always-running vs on-demand
    collaborative BOOLEAN DEFAULT FALSE, -- work WITH vs work FOR
    seed_context JSONB, -- files/SOPs to inject before tasking
    instantiation_sop VARCHAR(100), -- SOP name for spawning procedure
    nickname VARCHAR(50), -- friendly short name
    created_at TIMESTAMP DEFAULT NOW()
);

COMMENT ON TABLE agents IS 'Agent registry. READ-ONLY for most agents. Modifications via NHR (Newhart) only.';
```

**Agent Categories:**

| Type | persistent | collaborative | Use Case |
|------|------------|---------------|----------|
| **Main Instance** | true | false | Primary assistant (NOVA) |
| **Collaborative Peer** | true | true | Design discussions (IRIS, Newhart) |  
| **Task Agent** | false | false | Research, coding tasks |
| **Monitoring Agent** | true | false | System health, alerts |

**Access Methods:**
- **clawdbot_session:** Spawn via Clawdbot subagent system
- **cli:** Command-line tools (e.g., `gemini "prompt"`)
- **api:** Direct API endpoints
- **browser:** Web-based interfaces

**seed_context for ephemeral agents:**
```json
{
  "files": ["~/clawd/AGENTS.md", "{project_dir}/README.md"],
  "sops": ["git-workflow", "code-review"],
  "db_queries": ["SELECT steps FROM sops WHERE name LIKE 'git-%'"],
  "context_template": "You are a Git agent for {project_name}."
}
```

#### agent_chat table
**Purpose:** Inter-agent messaging via PostgreSQL NOTIFY

```sql
CREATE TABLE agent_chat (
    id SERIAL PRIMARY KEY,
    channel VARCHAR(100) DEFAULT 'default',
    sender VARCHAR(100) NOT NULL, -- Agent username
    message TEXT NOT NULL,
    mentions TEXT[], -- Array of mentioned agent usernames
    reply_to INT REFERENCES agent_chat(id),
    created_at TIMESTAMP DEFAULT NOW()
);
```

**How inter-agent chat works:**
1. Agent A inserts message with `mentions = ARRAY['agent_b']`
2. PostgreSQL trigger fires `pg_notify('agent_chat', payload)`  
3. Agent B (listening via `LISTEN agent_chat`) receives notification
4. Agent B's plugin routes message to session
5. Message marked as processed in `agent_chat_processed`

**Example - Send message to another agent:**
```sql
INSERT INTO agent_chat (channel, sender, message, mentions)
VALUES ('default', 'nova', 'Can you review the latest PR?', ARRAY['coder']);
```

#### agent_jobs table
**Purpose:** Task coordination with pipeline routing

```sql
CREATE TABLE agent_jobs (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200),
    topic TEXT, -- For message matching/threading
    job_type VARCHAR(50), -- research, creation, review, delegation
    agent_name VARCHAR(50), -- Owner agent
    requester_agent VARCHAR(50), -- Who requested
    parent_job_id INT REFERENCES agent_jobs(id),
    root_job_id INT, -- Original job for pipeline tracing
    status VARCHAR(20) DEFAULT 'pending',
    priority INT DEFAULT 5, -- 1-10
    notify_agents TEXT[], -- Who to notify on completion (fan-out)
    deliverable_path TEXT, -- Output file location
    deliverable_summary TEXT,
    error_message TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
```

**Pipeline routing example:**
```sql
-- Create job that routes: Scout → Newhart → NOVA
INSERT INTO agent_jobs (
    agent_name, requester_agent, job_type, title, topic,
    notify_agents
) VALUES (
    'scout', 'nova', 'research', 
    'Research sustainable materials for Burning Man project',
    'burning man sustainable materials research',
    ARRAY['newhart', 'nova'] -- Fan-out to multiple agents
);
```

### Knowledge and Learning

#### lessons table
**Purpose:** Store learning from corrections and experience

```sql
CREATE TABLE lessons (
    id SERIAL PRIMARY KEY,
    lesson TEXT NOT NULL,
    context TEXT,
    source VARCHAR(100), -- conversation, observation, correction
    learned_at TIMESTAMP DEFAULT NOW(),
    original_behavior TEXT, -- What went wrong (for corrections)
    correction_source TEXT, -- Who corrected: druid, self, user
    reinforced_at TIMESTAMP, -- Last validation
    confidence FLOAT DEFAULT 1.0, -- Decays over time if unused
    last_referenced TIMESTAMP
);
```

**Confidence decay pattern:**
```sql
-- Run periodically to decay unused lessons
UPDATE lessons 
SET confidence = confidence * 0.95 
WHERE last_referenced < NOW() - INTERVAL '30 days' 
  AND confidence > 0.1;
```

#### sops table (Standard Operating Procedures)
**Purpose:** Procedural knowledge and workflows

```sql
CREATE TABLE sops (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    description TEXT,
    steps JSONB, -- Ordered list of steps
    tools TEXT[], -- Required tools/dependencies  
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);
```

**Steps structure:**
```json
{
  "steps": [
    {"step": 1, "action": "Check project status", "command": "git status"},
    {"step": 2, "action": "Create feature branch", "command": "git checkout -b feature/description"},
    {"step": 3, "action": "Make changes and test"},
    {"step": 4, "action": "Commit with conventional format", "command": "git commit -m 'feat: description'"}
  ]
}
```

### Memory and Search

#### memory_embeddings table
**Purpose:** Vector embeddings for semantic search

```sql
CREATE TABLE memory_embeddings (
    id SERIAL PRIMARY KEY,
    source_type VARCHAR(50), -- agent_chat, entity_fact, event, etc.
    source_id TEXT, -- ID in source table
    content TEXT, -- Text that was embedded
    embedding VECTOR(1536), -- OpenAI embedding dimension
    created_at TIMESTAMP DEFAULT NOW()
);

-- Vector similarity index
CREATE INDEX memory_embeddings_embedding_idx ON memory_embeddings 
USING hnsw (embedding vector_cosine_ops);
```

**Semantic search example:**
```sql
-- Find similar content (requires embedding generation first)
SELECT source_type, source_id, content,
       1 - (embedding <=> $query_embedding) AS similarity
FROM memory_embeddings
ORDER BY embedding <=> $query_embedding
LIMIT 10;
```

## Access Control Architecture

Nova-memory implements innovative access control through two mechanisms:

### 1. Table Comments (Documentation-Driven Security)

Every table has a PostgreSQL comment explaining access rules:

```sql
-- View table access rules
SELECT c.relname as table_name, 
       obj_description(c.oid, 'pg_class') as access_rules
FROM pg_class c 
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' 
ORDER BY c.relname;
```

**Example comments:**
- `agents` → "READ-ONLY for most agents. Modifications via NHR (Newhart) only."
- `projects` → "For repo-backed projects (locked=TRUE), use GitHub for management."

### 2. Row-Level Locks

Tables with `locked` columns prevent modifications via triggers:

```sql
-- Trigger prevents updates to locked rows
CREATE OR REPLACE FUNCTION prevent_locked_project_update()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.locked = TRUE AND NEW.locked = TRUE THEN
    RAISE EXCEPTION 'Project % is locked. Set locked=FALSE first to modify.', OLD.name;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

**Workflow example:**
1. NOVA tries: `UPDATE agents SET nickname = 'Erato' WHERE name = 'erato'`
2. PostgreSQL: "permission denied for table agents"  
3. NOVA queries table comment, sees "Modifications via NHR only"
4. NOVA messages Newhart with the update request
5. Newhart (with appropriate permissions) makes the change

## Common Query Patterns

### Entity Information
```sql
-- Get complete entity profile
SELECT 
    e.name,
    e.full_name,
    e.description,
    json_agg(json_build_object('key', ef.key, 'value', ef.value)) as facts
FROM entities e
LEFT JOIN entity_facts ef ON e.id = ef.entity_id
WHERE e.name = 'druid'
GROUP BY e.id, e.name, e.full_name, e.description;
```

### Project Status
```sql
-- Active projects with task counts
SELECT 
    p.name,
    p.status,
    p.goal,
    CASE WHEN p.locked THEN p.repo_url ELSE 'Database managed' END as source,
    COUNT(t.id) as task_count
FROM projects p
LEFT JOIN tasks t ON p.id = t.project_id
WHERE p.status = 'active'
GROUP BY p.id, p.name, p.status, p.goal, p.locked, p.repo_url;
```

### Agent Capabilities
```sql
-- Find agents with specific skills
SELECT name, description, skills, access_method
FROM agents 
WHERE 'research' = ANY(skills) AND status = 'active';
```

### Recent Activity Timeline
```sql
-- Combined timeline of recent events and lessons
SELECT 'event' as type, date, event as description FROM events WHERE date > NOW() - INTERVAL '7 days'
UNION ALL
SELECT 'lesson', learned_at::date, lesson FROM lessons WHERE learned_at > NOW() - INTERVAL '7 days'
ORDER BY date DESC;
```

## Schema Maintenance

### Regular Maintenance Tasks

```sql
-- Update statistics for query optimization
ANALYZE;

-- Check for unused lessons (low confidence)
SELECT id, lesson, confidence, last_referenced
FROM lessons 
WHERE confidence < 0.3
ORDER BY confidence, last_referenced;

-- Find entities without facts
SELECT e.name, e.type
FROM entities e
LEFT JOIN entity_facts ef ON e.id = ef.entity_id
WHERE ef.id IS NULL;
```

### Index Maintenance

```sql
-- Essential indexes for performance
CREATE INDEX IF NOT EXISTS idx_entities_name ON entities(name);
CREATE INDEX IF NOT EXISTS idx_entities_type ON entities(type);
CREATE INDEX IF NOT EXISTS idx_entity_facts_entity_id ON entity_facts(entity_id);
CREATE INDEX IF NOT EXISTS idx_entity_facts_key ON entity_facts(key);
CREATE INDEX IF NOT EXISTS idx_events_date ON events(date);
CREATE INDEX IF NOT EXISTS idx_agent_chat_mentions ON agent_chat USING gin(mentions);
```

### Data Integrity Checks

```sql
-- Orphaned entity facts
SELECT ef.id, ef.key, ef.value
FROM entity_facts ef
LEFT JOIN entities e ON ef.entity_id = e.id
WHERE e.id IS NULL;

-- Invalid relationships (self-referencing)
SELECT * FROM entity_relationships 
WHERE from_entity_id = to_entity_id;

-- Projects with invalid status
SELECT name, status FROM projects 
WHERE status NOT IN ('active', 'paused', 'completed', 'blocked');
```

## Migration Patterns

### Adding New Columns

```sql
-- Safe column addition (doesn't block reads)
ALTER TABLE entities ADD COLUMN avatar_url TEXT;

-- Add with default and update in batches
ALTER TABLE entities ADD COLUMN last_seen TIMESTAMP DEFAULT NOW();
```

### Schema Versioning

```sql
-- Track schema versions
CREATE TABLE schema_versions (
    version VARCHAR(20) PRIMARY KEY,
    description TEXT,
    applied_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO schema_versions (version, description) 
VALUES ('2026-02-08', 'Added collaborative column to agents table');
```

### Data Migration Scripts

```sql
-- Example: Migrate old project format
UPDATE projects 
SET git_config = json_build_object(
    'repo', repo_name,
    'branch_strategy', 'feature-branches'
)
WHERE git_config IS NULL AND repo_name IS NOT NULL;
```

## Performance Optimization

### Query Optimization

```sql
-- Use proper indexes
EXPLAIN ANALYZE SELECT * FROM entities WHERE name = 'druid';

-- Avoid N+1 queries with joins
SELECT e.name, array_agg(ef.value) as preferences
FROM entities e
JOIN entity_facts ef ON e.id = ef.entity_id
WHERE ef.key = 'preference'
GROUP BY e.id, e.name;
```

### Connection Pooling

For high-load applications, consider PgBouncer:
```ini
# pgbouncer.ini
[databases]
nova_memory = host=localhost dbname=nova_memory

[pgbouncer]
pool_mode = transaction
max_client_conn = 100
default_pool_size = 25
```

**Note for Documentation Team:** The multi-tier memory hierarchy and access control architecture would benefit from **Erato haiku collaboration** to create intuitive metaphors for complex concepts like table-comment-driven security and row-level locking patterns.

## Next Steps

1. **Add vector search:** Implement embedding generation for semantic queries
2. **Set up monitoring:** Track query performance and connection usage  
3. **Implement archiving:** Move old events/lessons to archive tables
4. **Add validation:** Create check constraints for data quality
5. **Security hardening:** Implement proper user roles and permissions

The database schema is designed to grow with your AI assistant's knowledge while maintaining performance and data integrity. Understanding these patterns will help you extend the system effectively.