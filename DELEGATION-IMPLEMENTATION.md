# Agent Delegation Memory - Implementation Guide

## Overview

This implementation integrates agent delegation knowledge into NOVA's memory system, making it searchable via semantic recall instead of relying on runtime keyword hints.

## Architecture

```
User Query: "Can you help me debug this code?"
                      ↓
            Semantic Recall (proactive-recall.py)
                      ↓
     Search memory_embeddings for similar context
                      ↓
    Match: "NOVA delegates to Coder for coding tasks"
                      ↓
         Context injected into agent prompt
                      ↓
      NOVA sees delegation knowledge automatically
```

## Files Created/Modified

### New Files

1. **`docs/agent-delegation-memory.md`** - Architecture and design documentation
2. **`scripts/seed-delegation-knowledge.sql`** - Populates initial delegation facts
3. **`scripts/embed-delegation-facts.sh`** - Generates embeddings for delegation facts
4. **`scripts/test-delegation-memory.sh`** - End-to-end testing script
5. **`DELEGATION-IMPLEMENTATION.md`** - This file

### Modified Files

1. **`scripts/extract-memories.sh`** - Updated to recognize delegation patterns in conversations
   - Backup created at `scripts/extract-memories.sh.backup`
   - Added DELEGATION CONTEXT section to extraction prompt

## Installation

### Step 1: Seed Initial Delegation Knowledge

```bash
cd ~/clawd/nova-memory
psql -h localhost -U nova -d nova_memory -f scripts/seed-delegation-knowledge.sql
```

**What this does:**
- Extracts agent roster from `agents` table
- Creates `delegates_to` facts for each agent
- Adds task-specific delegation mappings (e.g., "code debugging → Coder")
- Creates capabilities based on agent descriptions
- Sets up a `delegation_knowledge` view for easy inspection

**Expected output:**
```
Delegation facts seeded: 30+ facts
Active agents: 9 agents

=== Delegation Knowledge Summary ===
delegates_to     | 9  | 1.0
task_delegation  | 18 | 1.0
agent_capability | 5  | 0.8
```

### Step 2: Generate Embeddings

```bash
cd ~/clawd/nova-memory
./scripts/embed-delegation-facts.sh
```

**What this does:**
- Reads delegation facts from database
- Generates OpenAI embeddings for each fact
- Stores embeddings in `memory_embeddings` table
- Makes delegation knowledge semantically searchable

**Expected output:**
```
🧠 Embedding delegation facts for semantic recall...
📝 Found 32 new delegation facts to embed
✅ [1/32] Embedded: NOVA delegates to Coder for coding
✅ [2/32] Embedded: NOVA delegates to Gidget for git-ops
...
🎯 Embedding complete!
```

**Requirements:**
- `OPENAI_API_KEY` in environment or `~/.secrets/openai-api-key`
- ~32 API calls (~$0.01 cost for embedding-3-small)

### Step 3: Test the System

```bash
cd ~/clawd/nova-memory
./scripts/test-delegation-memory.sh
```

**What this tests:**
1. Delegation facts exist in database
2. Embeddings are generated
3. Sample delegation knowledge
4. Semantic search works
5. Memory extraction recognizes delegation patterns

**Expected output:**
```
✅ Delegation memory system is operational!

Try queries like:
  • 'help me debug this code' → should surface Coder
  • 'commit these changes' → should surface Gidget
  • 'research this topic' → should surface Scout
```

## Usage

### Semantic Recall (Automatic)

When a message arrives, the semantic recall hook automatically searches for relevant delegation knowledge:

```bash
# This happens automatically in the Clawdbot hook
python3 ~/clawd/nova-memory/scripts/proactive-recall.py "help me fix this bug" --inject
```

**Result:**
```json
{
  "memories": [
    {
      "content": "NOVA delegates to Coder for coding tasks",
      "similarity": 0.85,
      "confidence": 1.0
    },
    {
      "content": "For tasks involving code debugging → Coder, NOVA delegates appropriately",
      "similarity": 0.82,
      "confidence": 1.0
    }
  ]
}
```

### Manual Queries

Test semantic search directly:

```bash
# Coding tasks
python3 scripts/proactive-recall.py "I need help debugging Python code"

# Git operations
python3 scripts/proactive-recall.py "commit and push these changes"

# Research
python3 scripts/proactive-recall.py "find information about quantum computing"
```

### Database Queries

```sql
-- View all delegation knowledge
SELECT * FROM delegation_knowledge;

-- Find what NOVA delegates for coding
SELECT value FROM entity_facts 
WHERE entity_id = 1 
  AND category = 'delegation'
  AND value LIKE '%Coder%';

-- See agent capabilities
SELECT value FROM entity_facts
WHERE entity_id = 1
  AND key = 'agent_capability'
ORDER BY confidence DESC;
```

### Memory Extraction

The updated memory extractor automatically recognizes delegation patterns:

```bash
export SENDER_NAME="I)ruid"
echo "[USER] Can you fix this bug?
[CURRENT NOVA MESSAGE] Let me get Coder to help with that." | \
./scripts/extract-memories.sh
```

**Output:**
```json
{
  "facts": [
    {
      "subject": "NOVA",
      "predicate": "delegates_to",
      "value": "Coder for bug fixing",
      "confidence": 1.0,
      "visibility": "public"
    }
  ]
}
```

## Learning Over Time

