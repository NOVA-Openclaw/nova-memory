# nova-memory Installation Guide

This document describes the installation process and recent changes to make nova-memory portable and easy to install.

## Quick Install

```bash
cd ~/clawd/nova-memory
./install.sh
```

The installer is **idempotent** - safe to run multiple times.

## Recent Changes (2026-02-10)

### 1. Hooks Now Use Relative Paths

All hooks have been updated to reference scripts using relative paths instead of hardcoded `~/clawd/scripts/`:

**Before:**
```typescript
const RECALL_SCRIPT = path.join(os.homedir(), "clawd/scripts/proactive-recall.py");
```

**After:**
```typescript
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SCRIPTS_DIR = path.join(__dirname, "..", "..", "scripts");
const RECALL_SCRIPT = path.join(SCRIPTS_DIR, "proactive-recall.py");
```

This allows the repo to be installed anywhere, not just at `~/clawd/`.

**Files Updated:**
- `hooks/memory-extract/handler.ts` - now uses relative path for `process-input.sh`
- `hooks/session-init/handler.ts` - now uses relative path for `generate-session-context.sh`
- `hooks/semantic-recall/handler.ts` - now uses relative path for `proactive-recall.py`

### 2. Comprehensive Installer Script

Created `install.sh` - a fully idempotent installer that:

#### Prerequisites Check
- ✅ Verifies PostgreSQL installed and running
- ✅ Checks for `psql` command
- ⚠️ Warns if `ANTHROPIC_API_KEY` not set
- ✅ Checks for pgvector extension availability

#### Database Setup (Idempotent)
- Creates `nova_memory` database if it doesn't exist
- Applies `schema.sql` (safe to run multiple times)
- Reports what was created vs what already existed
- Counts total tables in database

#### Hooks Installation
- **Copies** (not symlinks) hooks to workspace hooks directory
- **Copies** scripts directory to workspace (so hooks can find them via relative paths)
- OpenClaw wasn't following symlinks reliably
- Detects workspace from `OPENCLAW_WORKSPACE` env or default
- Installs: `memory-extract`, `semantic-recall`, `session-init`

#### Scripts Setup
- Makes all `.sh` and `.py` files executable
- Verifies Python dependencies (psycopg2, anthropic, openai)
- Reports missing dependencies with install command

#### Verification
- Tests database connection
- Runs a simple query to verify schema
- Lists installed hooks
- Provides next steps

## What the Installer Does

### Output Example

```
═══════════════════════════════════════════
  nova-memory installer v1.0
═══════════════════════════════════════════

Checking prerequisites...
  ✅ PostgreSQL installed (16.11)
  ✅ psql command available
  ✅ PostgreSQL service running
  ⚠️  ANTHROPIC_API_KEY not set (extraction will fail)
  ✅ pgvector extension available

Database setup...
  ✅ Database 'nova_memory' exists
  ✅ Database connection verified
  ✅ Schema applied successfully
      Skipped 315 existing objects
      Total tables in database: 55

Hooks installation...
  ✅ memory-extract installed
  ✅ semantic-recall installed
  ✅ session-init installed

Scripts setup...
  ✅ Made 13 scripts executable
  ✅ Python3 available
  ⚠️  Missing Python dependencies: anthropic openai
      Install: pip3 install anthropic openai

Verification...
  ✅ Database connection OK
  ✅ Test query OK (found 55 tables)
  ✅ Installed hooks:
      • memory-extract
      • semantic-recall
      • session-init

═══════════════════════════════════════════
  Installation complete!
═══════════════════════════════════════════
```

## Environment Variables

The installer and hooks use these environment variables:

### Required for Operation
- `ANTHROPIC_API_KEY` - For memory extraction (Claude API)
- `OPENAI_API_KEY` - For embeddings (semantic search)

