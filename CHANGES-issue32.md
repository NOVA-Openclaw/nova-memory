# Changes for Issue #32: Installer Python venv setup

## Summary
Updated `install.sh` to create a standardized Python virtual environment at `~/.local/share/nova/venv/` with all required dependencies, and updated `hooks/semantic-recall/handler.ts` to use the new location with backward compatibility fallback.

## Changes Made

### 1. install.sh - Added Part 5: Python Virtual Environment Setup
**Location:** Between Part 4 (Scripts Setup) and Part 6 (Cron Job Setup)

**Features:**
- ✅ Checks for Python3 availability
- ✅ Installs virtualenv via pip3 if not present (idempotent check)
- ✅ Creates venv at `~/.local/share/nova/venv/` (creates parent dirs automatically)
- ✅ Installs required packages: `openai`, `tiktoken`, `psycopg2-binary`, `pillow`
- ✅ Idempotent package installation (skips already installed packages)
- ✅ Uses same status indicators as rest of installer (✅/❌/⚠️)
- ✅ Verifies all packages installed successfully

**Idempotency guarantees:**
- Skips virtualenv install if `python3 -m virtualenv` already works
- Skips venv creation if directory already exists
- Checks each package individually before attempting installation
- Reports already-installed vs newly-installed packages

### 2. hooks/semantic-recall/handler.ts - Updated venv path
**Changes:**
- Added `STANDARD_VENV` constant pointing to `~/.local/share/nova/venv/bin/python`
- Kept `WORKSPACE_VENV` as fallback for backward compatibility
- Added runtime check using `existsSync()` to prefer standard location
- Falls back to workspace venv if standard location doesn't exist

**Compatibility:**
- Existing installations with workspace venv continue working
- New installations use standard location automatically
- No breaking changes for users

### 3. Renumbered Part 6 → Part 7
Updated "Part 6: Verification" to "Part 7: Verification" to maintain section numbering.

## Testing
- ✅ Syntax check passed: `bash -n install.sh` (no errors)
- ✅ Script structure maintained (idempotent, status indicators consistent)
- ✅ TypeScript imports valid (existsSync from 'fs')

## Installation Flow
1. Check Python3 available
2. Install virtualenv if needed (pip3 install --user virtualenv)
3. Create venv at ~/.local/share/nova/venv/ if not exists
4. Check which packages are missing
5. Install only missing packages
6. Verify all packages available
7. Report status with ✅/❌/⚠️ indicators

## Next Steps
- Test full installation on clean system
- Verify hooks work with new venv location
- Consider adding venv verification to `--verify-only` mode
