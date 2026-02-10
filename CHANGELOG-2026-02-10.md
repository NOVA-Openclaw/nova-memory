# Changelog - 2026-02-10

## Summary

Complete refactor of nova-memory installation system to support **portable, idempotent installation** with **relative paths**.

## Changes Made

### Part 1: Hook Refactoring - Relative Paths

Updated all hooks to use relative paths instead of hardcoded `~/clawd/scripts/`:

#### Files Modified

**1. `hooks/memory-extract/handler.ts`**
- Added ES6 module path resolution using `fileURLToPath` and `dirname`
- Replaced hardcoded `/home/nova/clawd/scripts/process-input.sh`
- Now uses `join(__dirname, "..", "..", "scripts", "process-input.sh")`

**2. `hooks/session-init/handler.ts`**
- Added ES6 module path resolution
- Replaced `join(process.env.HOME, "clawd", "scripts")`
- Now uses `join(__dirname, "..", "..", "scripts")`

**3. `hooks/semantic-recall/handler.ts`**
- Added ES6 module path resolution
- Replaced `path.join(os.homedir(), "clawd/scripts/proactive-recall.py")`
- Now uses `path.join(SCRIPTS_DIR, "proactive-recall.py")` where SCRIPTS_DIR is relative

**4. `hooks/semantic-recall/HOOK.md`**
- Updated documentation to reflect relative script paths
- Changed "~/clawd/scripts/" to "../../scripts/ relative to hook"

### Part 2: Comprehensive Installer

**Created: `install.sh`**

A fully idempotent installer script with the following features:

#### 1. Prerequisites Check
- ✅ Verifies PostgreSQL installed and version
- ✅ Checks `psql` command availability
- ✅ Verifies PostgreSQL service running
- ⚠️ Warns if `ANTHROPIC_API_KEY` missing
- ✅ Checks pgvector extension availability

#### 2. Database Setup (Idempotent)
- Creates `nova_memory` database if missing
- Verifies connection to existing database
- Applies `schema.sql` safely (handles already-exists errors)
- Reports created vs skipped objects
- Counts total tables in database

#### 3. Hooks Installation
- **Copies** hooks to `$WORKSPACE/hooks/` (not symlinks)
- Removes existing hooks before copying (idempotent)
- Installs: `memory-extract`, `semantic-recall`, `session-init`
- Detects workspace from `OPENCLAW_WORKSPACE` or uses default

#### 4. Scripts Installation (NEW)
- **Copies** entire scripts directory to `$WORKSPACE/scripts/`
- Makes all `.sh` and `.py` files executable
- Enables hooks to find scripts via relative paths
- Creates self-contained workspace installation

#### 5. Python Dependency Check
- Verifies Python3 available
- Checks for: `psycopg2`, `anthropic`, `openai`
- Reports missing dependencies with install command

#### 6. Verification
- Tests database connection
- Runs sample query
- Lists installed hooks
- Provides next steps

#### Output Features
- Color-coded status indicators (✅ ❌ ⚠️)
- Clear section headers
- Detailed success/failure reporting
- Actionable next steps

### Part 3: Verification Script

**Created: `verify-installation.sh`**

Comprehensive verification script that checks:

- ✅ Hook directories exist with handler.ts
- ✅ Hooks use relative paths (grep check)
- ✅ Scripts directory exists in workspace
- ✅ Key scripts present and executable
- ✅ Database accessible with correct table count
- ✅ pgvector extension installed
- ✅ Environment variables set
- ✅ Python dependencies installed

### Part 4: Documentation

**Created: `INSTALLATION.md`**

Comprehensive installation guide covering:
- Quick install instructions
- Detailed explanation of all changes
- Environment variable reference
- Post-installation steps
- Troubleshooting guide
- Architecture diagrams (before/after)
- Manual installation fallback
- Portability notes

**Created: `CHANGELOG-2026-02-10.md`** (this file)

Complete change log for reference.

## Technical Details

### Why Relative Paths?

**Problem:** Hooks had hardcoded paths to `~/clawd/scripts/`
- Made system non-portable
- Couldn't install repo anywhere else
- Required specific directory structure

**Solution:** ES6 module path resolution
```typescript
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const SCRIPTS_DIR = join(__dirname, "..", "..", "scripts");
```

This resolves to `workspace/scripts/` from `workspace/hooks/hook-name/handler.ts`.

### Why Copy Instead of Symlink?

**Problem:** OpenClaw wasn't following symlinks reliably
- Hook execution failed with symlinked directories
- Path resolution issues in Node.js

**Solution:** Copy hooks and scripts to workspace
- Fully self-contained installation
- No external dependencies after installation
- Idempotent - safe to run installer multiple times

### Installation Layout