### Optional Configuration
- `OPENCLAW_WORKSPACE` - Override default workspace path
- `PGUSER` - PostgreSQL user (default: nova)
- `POSTGRES_HOST` - Database host (default: localhost)
- `POSTGRES_DB` - Database name (default: nova_memory)
- `POSTGRES_PASSWORD` - Database password (optional)

### Hook-Specific Settings
- `SEMANTIC_RECALL_TOKEN_BUDGET` - Max tokens for recall (default: 1000)
- `SEMANTIC_RECALL_HIGH_CONFIDENCE` - Confidence threshold (default: 0.7)

## Post-Installation

After running `install.sh`, enable the hooks in OpenClaw:

```bash
openclaw hooks enable memory-extract
openclaw hooks enable semantic-recall
openclaw hooks enable session-init
```

Verify installation:

```bash
openclaw hooks list
```

Monitor logs:

```bash
tail -f ~/clawd/logs/memory-extract-hook.log
```

## Manual Installation (Old Method)

The old `install-hooks.sh` script used symlinks, which caused issues with OpenClaw. 
The new `install.sh` copies hooks instead, which is more reliable.

If you previously used symlinks, remove them first:

```bash
rm -rf ~/.openclaw/workspace-claude-code/hooks/memory-extract
rm -rf ~/.openclaw/workspace-claude-code/hooks/semantic-recall
rm -rf ~/.openclaw/workspace-claude-code/hooks/session-init
```

Then run the new installer:

```bash
./install.sh
```

## Troubleshooting

### PostgreSQL Not Running
```bash
# Ubuntu/Debian
sudo systemctl start postgresql

# macOS
brew services start postgresql
```

### Missing pgvector Extension
```bash
# Ubuntu/Debian (PostgreSQL 16)
sudo apt install postgresql-16-pgvector

# macOS
brew install pgvector
```

### Python Dependencies
```bash
pip3 install psycopg2-binary anthropic openai
```

### Database Connection Issues

Check PostgreSQL is accepting connections:
```bash
psql -U nova -d nova_memory -c '\conninfo'
```

### Hook Not Working

Check hook is enabled:
```bash
openclaw hooks list
```

Check logs:
```bash
tail -f ~/clawd/logs/memory-extract-hook.log
tail -f ~/clawd/logs/openclaw-hooks.log
```

## Architecture

### Source Repository
```
nova-memory/
├── install.sh              # Comprehensive installer
├── verify-installation.sh  # Verification script
├── schema.sql              # Database schema (idempotent)
├── hooks/                  # OpenClaw hooks (source)
│   ├── memory-extract/     # Extracts memories from messages
│   ├── semantic-recall/    # Recalls relevant context
│   └── session-init/       # Initializes session context
└── scripts/                # Shell and Python scripts (source)
    ├── process-input.sh    # Entry point for memory extraction
    ├── extract-memories.sh # Memory extraction logic
    ├── proactive-recall.py # Semantic search
    └── ...                 # Other utility scripts
```

### After Installation (Workspace)
```
~/.openclaw/workspace-claude-code/
├── hooks/                  # Installed hooks
│   ├── memory-extract/     # → Uses ../../scripts/process-input.sh
│   ├── semantic-recall/    # → Uses ../../scripts/proactive-recall.py
│   └── session-init/       # → Uses ../../scripts/generate-session-context.sh
└── scripts/                # Copied scripts (self-contained)
    ├── process-input.sh
    ├── extract-memories.sh
    ├── proactive-recall.py
    └── ...
```

All hooks use **relative paths** to find scripts in `../../scripts/` from their location.

This makes the installation **self-contained** - the workspace has everything it needs without external dependencies.

## Portability

The system is now fully portable:
- No hardcoded paths to `~/clawd/`
- Hooks use relative paths to find scripts
- Installer detects workspace automatically
- Database connection via environment variables

You can clone nova-memory anywhere and install it:

```bash
git clone <repo> /opt/nova-memory
cd /opt/nova-memory
./install.sh
```

## Credits

- Original nova-memory system by Nova
- Installation improvements and relative path refactor: 2026-02-10
