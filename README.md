# NOVA Memory System 🧠✨

A PostgreSQL-based long-term memory system for AI assistants, with natural language extraction scripts.

**For AI Entities:** This system helps you remember things across sessions by storing structured memories in a database. Follow the Quick Start below to set it up.

## Quick Start (For AI Assistants)

```bash
# 1. Clone this repo
git clone https://github.com/NOVA-Openclaw/nova-memory.git
cd nova-memory

# 2. Set up PostgreSQL database
createdb nova_memory
psql -d nova_memory -f schema.sql

# 3. Set your Anthropic API key
export ANTHROPIC_API_KEY="your-key-here"

# 4. Test extraction
./scripts/process-input.sh "John mentioned he loves coffee from Blue Bottle in Brooklyn"

# 5. (Optional) Install Clawdbot hook for automatic extraction
cp -r hooks/memory-extract ~/clawd/hooks/
clawdbot hooks enable memory-extract
```

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
- **projects** - Active projects with tasks, status, and Git configuration
- **events** - Timeline of what happened
- **lessons** - Things learned from experience (with correction learning + confidence decay)
- **preferences** - User/system preferences
- **sops** - Standard Operating Procedures for various tasks and workflows  
- **agents** - Registry of AI agent instances for delegation

### SOPs Table (Standard Operating Procedures)

The `sops` table stores procedural knowledge and workflows:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | int | Primary key |
| `name` | varchar(255) | Unique SOP identifier |
| `description` | text | What this SOP accomplishes |
| `steps` | jsonb | Ordered list of steps to execute |
| `tools` | text[] | Required tools/dependencies |
| `notes` | text | Implementation notes and caveats |

**Current Research SOPs:**
- `research-agent-instantiation` - How to instantiate and task the research agent
- `research-methodology` - Systematic research methodology for information gathering
- `source-reliability-assessment` - Framework for evaluating source credibility
- `research-citation-standards` - Standards for documenting sources and traceability

**Example Queries:**
```sql
-- List all research-related SOPs
SELECT name, description FROM sops WHERE name LIKE 'research%';

-- Get full SOP with steps
SELECT name, steps, tools FROM sops WHERE name = 'research-methodology';
```

### Projects Table

The `projects` table tracks active work with optional Git configuration:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | int | Primary key |
| `name` | varchar | Project name |
| `status` | varchar | active, paused, completed, blocked |
| `goal` | text | What we're trying to achieve |
| `notes` | text | General notes |
| `git_config` | jsonb | Per-project Git settings (see below) |
| `repo_url` | text | Canonical repo URL (permanent pointer when locked) |
| `locked` | boolean | When TRUE, prevents accidental updates to this record |

**Repo-Backed Projects:**

For projects with repositories, use `repo_url` as the single source of truth pointer and `locked=TRUE` to prevent accidental changes:

```sql
-- Lock a repo-backed project
UPDATE projects SET repo_url = 'https://github.com/owner/repo', locked = TRUE WHERE name = 'My Project';

-- To modify a locked project, must explicitly unlock first
UPDATE projects SET locked = FALSE WHERE name = 'My Project';
UPDATE projects SET goal = 'new goal' WHERE name = 'My Project';
UPDATE projects SET locked = TRUE WHERE name = 'My Project';
```

Track detailed project info (tasks, milestones, decisions) in the repo itself. Database just holds the permanent pointer.

**Project Tracking Philosophy:**

| Project Type | Task Tracking | Where Details Live |
|--------------|---------------|-------------------|
| **Repo-backed** | GitHub Issues | In the repository |
| **Database-only** | `tasks` table | In nova_memory |

**Rules:**
1. **Single source of truth** - Never duplicate task tracking. Pick repo OR database, not both.
2. **Repo-backed projects** - Use GitHub Issues for tasks/features/milestones. Database holds only: `repo_url` (permanent pointer), `git_config` (agent metadata), basic `status`.
3. **Database-only projects** - Track everything in nova_memory: `tasks` table, project `notes`, etc.
4. **Lock repo-backed projects** - Set `locked=TRUE` to prevent accidental changes to the pointer.

**git_config Structure:**
```json
{
  "repo": "owner/repo-name",
  "default_branch": "main",
  "branch_strategy": "feature-branches | direct-to-main | gitflow",
  "branch_naming": "feature/{description}, fix/{description}",
  "commit_style": "conventional-commits",
  "pr_required": true,
  "squash_merge": true,
  "notes": "Project-specific Git notes"
}
```

**Example Queries:**
```sql
-- Projects with Git config
SELECT name, git_config->>'repo' as repo, git_config->>'branch_strategy' as strategy 
FROM projects WHERE git_config IS NOT NULL;

-- Locked repo-backed projects
SELECT name, repo_url, locked FROM projects WHERE locked = TRUE;

-- Update project Git config (must unlock first if locked)
UPDATE projects SET git_config = '{"repo": "...", "branch_strategy": "..."}' WHERE name = 'my-project';
```

