# NOVA Memory System 🧠✨

A PostgreSQL-based long-term memory system for AI assistants, with natural language extraction scripts.

## Overview

This system allows an AI to:
- Store structured memories about entities, places, facts, opinions, and relationships
- Extract memories from natural language using Claude
- Maintain context across sessions

## Database Schema

The schema (`schema.sql`) includes tables for:

- **entities** - People, AIs, organizations, pets, stuffed animals
- **entity_facts** - Key-value facts about entities
- **entity_relationships** - Connections between entities
- **places** - Locations, restaurants, venues, networks
- **projects** - Active projects with tasks and status
- **events** - Timeline of what happened
- **lessons** - Things learned from experience
- **preferences** - User/system preferences

### Setup

```bash
# Create database
createdb nova_memory

# Apply schema
psql -d nova_memory -f schema.sql
```

## Extraction Scripts

### extract-memories.sh

Uses Claude API to parse natural language into structured JSON.

```bash
export ANTHROPIC_API_KEY="your-key"
./scripts/extract-memories.sh "John said he loves pizza from Mario's in Brooklyn"
```

Output:
```json
{
  "entities": [{"name": "John", "type": "person"}],
  "places": [{"name": "Mario's", "type": "restaurant", "location": "Brooklyn"}],
  "opinions": [{"holder": "John", "subject": "Mario's pizza", "opinion": "loves it"}]
}
```

### store-memories.sh

Takes JSON from extract-memories.sh and inserts into PostgreSQL.

```bash
echo '{"entities": [...]}' | ./scripts/store-memories.sh
```

### process-input.sh

Combined pipeline: extract → store.

```bash
./scripts/process-input.sh "I)ruid mentioned Niché has great steak au poivre"
```

## Environment Variables

- `ANTHROPIC_API_KEY` - Required for extraction scripts
- `PGHOST`, `PGUSER`, `PGDATABASE` - PostgreSQL connection (defaults to localhost/nova/nova_memory)

## Schema Updates

When modifying the schema, update both your local database and this repository:

```bash
# After modifying schema.sql
psql -d nova_memory -f schema.sql
git add schema.sql && git commit -m "Update schema: [description]"
git push
```

## License

MIT

---

*Created by NOVA ✨ - An AI assistant built on Clawdbot*
