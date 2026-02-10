# NOVA Memory System 🧠✨

A PostgreSQL-based long-term memory system for AI assistants, with natural language extraction scripts.

**For AI Entities:** This system helps you remember things across sessions by storing structured memories in a database. Follow the Quick Start below to set it up.

## ⚡ Quick Start (Recommended - NEW!)

**One-command installation:**

```bash
cd ~/clawd/nova-memory
./install.sh
```

The installer will:
- ✅ Check all prerequisites (PostgreSQL, psql, pgvector)
- ✅ Create/verify database (named `{username}_memory`, e.g., `nova_memory`)
- ✅ Apply schema (idempotent - safe to run multiple times)
- ✅ Install hooks to OpenClaw workspace
- ✅ Set up all scripts with correct permissions
- ✅ Verify everything is working

**Note:** The database name is automatically generated from your OS username:
- User `nova` → database `nova_memory`
- User `nova-staging` → database `nova_staging_memory`
- User `argus` → database `argus_memory`

This allows multiple users to run nova-memory on the same PostgreSQL instance without conflicts.

Then enable the hooks:
```bash
openclaw hooks enable memory-extract
openclaw hooks enable semantic-recall
openclaw hooks enable session-init
```

📖 **Full documentation:** See [INSTALLATION.md](./INSTALLATION.md)

🔍 **Verify installation:** Run `./verify-installation.sh`

## Manual Installation (Old Method)

<details>
<summary>Click to expand manual installation steps</summary>

```bash
# 1. Clone this repo
git clone https://github.com/NOVA-Openclaw/nova-memory.git

# 2. Set up PostgreSQL database
cd nova-memory
# Database name is based on your username (e.g., nova_memory, argus_memory)
DB_USER=$(whoami)
DB_NAME="${DB_USER//-/_}_memory"
createdb "$DB_NAME"
psql -d "$DB_NAME" -f schema.sql

# 3. Set your Anthropic API key
export ANTHROPIC_API_KEY="your-key-here"

# 4. Test extraction
./scripts/process-input.sh "John mentioned he loves coffee from Blue Bottle in Brooklyn"

# 5. Install OpenClaw hooks
./install.sh
openclaw hooks enable memory-extract
openclaw hooks enable semantic-recall
openclaw hooks enable session-init
```

</details>

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

### Access Control Architecture

The schema uses two mechanisms to enforce separation of concerns in multi-agent systems:

#### 1. Table-Level Comments (Access Control Documentation)

Every table has a PostgreSQL `COMMENT` explaining its purpose and access rules:

```sql
-- Query a table's access control comment
SELECT obj_description('agents'::regclass, 'pg_class');

-- List all table comments
SELECT c.relname as table_name, obj_description(c.oid, 'pg_class') as access_rules
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY c.relname;
```

**Example comments:**
- `agents` → "Agent registry. READ-ONLY for most agents. Modifications via NHR (Newhart) only."
- `projects` → "Project tracking. For repo-backed projects (locked=TRUE), use GitHub for management."

**Philosophy:** When an agent gets "permission denied", the comment explains *why* and *who* to route the request to. Permission denied is a **signpost**, not just a roadblock.

#### 2. Row-Level Locks (`locked` Column)

Tables like `projects` have a `locked` boolean column with a trigger that prevents updates:

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

**Use case:** Repo-backed projects are locked because their source of truth is GitHub, not the database. The database just holds a pointer.

#### Workflow Example

```
1. NOVA tries: UPDATE agents SET nickname = 'Erato' WHERE name = 'erato';
2. PostgreSQL: "permission denied for table agents"
3. NOVA checks: SELECT obj_description('agents'::regclass, 'pg_class');
4. Comment says: "Modifications via NHR (Newhart) only"
5. NOVA messages Newhart with the update request
6. Newhart (with write access) makes the change
```

This enforces domain ownership without manual discipline—the database itself guides agents to the correct workflow.

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
| `locked` | boolean | When TRUE, project is repo-backed. Use GitHub for management, not this table. |

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
| `collaborative` | boolean | TRUE = work WITH NOVA (dialogue), FALSE = work FOR NOVA (tasks) |
| `config_reasoning` | text | Explanation of why this agent was configured this way |
| `fallback_model` | varchar(100) | Alternative model to use if primary model unavailable |

**Collaborative vs Task-Based Agents:**
- **Collaborative** (`collaborative = true`): Work WITH NOVA in back-and-forth dialogue (e.g., IRIS for art, Newhart for design discussions)
- **Task-Based** (`collaborative = false`): Work FOR NOVA - spawn with a task, return results (e.g., research agent, git agent)

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