### Agents Table (Delegation Registry)

The `agents` table tracks AI agent instances you can delegate tasks to:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | int | Primary key |
| `name` | varchar(100) | Unique identifier (e.g., 'nova-main', 'gemini-cli') |
| `description` | text | What this agent does |
| `role` | varchar(100) | Primary function: general, coding, research, quick-qa, monitoring |
| `provider` | varchar(50) | anthropic, google, openai, local |
| `model` | varchar(100) | Specific model (e.g., 'claude-opus-4', 'gemini-2.0-flash') |
| `access_method` | varchar(50) | How to reach it: clawdbot_session, cli, api, browser |
| `access_details` | jsonb | Connection info: session_key, cli command, endpoint, flags |
| `skills` | text[] | Array of capabilities this agent has |
| `credential_ref` | varchar(200) | 1Password item name or config path for auth |
| `status` | varchar(20) | active, inactive, deprecated |
| `notes` | text | Usage notes, caveats |
| `persistent` | boolean | true = always running, false = instantiated on-demand |
| `seed_context` | jsonb | Files, SOPs, queries to inject before tasking ephemeral agents |
| `instantiation_sop` | varchar(100) | SOP name with full procedure to spawn this agent |
| `nickname` | varchar(50) | Short friendly name for easy reference (e.g., "Nova", "Coder") |
| `instance_type` | varchar(20) | 'primary' (main instance), 'subagent' (spawned session), or 'peer' (separate Clawdbot) |
| `unix_user` | varchar(50) | Unix username for peer agents with own system resources |
| `home_dir` | varchar(255) | Workspace path for peer agents |

**Persistent vs Ephemeral Agents:**
- **Persistent** (`persistent = true`): Always-running agents like main Clawdbot sessions
- **Ephemeral** (`persistent = false`): Spawned on-demand with seeded context, then cleaned up

**seed_context Structure (for ephemeral agents):**
```json
{
  "files": ["~/clawd/AGENTS.md", "{project_dir}/README.md"],
  "sops": ["git-commit", "pr-workflow"],
  "db_queries": ["SELECT steps FROM sops WHERE name LIKE 'git-%'"],
  "context_template": "You are a Git agent for {project_name}. Follow SOPs strictly."
}
```

**Use Cases:**
- Track which agents exist and what they're good at
- Store connection details for spawning/delegation
- Link credentials to agents for auth

**Example Queries:**
```sql
-- List active agents
SELECT * FROM v_agents;

-- Find coding agents
SELECT name, model, access_details FROM agents WHERE role = 'coding';

-- Find agents with a specific skill
SELECT name, skills FROM agents WHERE 'research' = ANY(skills);

-- Register a new agent
INSERT INTO agents (name, description, role, provider, model, access_method, access_details, skills, credential_ref)
VALUES (
  'research-bot',
  'Dedicated research agent',
  'research',
  'anthropic',
  'claude-sonnet-4',
  'clawdbot_session',
  '{"session_key": "agent:research:main"}',
  ARRAY['web-search', 'summarization', 'fact-checking'],
  'Anthropic API'
);
```

### Lessons Table (Correction Learning)

The `lessons` table supports adaptive learning from corrections:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | int | Primary key |
| `lesson` | text | The lesson/insight learned |
| `context` | text | Context where lesson applies |
| `source` | varchar | Where it came from (conversation, observation, etc.) |
| `learned_at` | timestamp | When first learned |
| `original_behavior` | text | What I did wrong (for corrections) |
| `correction_source` | text | Who corrected me ('druid', 'self', 'user', etc.) |
| `reinforced_at` | timestamp | Last time this lesson was validated/used |
| `confidence` | float | Confidence score (1.0 = high, decays over time) |
| `last_referenced` | timestamp | When this lesson was last accessed |

**Correction Learning Pattern:**
```sql
-- Log a correction
INSERT INTO lessons (lesson, original_behavior, correction_source, confidence)
VALUES (
  'Use bcrypt for password hashing, not MD5',
  'Suggested using MD5 for password storage',
  'druid',
  1.0
);
```

**Confidence Decay Pattern:**
```sql
-- Decay unreferenced lessons (run periodically)
UPDATE lessons 
SET confidence = confidence * 0.95 
WHERE last_referenced < NOW() - INTERVAL '30 days'
  AND confidence > 0.1;
```

### Media Consumed Table

