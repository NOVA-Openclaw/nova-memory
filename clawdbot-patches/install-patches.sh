#!/bin/bash
# install-patches.sh - Apply NOVA's patches to OpenClaw
# Run after any OpenClaw update

set -e

OPENCLAW_DIR="${HOME}/.npm-global/lib/node_modules/openclaw/dist"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== NOVA OpenClaw Patch Installer ==="
echo "OpenClaw: $OPENCLAW_DIR"
echo "Patches:  $PATCH_DIR"
echo ""

if [ ! -d "$OPENCLAW_DIR" ]; then
    echo "ERROR: OpenClaw not found at $OPENCLAW_DIR"
    exit 1
fi

# 1. Message hooks
echo "1. Installing message hooks..."
mkdir -p "$OPENCLAW_DIR/hooks"
cp "$PATCH_DIR/message-hooks.js" "$OPENCLAW_DIR/hooks/" 2>/dev/null && echo "   - message-hooks.js" || echo "   - message-hooks.js (skipped)"
cp "$PATCH_DIR/internal-hooks.js" "$OPENCLAW_DIR/hooks/" 2>/dev/null && echo "   - internal-hooks.js" || echo "   - internal-hooks.js (skipped)"
cp "$PATCH_DIR/hooks.js" "$OPENCLAW_DIR/hooks/" 2>/dev/null && echo "   - hooks.js" || echo "   - hooks.js (skipped)"

mkdir -p "$OPENCLAW_DIR/auto-reply/reply"
cp "$PATCH_DIR/dispatch.js" "$OPENCLAW_DIR/auto-reply/" 2>/dev/null && echo "   - dispatch.js" || echo "   - dispatch.js (skipped)"
cp "$PATCH_DIR/reply-dispatcher.js" "$OPENCLAW_DIR/auto-reply/reply/" 2>/dev/null && echo "   - reply-dispatcher.js" || echo "   - reply-dispatcher.js (skipped)"

# 2. Subagent env vars
echo ""
echo "2. Installing subagent env vars patch..."
if [ -f "$PATCH_DIR/subagent-env-vars.patch" ]; then
    cd "$OPENCLAW_DIR/.."
    if patch -p1 --dry-run < "$PATCH_DIR/subagent-env-vars.patch" >/dev/null 2>&1; then
        patch -p1 < "$PATCH_DIR/subagent-env-vars.patch"
        echo "   - Applied successfully"
    else
        echo "   - Already applied or conflict (skipped)"
    fi
else
    echo "   - Patch file not found (skipped)"
fi

echo ""
echo "=== Done ==="
echo "Restart gateway: openclaw gateway restart"
