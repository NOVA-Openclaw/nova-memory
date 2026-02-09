-- seed-delegation-knowledge.sql
-- Populates initial agent delegation knowledge into entity_facts
-- Run this once to bootstrap the delegation memory system
--
-- Usage: psql -h localhost -U nova -d nova_memory -f scripts/seed-delegation-knowledge.sql

BEGIN;

-- Ensure NOVA entity exists (should be entity_id=1)
INSERT INTO entities (id, name, type, created_at)
VALUES (1, 'NOVA', 'ai', NOW())
ON CONFLICT (id) DO NOTHING;

-- Remove any existing delegation facts (for idempotent seeding)
DELETE FROM entity_facts 
WHERE entity_id = 1 AND key IN ('delegates_to', 'task_delegation', 'agent_capability', 'agent_success', 'agent_failure');

-- Seed basic agent relationships from the agents table
-- This creates foundational "delegates_to" facts
INSERT INTO entity_facts (entity_id, key, value, confidence, data_type, source)
SELECT 
    1 as entity_id,
    'delegates_to' as key,
    nickname || ' for ' || COALESCE(role, 'general tasks') as value,
    1.0 as confidence,
    'permanent' as data_type,
    'seed:agents_table' as source
FROM agents 
WHERE status = 'active' 
  AND instance_type IN ('subagent', 'peer')
  AND nickname IS NOT NULL
ORDER BY id;

-- Seed agent capabilities from descriptions (where available)
INSERT INTO entity_facts (entity_id, key, value, confidence, data_type, source)
SELECT 
    1 as entity_id,
    'agent_capability' as key,
    nickname || ': ' || description as value,
    0.8 as confidence,  -- Lower confidence since it's inferred from description
    'observation' as data_type,
    'seed:agents_table' as source
FROM agents 
WHERE status = 'active' 
  AND instance_type IN ('subagent', 'peer')
  AND nickname IS NOT NULL
  AND description IS NOT NULL
  AND description != ''
ORDER BY id;

-- Add specialized task associations based on known roles
-- These are high-confidence mappings for common delegation patterns
INSERT INTO entity_facts (entity_id, key, value, confidence, data_type, source) VALUES
-- Coding tasks
(1, 'task_delegation', 'code debugging → Coder', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'script writing → Coder', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'refactoring code → Coder', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'syntax errors → Coder', 1.0, 'permanent', 'seed:role_mapping'),

-- Git operations
(1, 'task_delegation', 'git commit → Gidget', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'git push → Gidget', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'branch management → Gidget', 1.0, 'permanent', 'seed:role_mapping'),

-- Research
(1, 'task_delegation', 'web research → Scout', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'information lookup → Scout', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'fact finding → Scout', 1.0, 'permanent', 'seed:role_mapping'),

-- Creative work
(1, 'task_delegation', 'image generation → IRIS', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'visual design → IRIS', 1.0, 'permanent', 'seed:role_mapping'),

-- Documentation
(1, 'task_delegation', 'writing documentation → Scribe', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'README creation → Scribe', 1.0, 'permanent', 'seed:role_mapping'),

-- Portfolio
(1, 'task_delegation', 'stock analysis → Ticker', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'portfolio tracking → Ticker', 1.0, 'permanent', 'seed:role_mapping'),

-- Media
(1, 'task_delegation', 'media curation → Athena', 1.0, 'permanent', 'seed:role_mapping'),
(1, 'task_delegation', 'movie/podcast recommendations → Athena', 1.0, 'permanent', 'seed:role_mapping');

-- Create a summary view for easy inspection
CREATE OR REPLACE VIEW delegation_knowledge AS
SELECT 
    ef.id,
    ef.key,
    ef.value,
    ef.confidence,
    ef.data_type,
    ef.source,
    ef.learned_at,
    ef.updated_at
FROM entity_facts ef
WHERE ef.entity_id = 1 
  AND ef.key IN ('delegates_to', 'task_delegation', 'agent_capability', 'agent_success', 'agent_failure')
ORDER BY 
    CASE ef.key
        WHEN 'delegates_to' THEN 1
        WHEN 'task_delegation' THEN 2
        WHEN 'agent_capability' THEN 3
        WHEN 'agent_success' THEN 4
        WHEN 'agent_failure' THEN 5
        ELSE 6
    END,
    ef.confidence DESC,
    ef.value;

COMMIT;

-- Summary report
SELECT 'Delegation facts seeded:' as message, COUNT(*) as count 
FROM entity_facts 
WHERE entity_id = 1 AND key IN ('delegates_to', 'task_delegation', 'agent_capability', 'agent_success', 'agent_failure');

SELECT 'Active agents:' as message, COUNT(*) as count 
FROM agents 
WHERE status = 'active' AND instance_type IN ('subagent', 'peer');

-- Show what was created
\echo '\n=== Delegation Knowledge Summary ===\n'
SELECT key, COUNT(*) as count, AVG(confidence)::numeric(3,2) as avg_confidence
FROM entity_facts 
WHERE entity_id = 1 AND key IN ('delegates_to', 'task_delegation', 'agent_capability')
GROUP BY key
ORDER BY key;

\echo '\n=== Sample Delegation Facts ===\n'
SELECT key, value, confidence, source
FROM entity_facts 
WHERE entity_id = 1 AND key IN ('delegates_to', 'task_delegation', 'agent_capability')
ORDER BY key, confidence DESC
LIMIT 15;