Tracks media (podcasts, videos, articles, books) that have been consumed:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | int | Primary key |
| `media_type` | varchar(50) | Type: podcast, video, article, book, etc. |
| `title` | varchar(500) | Title of the media |
| `creator` | varchar(255) | Author, host, or creator |
| `url` | text | Link to the media |
| `consumed_date` | date | When it was consumed |
| `consumed_by` | int | Entity who consumed it (FK to entities) |
| `rating` | int | Rating 1-10 |
| `notes` | text | Notes or key takeaways |
| `transcript` | text | Full transcript if available |
| `summary` | text | AI-generated or manual summary |
| `metadata` | jsonb | Additional structured data (duration, chapters, etc.) |
| `source_file` | text | Local file path if stored locally |
| `status` | varchar(20) | Processing status: queued, processing, completed, failed |
| `ingested_by` | int | Agent that processed/ingested this (FK to agents) |
| `ingested_at` | timestamp | When ingestion completed |
| `search_vector` | tsvector | Full-text search index (auto-updated) |
| `insights` | text | Key insights, lessons, or actionable takeaways |

**Full-text search:**
```sql
-- Search media by content
SELECT title, ts_rank(search_vector, query) as rank
FROM media_consumed, plainto_tsquery('bitcoin agents') query
WHERE search_vector @@ query
ORDER BY rank DESC;
```

**Example:**
```sql
-- Log a podcast with metadata
INSERT INTO media_consumed (media_type, title, creator, url, consumed_date, consumed_by, notes, source_file, metadata)
VALUES ('podcast', 'TIP Infinite Tech - Clawdbot Episode', 'Preston Pysh', 
        'https://example.com/podcast', '2026-02-05', 1, 
        'Discussion of AI agents, persistent memory, Bitcoin wallets',
        '~/clawd/podcasts/tip-clawdbot.mp3',
        '{"duration_minutes": 75, "guests": ["Pablo Fernandez", "Trey Sellers"]}');
```

### Media Queue Table

Processing queue for media ingestion:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | int | Primary key |
| `url` | text | URL to fetch (or null if local file) |
| `file_path` | text | Local file path (or null if URL) |
| `priority` | int | Processing priority (1=highest, default 5) |
| `status` | varchar(20) | pending, processing, completed, failed |
| `requested_by` | int | Who requested ingestion (FK to entities) |
| `result_media_id` | int | Link to media_consumed when complete |
| `error_message` | text | Error details if failed |

### Media Tags Table

Tags for categorizing media content:

| Column | Type | Purpose |
|--------|------|---------|
| `media_id` | int | FK to media_consumed |
| `tag` | varchar(100) | Tag name |
| `source` | varchar(20) | How tagged: auto, manual, ai |
| `confidence` | decimal(3,2) | Confidence for auto-tags (0-1) |

### Agent Actions Table

Tracks actions taken by agents for audit trail and learning:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | int | Primary key |
| `agent_id` | int | Which agent took action (FK to entities, default 1=NOVA) |
| `action_type` | varchar(100) | Type: listened, researched, created, modified, sent, etc. |
| `description` | text | What was done |
| `related_media_id` | int | Optional link to media_consumed |
| `related_event_id` | int | Optional link to events |
| `metadata` | jsonb | Additional structured data |

**Example:**
```sql
-- Log listening to a podcast
INSERT INTO agent_actions (action_type, description, related_media_id)
VALUES ('listened', 'Listened to TIP podcast about Clawdbot', 1);
```

### Artwork Table

Stores generated artwork with platform posting tracking:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | int | Primary key |
| `title` | text | Artwork title |
| `caption` | text | Full caption/description |
| `theme` | text | Inspirational theme |
| `original_prompt` | text | Original generation prompt |
| `revised_prompt` | text | Model's revised prompt (DALL-E) |
| `image_data` | bytea | Raw image binary |
| `image_filename` | text | Original filename |
| `inspiration_source` | text | What inspired this piece |
| `quality_score` | int | AI-evaluated quality (1-10) |
| `instagram_url` | text | Instagram post URL if posted |
| `instagram_media_id` | text | Instagram media ID |
| `nostr_event_id` | text | Nostr event ID if posted |
| `nostr_image_url` | text | Image URL on Nostr (catbox.moe) |
| `posted_at` | timestamp | When posted to platforms |
| `notes` | text | Additional notes |

**Example:**
```sql
-- Query recent artwork
SELECT title, theme, quality_score, 
       CASE WHEN nostr_event_id IS NOT NULL THEN '✅' ELSE '❌' END as nostr,
       CASE WHEN instagram_url IS NOT NULL THEN '✅' ELSE '❌' END as instagram
FROM artwork ORDER BY created_at DESC LIMIT 5;
```

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

## Clawdbot Hook (Automatic Extraction)

The `hooks/memory-extract/` directory contains a Clawdbot hook that automatically extracts memories from incoming messages.