**Before:**
```
~/.openclaw/workspace-claude-code/
└── hooks/
    ├── memory-extract/     (symlink → ~/clawd/nova-memory/hooks/memory-extract)
    ├── semantic-recall/    (symlink → ~/clawd/nova-memory/hooks/semantic-recall)
    └── session-init/       (symlink → ~/clawd/nova-memory/hooks/session-init)

~/clawd/scripts/            (separate location)
    ├── process-input.sh
    ├── proactive-recall.py
    └── ...
```

**After:**
```
~/.openclaw/workspace-claude-code/
├── hooks/                  (copies)
│   ├── memory-extract/     → Uses ../../scripts/
│   ├── semantic-recall/    → Uses ../../scripts/
│   └── session-init/       → Uses ../../scripts/
└── scripts/                (copies)
    ├── process-input.sh
    ├── proactive-recall.py
    └── ...
```

## Testing

### Verification Commands

```bash
# Run installer
cd ~/clawd/nova-memory
./install.sh

# Verify installation
./verify-installation.sh

# Check hooks can find scripts
cd ~/.openclaw/workspace-claude-code/hooks/memory-extract
node -e "import('path').then(p => console.log('Scripts:', p.resolve('.', '..', '..', 'scripts')))"
```

### Expected Results

All verifications should show ✅:
- 3 hooks installed with handler.ts
- All hooks use relative paths
- Scripts directory with 13 files
- Key scripts executable
- Database accessible
- pgvector extension present

Warnings (⚠️) are acceptable for:
- Missing API keys (if not configured yet)
- Missing Python dependencies (if not needed)

## Portability

The system is now fully portable. You can:

```bash
# Clone anywhere
git clone <repo> /opt/nova-memory
cd /opt/nova-memory

# Install with custom workspace
export OPENCLAW_WORKSPACE=/custom/workspace
./install.sh

# Works!
```

## Backward Compatibility

### Breaking Changes

⚠️ **Symlinked installations will break**

If you previously used `install-hooks.sh` (symlink method), you must:

1. Remove old symlinks:
   ```bash
   rm -rf ~/.openclaw/workspace-claude-code/hooks/memory-extract
   rm -rf ~/.openclaw/workspace-claude-code/hooks/semantic-recall
   rm -rf ~/.openclaw/workspace-claude-code/hooks/session-init
   ```

2. Run new installer:
   ```bash
   cd ~/clawd/nova-memory
   ./install.sh
   ```

### Non-Breaking Changes

✅ **Database schema remains unchanged**
- Schema is idempotent (CREATE IF NOT EXISTS)
- Re-running installer is safe

✅ **Script behavior unchanged**
- Scripts work identically
- Same environment variables
- Same database interactions

## Files Added

- `install.sh` - Comprehensive installer
- `verify-installation.sh` - Installation verification
- `INSTALLATION.md` - Installation guide
- `CHANGELOG-2026-02-10.md` - This file

## Files Modified

- `hooks/memory-extract/handler.ts` - Relative paths
- `hooks/session-init/handler.ts` - Relative paths
- `hooks/semantic-recall/handler.ts` - Relative paths
- `hooks/semantic-recall/HOOK.md` - Documentation update

## Files Unchanged

- `schema.sql` - No changes needed
- `scripts/*.sh` - No changes needed
- `scripts/*.py` - No changes needed
- `install-hooks.sh` - Kept for reference (deprecated)

## Migration Guide

### From Old Installation (Symlinks)

1. **Backup** (optional, if you've customized anything):
   ```bash
   cp -r ~/.openclaw/workspace-claude-code/hooks /tmp/hooks-backup
   ```

2. **Remove old symlinks**:
   ```bash
   cd ~/.openclaw/workspace-claude-code/hooks
   rm -rf memory-extract semantic-recall session-init
   ```

3. **Pull updates**:
   ```bash
   cd ~/clawd/nova-memory
   git pull
   ```

4. **Run new installer**:
   ```bash
   ./install.sh
   ```

5. **Verify**:
   ```bash
   ./verify-installation.sh
   ```

6. **Re-enable hooks** (if they were disabled):
   ```bash
   openclaw hooks enable memory-extract
   openclaw hooks enable semantic-recall
   openclaw hooks enable session-init
   ```

### Fresh Installation

Just run:
```bash
cd ~/clawd/nova-memory
./install.sh
```

## Future Improvements

Potential enhancements:

1. **Package manager** - Distribute via npm/pip
2. **Auto-updates** - Check for updates and re-install
3. **Configuration wizard** - Interactive setup for API keys
4. **Hook templating** - Generate custom hooks easily
5. **Multi-workspace** - Install to multiple workspaces
6. **Uninstaller** - Clean removal script

## Credits

- **Original System**: Nova's memory extraction and semantic recall
- **Refactor & Installer**: Subagent task, February 10, 2026
- **Testing**: Verified on Ubuntu 24.04 with PostgreSQL 16.11

## Notes

- All changes maintain backward compatibility with existing data
- No database migrations required
- Hooks behavior unchanged (just path resolution improved)
- Installation is now truly idempotent and portable
