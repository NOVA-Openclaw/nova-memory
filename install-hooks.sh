#!/bin/bash
# Install nova-memory hooks to OpenClaw hooks directory
# This script creates symlinks from the workspace hooks directory to nova-memory hooks

set -e

# Determine paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_SOURCE="$SCRIPT_DIR/hooks"

# Default workspace is ~/.openclaw/workspace-claude-code, but can be overridden
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-claude-code}"
HOOKS_TARGET="$WORKSPACE/hooks"

echo "Installing nova-memory hooks..."
echo "Source: $HOOKS_SOURCE"
echo "Target: $HOOKS_TARGET"

# Create hooks directory if it doesn't exist
mkdir -p "$HOOKS_TARGET"

# Function to install a hook via symlink
install_hook() {
    local hook_name="$1"
    local source="$HOOKS_SOURCE/$hook_name"
    local target="$HOOKS_TARGET/$hook_name"
    
    if [ ! -d "$source" ]; then
        echo "⚠️  Hook not found: $hook_name (skipping)"
        return
    fi
    
    # Remove existing symlink or directory
    if [ -L "$target" ]; then
        echo "  Updating existing symlink: $hook_name"
        rm "$target"
    elif [ -e "$target" ]; then
        echo "⚠️  $target exists and is not a symlink. Remove it manually to install."
        return
    fi
    
    # Create symlink
    ln -s "$source" "$target"
    echo "✅ Installed: $hook_name -> $source"
}

# Install each hook
echo ""
install_hook "memory-extract"
install_hook "semantic-recall"
install_hook "session-init"

echo ""
echo "✅ Installation complete!"
echo ""
echo "To enable hooks in OpenClaw:"
echo "  openclaw hooks enable memory-extract"
echo "  openclaw hooks enable semantic-recall"
echo "  openclaw hooks enable session-init"
echo ""
echo "To verify installation:"
echo "  openclaw hooks list"
