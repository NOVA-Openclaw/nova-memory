# Issue #26: Installer should install hooks to ~/.openclaw/hooks/

## ✅ Completed

**Updated:** `install-hooks.sh`

### Changes Made:

1. **Changed target directory** from `$WORKSPACE/hooks` to `~/.openclaw/hooks/`
   - This is the standard OpenClaw hooks location

2. **Switched from symlinks to copying**
   - Hooks are now copied with `cp -r` instead of using `ln -s`
   - Preserves all files in each hook directory (handler.ts, HOOK.md, etc.)

3. **Made it idempotent**
   - Checks if hooks exist before installing
   - Updates existing hooks safely (removes old, copies new)
   - Safe to run multiple times

4. **Uses consistent status indicators**
   - ✅ (green checkmark) for success
   - ⚠️ (yellow warning) for issues
   - Matches the style used in `install.sh`

### Hooks Installed:

All three hooks are successfully copied to `~/.openclaw/hooks/`:
- `memory-extract/` (HOOK.md, handler.ts)
- `semantic-recall/` (HOOK.md, IMPLEMENTATION.md, handler.ts, test-entity-resolution.js, verify-refactor.ts)
- `session-init/` (HOOK.md, handler.ts)

### Testing:

✅ Syntax check passed: `bash -n install-hooks.sh`
✅ First installation successful
✅ Idempotent update successful
✅ All files preserved correctly

### Verification:

```bash
$ ls ~/.openclaw/hooks/
activity-tracker  memory-extract  semantic-recall  session-init

$ openclaw hooks list
# Shows all three hooks present
```

## Note:

The hooks import from `../../../nova-relationships/...` which assumes `~/nova-relationships` exists. This is tracked separately in issue #25 and was not addressed here as requested.
