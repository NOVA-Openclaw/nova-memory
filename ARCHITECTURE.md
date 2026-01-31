# NOVA Memory System - Architecture

## Data Flow Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MESSAGE PROCESSING FLOW                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐                                                        │
│  │   Incoming   │  Signal, Telegram, Discord, etc.                       │
│  │   Message    │                                                        │
│  └──────┬───────┘                                                        │
│         │                                                                │
│         ▼                                                                │
│  ┌──────────────┐     ┌─────────────────┐                               │
│  │   Clawdbot   │────►│  Claude API     │  Main conversation            │
│  │   Gateway    │◄────│  (Response)     │                               │
│  └──────┬───────┘     └─────────────────┘                               │
│         │                                                                │
│         │ After response (async)                                         │
│         ▼                                                                │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    MEMORY EXTRACTION PIPELINE                     │   │
│  │                                                                   │   │
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐   │   │
│  │  │ process-    │───►│ extract-    │───►│ store-memories.sh   │   │   │
│  │  │ input.sh    │    │ memories.sh │    │                     │   │   │
│  │  │             │    │             │    │ Inserts into        │   │   │
│  │  │ Entry point │    │ Claude API  │    │ PostgreSQL          │   │   │
│  │  │             │    │ parses text │    │                     │   │   │
│  │  └─────────────┘    └─────────────┘    └──────────┬──────────┘   │   │
│  │                                                    │              │   │
│  └────────────────────────────────────────────────────│──────────────┘   │
│                                                       │                  │
│                                                       ▼                  │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                     POSTGRESQL DATABASE                           │   │
│  │                                                                   │   │
│  │  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────────────┐ │   │
│  │  │ entities  │ │  places   │ │  events   │ │ entity_facts      │ │   │
│  │  │           │ │           │ │           │ │                   │ │   │
│  │  │ People,   │ │ Locations │ │ Timeline  │ │ Key-value facts   │ │   │
│  │  │ AIs, orgs │ │ venues    │ │ of events │ │ about entities    │ │   │
│  │  └───────────┘ └───────────┘ └───────────┘ └───────────────────┘ │   │
│  │                                                                   │   │
│  │  ┌───────────────────┐ ┌───────────┐ ┌─────────────────────────┐ │   │
│  │  │ entity_           │ │ projects  │ │ lessons / preferences   │ │   │
│  │  │ relationships     │ │           │ │                         │ │   │
│  │  │                   │ │ Tasks &   │ │ Learned insights &      │ │   │
│  │  │ Connections       │ │ status    │ │ user preferences        │ │   │
│  │  └───────────────────┘ └───────────┘ └─────────────────────────┘ │   │
│  │                                                                   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│                              ▲                                           │
│                              │ Query at session start                    │
│                              │                                           │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                      MEMORY RECALL                                │   │
│  │                                                                   │   │
│  │  memory_search tool → Semantic search MEMORY.md + memory/*.md    │   │
│  │  memory_get tool    → Retrieve specific lines from memory files  │   │
│  │  SQL queries        → Direct database lookups for structured data│   │
│  │                                                                   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Integration Points

### 1. Current: Manual/On-Demand Processing

Scripts can be run manually to process specific text:

```bash
# Process a single statement
./scripts/process-input.sh "User said they love coffee from Blue Bottle"

# Process a conversation log
cat conversation.txt | ./scripts/process-input.sh
```

### 2. Planned: Heartbeat Integration

During periodic heartbeat checks, process recent conversation context:

```bash
# In HEARTBEAT.md or cron job
# Extract memories from recent messages
recent_messages | ./scripts/process-input.sh
```

### 3. Planned: Real-time Processing

Hook into Clawdbot message pipeline to process each message:

```
Message received → Response generated → Async: extract & store memories
```

## Script Details

### extract-memories.sh

**Input:** Natural language text (string)
**Output:** Structured JSON

Uses Claude API with a carefully crafted prompt to identify:
- Named entities (people, places, things)
- Facts (objective information)
- Opinions (subjective, attributed to holder)
- Preferences (likes/dislikes)
- Events (things that happened)
- Relationships (connections between entities)

**Key feature:** Distinguishes between facts and opinions, always attributing opinions to the person who holds them.

### store-memories.sh

**Input:** JSON from extract-memories.sh
**Output:** Database insertions

Maps extracted data to database tables:
- `entities[]` → `entities` table
- `places[]` → `places` table  
- `facts[]` → `entity_facts` table
- `opinions[]` → `entity_facts` with `opinion_` prefix
- `preferences[]` → `entity_facts` with `preference_` prefix

### process-input.sh

**Input:** Natural language text
**Output:** JSON + database insertions

Convenience wrapper that chains extract → store.

## Memory Recall

The stored memories are accessed via:

1. **Semantic search** - `memory_search` tool searches markdown files
2. **Direct SQL** - Query database for structured lookups
3. **Session context** - Key facts loaded at session start

Example queries:
```sql
-- Get all facts about a person
SELECT * FROM v_entity_facts WHERE entity_name = 'I)ruid';

-- Get relationships
SELECT * FROM v_relationships WHERE entity1 = 'NOVA';

-- Find places by type
SELECT * FROM places WHERE type = 'restaurant';
```

## Future Enhancements

- [ ] Real-time message hook in Clawdbot
- [ ] Confidence decay over time
- [ ] Contradiction detection
- [ ] Memory consolidation (merge related facts)
- [ ] Vector embeddings for semantic search
