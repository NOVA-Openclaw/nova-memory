#!/bin/bash
# Test script for hook installation and config patching

set -e

echo "Testing nova-memory hook installation and config patching"
echo "=========================================================="
echo ""

# Create test environment
TEST_DIR="$(pwd)/test-configs/integration-test"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/.openclaw/hooks"
mkdir -p "$TEST_DIR/workspace/scripts"

# Create a test openclaw.json
cat > "$TEST_DIR/.openclaw/openclaw.json" << 'EOF'
{
  "meta": {
    "lastTouchedVersion": "2026.2.9"
  },
  "agents": {
    "defaults": {}
  },
  "hooks": {
    "enabled": true,
    "internal": {
      "enabled": true,
      "entries": {
        "boot-md": {
          "enabled": true
        }
      }
    }
  }
}
EOF

echo "✓ Test environment created at $TEST_DIR"
echo ""

# Test 1: Script without jq
echo "Test 1: Check jq availability"
if command -v jq &> /dev/null; then
    echo "✓ jq is installed"
else
    echo "✗ jq not installed (this would be caught by the installer)"
fi
echo ""

# Test 2: Run enable-hooks.sh script
echo "Test 2: Run enable-hooks.sh on test config"
echo ""
./scripts/enable-hooks.sh "$TEST_DIR/.openclaw/openclaw.json"
echo ""

# Test 3: Verify the result
echo "Test 3: Verify hooks were enabled"
for hook in "memory-extract" "semantic-recall" "session-init"; do
    ENABLED=$(jq -r ".hooks.internal.entries.\"$hook\".enabled" "$TEST_DIR/.openclaw/openclaw.json")
    if [ "$ENABLED" = "true" ]; then
        echo "✓ $hook is enabled"
    else
        echo "✗ $hook is NOT enabled (expected: true, got: $ENABLED)"
        exit 1
    fi
done
echo ""

# Test 4: Verify existing hooks are preserved
echo "Test 4: Verify existing hooks are preserved"
BOOT_MD_ENABLED=$(jq -r ".hooks.internal.entries.\"boot-md\".enabled" "$TEST_DIR/.openclaw/openclaw.json")
if [ "$BOOT_MD_ENABLED" = "true" ]; then
    echo "✓ boot-md hook preserved (still enabled)"
else
    echo "✗ boot-md hook was modified (expected: true, got: $BOOT_MD_ENABLED)"
    exit 1
fi
echo ""

# Test 5: Verify backup was created
echo "Test 5: Verify backup was created"
BACKUP_COUNT=$(ls -1 "$TEST_DIR/.openclaw/openclaw.json.backup-"* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt 0 ]; then
    echo "✓ Backup file created ($BACKUP_COUNT backup(s) found)"
else
    echo "✗ No backup file created"
    exit 1
fi
echo ""

# Test 6: Test idempotency (run again)
echo "Test 6: Test idempotency (run enable-hooks.sh again)"
echo ""
./scripts/enable-hooks.sh "$TEST_DIR/.openclaw/openclaw.json" > /dev/null 2>&1
echo "✓ Script ran successfully a second time"
echo ""

# Verify hooks are still enabled
for hook in "memory-extract" "semantic-recall" "session-init"; do
    ENABLED=$(jq -r ".hooks.internal.entries.\"$hook\".enabled" "$TEST_DIR/.openclaw/openclaw.json")
    if [ "$ENABLED" = "true" ]; then
        echo "✓ $hook still enabled after second run"
    else
        echo "✗ $hook changed after second run"
        exit 1
    fi
done
echo ""

# Test 7: Test with empty config
echo "Test 7: Test with config that has no hooks section"
cat > "$TEST_DIR/.openclaw/openclaw-empty.json" << 'EOF'
{
  "meta": {
    "lastTouchedVersion": "2026.2.9"
  },
  "agents": {
    "defaults": {}
  }
}
EOF

./scripts/enable-hooks.sh "$TEST_DIR/.openclaw/openclaw-empty.json" > /dev/null 2>&1
echo "✓ Script handled empty config successfully"
echo ""

for hook in "memory-extract" "semantic-recall" "session-init"; do
    ENABLED=$(jq -r ".hooks.internal.entries.\"$hook\".enabled" "$TEST_DIR/.openclaw/openclaw-empty.json")
    if [ "$ENABLED" = "true" ]; then
        echo "✓ $hook enabled in empty config"
    else
        echo "✗ $hook not enabled in empty config"
        exit 1
    fi
done
echo ""

# Show final config structure
echo "Final config structure:"
jq '.hooks' "$TEST_DIR/.openclaw/openclaw.json"
echo ""

echo "=========================================================="
echo "All tests passed! ✓"
echo ""
echo "The install.sh script will now:"
echo "  1. Copy hook files to ~/.openclaw/hooks/"
echo "  2. Automatically enable all three hooks in openclaw.json"
echo "  3. Create a backup before modifying the config"
echo "  4. Prompt user to restart the gateway"
echo ""