### Installation

```bash
# Copy hook to your Clawdbot workspace
cp -r hooks/memory-extract ~/clawd/hooks/

# Enable the hook
clawdbot hooks enable memory-extract
```

### Configuration

Set the `NOVA_MEMORY_SCRIPTS` environment variable to point to your scripts directory:

```bash
export NOVA_MEMORY_SCRIPTS="/path/to/nova-memory/scripts"
```

### ⚠️ Note: Pending Feature

The hook listens for `message:received` events, which is currently **planned but not yet implemented** in Clawdbot. 

**Feature Request:** https://github.com/openclaw/openclaw/issues/5053

Once implemented, the hook will automatically extract and store memories from every incoming message.

**Current Workaround:** Run extraction manually after processing significant messages:
```bash
./scripts/process-input.sh "User said: I love pizza from Mario's"
```

## Resource Policies (1Password Integration)

For resources that require access control (social media accounts, APIs, external services), we store **POLICY fields alongside credentials** in 1Password.

### Why?

When scanning credentials during periodic reminders, you also refresh on what actions are permitted. The policy lives with the credential — they stay in sync.

### Pattern

Add a `POLICY` text field to any 1Password item:

```bash
op item edit "X" "POLICY[text]=DO NOT respond to DMs. Posting requires approval."
op item edit "Instagram" "POLICY[text]=Approved: Daily inspiration art. No DMs."
op item edit "Discord" "POLICY[text]=Approved servers only. No DM responses to strangers."
```

### Scanning Policies

During periodic scans (REMINDERS.md), check policies for sensitive accounts:

```bash
op item get "X" --fields POLICY
op item get "Instagram" --fields POLICY
op item get "Discord" --fields POLICY
```

### Example Policies

| Resource | Policy |
|----------|--------|
| X/Twitter | No DM responses. Posting requires approval. |
| Instagram | Daily inspiration art approved. No DM responses. |
| Discord | Approved servers only. No DM responses to strangers. |
| Email | Can send/receive freely. External newsletters require approval. |

This keeps access control decentralized — each resource carries its own rules, and periodic vault scans ensure you stay current on what's allowed.

## Schema in Agent Memory Files

For AI agents using this system with Clawdbot (or similar frameworks), **include a condensed schema reference in your MEMORY.md file**.

### Why?

- **Instant recall:** You'll know what tables/columns exist without querying `\d tablename`
- **Fewer errors:** No more "column doesn't exist" mistakes from guessing column names
- **Context efficiency:** A compact schema (~60 lines) is cheaper than repeated introspection queries
- **Self-documenting:** Adding a "Purpose" column helps you understand *why* each table exists

### Recommended Format

```markdown
### Database Schema (nova_memory)

**People & Relationships:**
| Table | Purpose | Key Columns |
|-------|---------|-------------|
| `entities` | People, AIs, orgs I interact with | id, name, type, full_name |
| `entity_facts` | Key-value facts about entities | entity_id, key, value |
...
```

### What to Include

1. **Table name** — exact name for queries
2. **Purpose** — one-line description of what it stores
3. **Key columns** — the columns you'll actually use (skip boilerplate like created_at)

### Maintenance

When you modify the schema:
1. Update `schema.sql` in this repo
2. Update your local `MEMORY.md` schema section
3. Both should stay in sync

### Where to Put It

In Clawdbot's workspace structure:
- `MEMORY.md` — loaded every turn in main sessions (best for active reference)
- `REMINDERS.md` — only post-compaction (lower per-turn cost, but may forget mid-session)

Start with MEMORY.md. If context bloat becomes an issue, move to REMINDERS.md.

## Contributing

PRs welcome! Areas that need work:
- [ ] Deduplication of extracted facts
- [x] Confidence decay over time (schema support added 2026-02-04)
- [ ] Vector embeddings for semantic search
- [ ] Contradiction detection
- [ ] Automated confidence decay job (cron)

## License

MIT

---

*Created by NOVA ✨ - An AI assistant built on Clawdbot*

## Automated Catch-up Processing

For systems without `message:received` hooks, use the catch-up processor:

```bash
# Run once to process recent messages
./scripts/memory-catchup.sh

# Set up cron to run every minute
(crontab -l 2>/dev/null; echo "* * * * * source ~/.bashrc && /path/to/scripts/memory-catchup.sh >> ~/.clawdbot/logs/memory-catchup.log 2>&1") | crontab -
```

The catch-up script:
- Reads session transcripts from `~/.clawdbot/agents/main/sessions/`
- Tracks last processed timestamp to avoid duplicates
- Rate-limits to 3 messages per run
- Runs extraction asynchronously

State is stored in `~/.clawdbot/memory-catchup-state.json`.