As NOVA delegates tasks and agents complete them, the memory extractor will capture:

1. **Successful delegations** → increases confidence in agent capabilities
2. **Failed attempts** → records lessons learned
3. **New specializations** → discovers what each agent is actually good at

Example conversation:
```
[USER] Can you optimize this database query?
[NOVA] Let me get Coder to help with that.
[Later...]
[NOVA] Coder successfully optimized the query, reducing execution time by 40%.
```

Extracted memory:
```json
{
  "facts": [
    {
      "subject": "NOVA",
      "predicate": "agent_success",
      "value": "Coder: successfully optimized database query, 40% faster",
      "confidence": 1.0,
      "category": "delegation"
    }
  ]
}
```

This gets embedded and becomes searchable: future queries about "database optimization" will surface Coder as a capable agent.

## Maintenance

### Re-embedding Facts

If you update delegation facts manually, re-run the embedding script:

```bash
./scripts/embed-delegation-facts.sh
```

It only embeds new/changed facts (idempotent).

### Cleaning Up Old Facts

```sql
-- Remove low-confidence delegation facts older than 90 days
DELETE FROM entity_facts
WHERE category = 'delegation'
  AND confidence < 0.5
  AND learned_at < NOW() - INTERVAL '90 days';

-- Then re-embed
-- ./scripts/embed-delegation-facts.sh
```

### Adding New Agents

When a new agent is added to the `agents` table:

```bash
# Re-run seed script (it's idempotent)
psql -h localhost -U nova -d nova_memory -f scripts/seed-delegation-knowledge.sql

# Embed new facts
./scripts/embed-delegation-facts.sh
```

## Integration Points

### 1. Clawdbot Hooks

The existing `semantic-recall` hook automatically uses this system:
- Hook: `~/clawd/hooks/semantic-recall/`
- On `message:received`, it queries `proactive-recall.py`
- Delegation knowledge is injected if semantically relevant

### 2. Memory Extraction

The `memory-extract` hook (if configured) uses the updated `extract-memories.sh`:
- Hook: `~/clawd/hooks/memory-extract/` (if exists)
- Automatically captures delegation patterns from conversations
- No manual intervention needed

### 3. OpenClaw Session Memory

OpenClaw 2026.2.6+ has native session memory indexing. This is **complementary**:
- Session memory: raw conversational context
- NOVA memory: structured delegation knowledge
- Both are searched during semantic recall

## Migration from Hook Approach

The old `agent-delegation-hints` hook (keyword-based) can coexist during transition:

```bash
# Old hook location
ls ~/clawd/hooks/agent-delegation-hints/

# Status: Can be deprecated once memory system is populated
# No breaking changes - both systems work independently
```

**Recommendation:** Keep the hook for 2-4 weeks while delegation memories accumulate, then disable it.

## Troubleshooting

### No results from semantic search

```bash
# Check if facts exist
psql -h localhost -U nova -d nova_memory -c "SELECT COUNT(*) FROM entity_facts WHERE category='delegation';"

# Check if embeddings exist
psql -h localhost -U nova -d nova_memory -c "SELECT COUNT(*) FROM memory_embeddings WHERE source_type='entity_fact';"

# Re-embed if needed
./scripts/embed-delegation-facts.sh
```

### Memory extraction not recognizing delegation

Check the updated prompt:
```bash
grep -A 20 "DELEGATION CONTEXT" ~/clawd/nova-memory/scripts/extract-memories.sh
```

If missing, restore from backup and re-apply:
```bash
# Backup is at: ~/clawd/nova-memory/scripts/extract-memories.sh.backup
```

### OpenAI API errors

```bash
# Check API key
echo $OPENAI_API_KEY

# Or check secrets file
cat ~/.secrets/openai-api-key

# Test API directly
curl https://api.openai.com/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY"
```

## Performance

- **Seed script**: ~1 second (30-40 facts)
- **Embedding script**: ~5-10 seconds (30-40 API calls)
- **Semantic search**: ~200-300ms per query
- **Memory extraction**: ~1-2 seconds per message (unchanged)

## Cost

- **Initial setup**: ~$0.01 (32 embeddings @ $0.0003/1K tokens)
- **Ongoing**: Near zero (only new delegation facts)
- **Semantic search**: Free (uses existing embeddings)

## Next Steps

1. ✅ Seed initial delegation knowledge
2. ✅ Generate embeddings
3. ✅ Test semantic recall
4. 🔄 Monitor memory extraction for delegation patterns
5. 🔄 Accumulate experience-based delegation knowledge
6. 📊 Review in 2-4 weeks: compare to keyword-based hook performance
7. 🗑️ Deprecate `agent-delegation-hints` hook once confident

## Success Metrics

Track these to measure system effectiveness:

```sql
-- Delegation facts added per week
SELECT DATE_TRUNC('week', learned_at) as week, COUNT(*) 
FROM entity_facts 
WHERE category = 'delegation'
GROUP BY week 
ORDER BY week DESC 
LIMIT 4;

-- Agent success rate
SELECT 
    SUBSTRING(value FROM '^[^:]+') as agent,
    COUNT(*) as successes
FROM entity_facts
WHERE key = 'agent_success'
GROUP BY agent
ORDER BY successes DESC;
```

---

**Status:** ✅ Ready for deployment  
**Date:** 2026-02-09  
**Author:** Coder (subagent)  
**Requested by:** NOVA (via I)ruid's pivot request)
