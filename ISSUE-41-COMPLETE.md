# Issue #41: Auto-Enable Hooks - COMPLETE

**Issue:** https://github.com/NOVA-Openclaw/nova-memory/issues/41

## Problem

When nova-memory hooks are installed, they're not auto-enabled in OpenClaw config. Users have to manually add config entries for each hook.

## Solution Implemented

Created a complete auto-configuration system that:

### 1. Created `scripts/enable-hooks.sh`

A standalone script that safely patches `~/.openclaw/openclaw.json` to enable the three nova-memory hooks.

**Features:**
- Uses `jq` for safe JSON manipulation
- Creates timestamped backups before modifying config
- Handles multiple scenarios:
  - No hooks section at all (creates from scratch)
  - Hooks section exists but no internal section
  - Internal section exists but our hooks are missing
  - Hooks exist but are disabled
- Preserves existing hooks in the config
- Idempotent - safe to run multiple times
- Supports DRY_RUN mode for testing
- Color-coded output with status indicators

**Usage:**
```bash
# Apply to default config
./scripts/enable-hooks.sh

# Apply to specific config
./scripts/enable-hooks.sh /path/to/openclaw.json

# Dry run (preview changes)
DRY_RUN=1 ./scripts/enable-hooks.sh
```

### 2. Updated `install.sh`

Added **Part 4.5: OpenClaw Config Patching** section that:
- Checks if `jq` is installed
- Verifies `openclaw.json` exists
- Calls `enable-hooks.sh` automatically
- Sets `GATEWAY_RESTART_NEEDED` flag
- Handles failures gracefully with warnings

**Added checks:**
- jq availability check (warns if missing)
- OpenClaw config existence check
- enable-hooks.sh script existence check
- Tracks whether gateway restart is needed

**Updated output:**
- Shows which hooks were enabled automatically
- Provides next steps based on success/failure
- Prompts user to restart gateway when needed
- Falls back to manual instructions if auto-config fails

### 3. Testing Suite

Created `test-install-hooks.sh` - comprehensive test suite that verifies:

**Test Cases:**
1. ✅ jq availability check
2. ✅ Enable hooks in config with existing hooks section
3. ✅ Verify all three hooks are enabled
4. ✅ Verify existing hooks are preserved
5. ✅ Backup file creation
6. ✅ Idempotency (running script twice)
7. ✅ Handle empty config (no hooks section)

**All tests pass:**
```
Testing nova-memory hook installation and config patching
==========================================================
✓ Test environment created
✓ jq is installed
✓ Script ran successfully
✓ memory-extract is enabled
✓ semantic-recall is enabled
✓ session-init is enabled
✓ boot-md hook preserved (still enabled)
✓ Backup file created
✓ Script ran successfully a second time
✓ All hooks still enabled after second run
✓ Script handled empty config successfully
==========================================================
All tests passed! ✓
```

### 4. Updated Documentation

Updated `INSTALLATION.md` to document:
- New automatic hook configuration feature
- How enable-hooks.sh works
- Benefits of the new system
- Fallback options if auto-config fails
- Updated post-installation steps

## Files Created/Modified

### New Files:
- `scripts/enable-hooks.sh` - Hook configuration script
- `test-install-hooks.sh` - Comprehensive test suite
- `test-configs/` - Test fixtures and integration test environment
- `ISSUE-41-COMPLETE.md` - This document

### Modified Files:
- `install.sh` - Added Part 4.5 (OpenClaw Config Patching)
- `INSTALLATION.md` - Updated with new auto-config documentation

## Implementation Details

### JQ Filter Logic

The enable-hooks.sh script uses a sophisticated jq filter that:

```jq
# Ensure hooks section exists
if has("hooks") | not then
  .hooks = {"enabled": true, "internal": {"enabled": true, "entries": {}}}
else . end |

# Ensure hooks.enabled is true
.hooks.enabled = true |

# Ensure internal section exists
if .hooks | has("internal") | not then
  .hooks.internal = {"enabled": true, "entries": {}}
else . end |

# Ensure internal.enabled is true
.hooks.internal.enabled = true |

# Ensure entries object exists
if .hooks.internal | has("entries") | not then
  .hooks.internal.entries = {}
else . end |

# Enable each hook
.hooks.internal.entries["memory-extract"] = {"enabled": true} |
.hooks.internal.entries["semantic-recall"] = {"enabled": true} |
.hooks.internal.entries["session-init"] = {"enabled": true}
```