### Agent Chat Tables (Inter-Agent Messaging)

The `agent_chat` and `agent_chat_processed` tables enable asynchronous communication between AI agents via PostgreSQL NOTIFY:

**agent_chat** - Message queue for inter-agent communication

| Column | Type | Purpose |
|--------|------|---------|
| `id` | serial | Primary key |
| `channel` | varchar | Logical channel/topic (e.g., 'default', 'tasks') |
| `sender` | varchar | Agent database username who sent the message |
| `message` | text | The message content |
| `mentions` | text[] | Array of agent usernames being addressed |
| `reply_to` | int | Optional reference to parent message id |
| `created_at` | timestamp | When the message was sent |

**agent_chat_processed** - Tracks which agents have processed which messages

| Column | Type | Purpose |
|--------|------|---------|
| `chat_id` | int | Reference to agent_chat.id |
| `agent` | varchar | Agent username (lowercase) |
| `processed_at` | timestamp | When the agent processed the message |

**How it works:**
1. Agent A inserts a message into `agent_chat` with `mentions = ARRAY['agent_b']`
2. PostgreSQL trigger fires `pg_notify('agent_chat', payload)`
3. Agent B's Clawdbot plugin (listening via `LISTEN agent_chat`) receives the notification
4. Plugin checks for unprocessed messages where Agent B is mentioned
5. Message is routed to Agent B's session; marked as processed

**Plugin:** The `agent-chat-channel` Clawdbot plugin handles the LISTEN/NOTIFY integration.  
**Source:** https://github.com/NOVA-Openclaw/nova_scripts (clawdbot-plugins/agent-chat-channel/)

**Example - Send message to another agent:**
```sql
INSERT INTO agent_chat (channel, sender, message, mentions)
VALUES ('default', 'nova', 'Hey, can you review the latest PR?', ARRAY['coder']);
```

### Agent Jobs Tables (Task Routing & Pipelines)

The `agent_jobs` and `job_messages` tables enable task coordination between agents with pipeline routing:

**agent_jobs** - Task tracking with conversation threading

| Column | Type | Purpose |
|--------|------|---------|
| `id` | serial | Primary key |
| `title` | varchar(200) | Short job description |
| `topic` | text | Topic for message matching |
| `job_type` | varchar(50) | message_response, research, creation, review, delegation |
| `agent_name` | varchar(50) | Agent who owns this job |
| `requester_agent` | varchar(50) | Who requested it |
| `parent_job_id` | int | Immediate parent job (for hierarchy) |
| `root_job_id` | int | Original job in pipeline (for tracing) |
| `status` | varchar(20) | pending, in_progress, completed, failed, cancelled |
| `priority` | int | Priority 1-10 (default 5) |
| `notify_agents` | text[] | Agents to notify on completion (fan-out support) |
| `deliverable_path` | text | Path to output file |
| `deliverable_summary` | text | Brief description of results |
| `error_message` | text | Error details if failed |

**job_messages** - Conversation log per job

| Column | Type | Purpose |
|--------|------|---------|
| `job_id` | int | FK to agent_jobs |
| `message_id` | int | FK to agent_chat |
| `role` | varchar(20) | initial, followup, response, context |
| `added_at` | timestamp | When message was linked |

**Key Concepts:**

1. **Jobs as Threads**: Jobs are conversation threads, not 1:1 with messages. Related followup messages get added to existing jobs via topic matching.

2. **Pipeline Routing**: Jobs can route through multiple agents with `notify_agents[]` specifying next hop(s).

3. **Fan-Out**: `notify_agents = ARRAY['agent_a', 'agent_b']` notifies multiple agents on completion.

4. **Root Tracking**: `root_job_id` links to original job for direct pipeline tracing without walking parent chain.

**Example - Create a pipeline job:**
```sql
-- Scout researches, then notifies Newhart AND NOVA when done
INSERT INTO agent_jobs (agent_name, requester_agent, job_type, title, topic, notify_agents)
VALUES ('scout', 'nova', 'research', 'Research authors for Erato', 
        'erato literary agent authors', ARRAY['newhart', 'nova']);
```

**Example - Query pending jobs:**
```sql
SELECT j.id, j.title, j.requester_agent, j.created_at,
       (SELECT COUNT(*) FROM job_messages WHERE job_id = j.id) as message_count
FROM agent_jobs j
WHERE j.agent_name = 'newhart' AND j.status IN ('pending', 'in_progress')
ORDER BY j.priority DESC, j.updated_at DESC;
```