This handles all edge cases:
- Missing hooks section
- Missing internal section
- Missing entries object
- Existing hooks to preserve
- Disabled hooks to enable

### Backup Strategy

Before modifying config, creates timestamped backup:
```bash
BACKUP_FILE="${CONFIG_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
```

Example: `openclaw.json.backup-20260211-023157`

### Error Handling

The script handles multiple failure scenarios:
1. **jq not installed** - Warns and skips auto-config
2. **Config file not found** - Warns and skips auto-config
3. **Invalid JSON** - Validates before attempting changes
4. **Script not found** - Checks enable-hooks.sh exists
5. **Permission denied** - User sees error from enable-hooks.sh

## User Experience

### Before (Manual Configuration)

```bash
cd ~/clawd/nova-memory
./install.sh

# Manual steps required:
openclaw hooks enable memory-extract
openclaw hooks enable semantic-recall
openclaw hooks enable session-init
openclaw gateway restart
```

### After (Automatic Configuration)

```bash
cd ~/clawd/nova-memory
./install.sh
# Hooks automatically enabled!

# Just restart gateway:
openclaw gateway restart
```

### Output Example

```
OpenClaw config patching...
  Enabling nova-memory hooks in OpenClaw config...
  ✅ Hooks enabled in OpenClaw config
      • memory-extract
      • semantic-recall
      • session-init

...

Next steps:

1. Restart OpenClaw gateway to enable hooks:
   openclaw gateway restart

2. Verify installation:
   ./install.sh --verify-only

3. Check logs:
   tail -f ~/clawd/logs/memory-extract-hook.log
```

## Benefits

1. **Reduced friction** - No manual configuration needed
2. **Fewer errors** - Automated process eliminates mistakes
3. **Better UX** - Clear instructions and status indicators
4. **Idempotent** - Safe to run multiple times
5. **Safe** - Creates backups before modifying config
6. **Preserves existing config** - Doesn't overwrite other hooks
7. **Testable** - Comprehensive test suite included
8. **Fallback options** - Graceful degradation if auto-config fails

## Testing Performed

### Manual Testing:
1. ✅ Fresh install (no hooks section)
2. ✅ Install with existing hooks
3. ✅ Re-run installer (idempotency)
4. ✅ Manual enable-hooks.sh execution
5. ✅ DRY_RUN mode
6. ✅ Test with invalid JSON
7. ✅ Test without jq installed (simulated)

### Automated Testing:
- ✅ All 7 test cases in test-install-hooks.sh pass
- ✅ Integration test with full config patching
- ✅ Edge cases (empty config, existing hooks)
- ✅ Idempotency verification

## Production Safety

**This solution is production-ready because:**

1. **No production configs were modified during testing**
   - All testing done in `test-configs/` directory
   - Used test fixtures, not real configs
   - DRY_RUN mode for safe testing

2. **Backups are automatic**
   - Every config modification creates a timestamped backup
   - Easy to restore if something goes wrong

3. **Graceful degradation**
   - If jq not installed, warns and skips auto-config
   - If config not found, warns and continues
   - User can still enable hooks manually

4. **Idempotent**
   - Safe to run install.sh multiple times
   - Won't break existing configurations
   - Preserves other hooks in the config

5. **Well-tested**
   - Comprehensive test suite
   - Manual testing of edge cases
   - Verified on actual OpenClaw config structure

## Conclusion

Issue #41 is now **completely resolved**. The installation process now:

1. ✅ Copies hook files to `~/.openclaw/hooks/`
2. ✅ Patches `~/.openclaw/openclaw.json` to enable all three hooks
3. ✅ Uses proper JSON patching (jq) to safely merge config
4. ✅ Handles case where hooks section already exists
5. ✅ Tested without modifying production configs

Users can now install nova-memory with a single command and hooks will be automatically configured and ready to use after a gateway restart.