**Example - Get full pipeline tree:**
```sql
WITH RECURSIVE job_tree AS (
  SELECT id, agent_name, title, status, parent_job_id, 0 as depth
  FROM agent_jobs WHERE id = $root_job_id
  UNION ALL
  SELECT j.id, j.agent_name, j.title, j.status, j.parent_job_id, jt.depth + 1
  FROM agent_jobs j JOIN job_tree jt ON j.parent_job_id = jt.id
)
SELECT * FROM job_tree ORDER BY depth, id;
```

**Protocol:** See [nova-cognition/protocols/jobs-system.md](https://github.com/NOVA-Openclaw/nova-cognition/blob/main/protocols/jobs-system.md) for full specification.

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

**Multi-Agent Setup:** For shared database access with multiple agents, see [Database Aliasing Guide](docs/DATABASE-ALIASING.md).

## Schema Updates

When modifying the schema, update both your local database and this repository:

```bash
# After modifying schema.sql
psql -d nova_memory -f schema.sql
git add schema.sql && git commit -m "Update schema: [description]"
git push
```

## OpenClaw Hooks (Automatic Extraction)

The `hooks/` directory contains OpenClaw hooks that automatically extract and manage memories.

### Prerequisites

The hooks require **nova-relationships** for entity resolution. The hooks import via:
```typescript
import { resolveEntity } from "../../../nova-relationships/lib/entity-resolver/index.ts";
```

This expects `~/nova-relationships` to be a symlink to the nova-relationships repo. Install it:

```bash
cd ~/clawd/nova-relationships
./agent-install.sh
```

The installer creates the required `~/nova-relationships` symlink automatically.

### Available Hooks

- **memory-extract** - Extracts structured memories from incoming messages
- **semantic-recall** - Provides contextual memory recall during conversations
- **session-init** - Generates privacy-filtered context when sessions start

### Installation

Run the installation script to symlink hooks to your OpenClaw workspace:

```bash
./install-hooks.sh
```

This creates symlinks from `~/.openclaw/workspace-claude-code/hooks/` to `nova-memory/hooks/`. Symlinks ensure:
- Hooks stay under version control
- Changes are tracked in git
- Updates propagate automatically
- No manual copying needed

### Enable Hooks

```bash
openclaw hooks enable memory-extract
openclaw hooks enable semantic-recall
openclaw hooks enable session-init
```

### Configuration

Set the `NOVA_MEMORY_SCRIPTS` environment variable to point to your scripts directory:

```bash
export NOVA_MEMORY_SCRIPTS="$HOME/clawd/nova-memory/scripts"
```

### ✅ Hook Active

The hooks listen for `message:received` events and trigger on every incoming message.

Memories are automatically extracted and stored from conversations.

**Manual extraction** (if needed):
```bash
./scripts/process-input.sh "User said: I love pizza from Mario's"
```

### Uninstallation

To remove hooks:

```bash
cd ~/.openclaw/workspace-claude-code/hooks/
rm memory-extract semantic-recall session-init
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
(crontab -l 2>/dev/null; echo "* * * * * source ~/.bashrc && /path/to/scripts/memory-catchup.sh >> ~/.openclaw/logs/memory-catchup.log 2>&1") | crontab -
```

The catch-up script:
- Reads session transcripts from `~/.openclaw/agents/main/sessions/`
- Tracks last processed timestamp to avoid duplicates
- Rate-limits to 3 messages per run
- Runs extraction asynchronously

State is stored in `~/.openclaw/memory-catchup-state.json`.

## Context Window (2026-02-07)

The extraction pipeline now maintains a **20-message rolling context window** for improved reference resolution.

### How It Works

1. **Rolling Cache**: Last 20 messages stored in `~/.openclaw/memory-message-cache.json`
2. **Interleaved**: Both user AND assistant messages included chronologically
3. **Bidirectional**: BOTH speakers' messages get extracted, not just user

### Context Format

```
[USER] 1: How much do crawlers cost?
[NOVA] 2: About $130M in today's dollars...
[USER] 3: Let's build one for Burning Man
[NOVA] 4: That would be legendary...
---
[CURRENT USER MESSAGE - EXTRACT FROM THIS]
Yes, keep the aesthetic
```

### Benefits

- **Reference resolution**: "Yes", "that", "do it" now have meaning
- **Self-memory**: NOVA's actions/updates get extracted too
- **Conversation flow**: Full context for both speakers

### Deduplication

**Layer 1 (Prompt)**: Existing facts/vocab queried and included in prompt
**Layer 2 (Storage)**: `store-memories.sh` checks before every insert

### Scripts Updated

- `memory-catchup.sh` - Now processes both roles, builds context cache
- `extract-memories.sh` - Updated prompt for conversation format
- `store-memories.sh` - Added duplicate checking functions
