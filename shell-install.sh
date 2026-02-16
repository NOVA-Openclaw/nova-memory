#!/bin/bash
# shell-install.sh - Interactive setup for humans
# Prompts for API keys, saves to OpenClaw provider config, then runs agent-install.sh

set -e

OPENCLAW_CONFIG="${HOME}/.openclaw/openclaw.json"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "═══════════════════════════════════════════"
echo "  nova-memory interactive setup"
echo "═══════════════════════════════════════════"
echo ""

# Check jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq is required but not installed${NC}"
    echo "   Install: sudo apt install jq"
    exit 1
fi

# Ensure config file exists
if [ ! -f "$OPENCLAW_CONFIG" ]; then
    echo "Creating config file: $OPENCLAW_CONFIG"
    mkdir -p "$(dirname "$OPENCLAW_CONFIG")"
    echo '{}' > "$OPENCLAW_CONFIG"
fi

CONFIG_CHANGED=0

# --- OpenAI API Key ---
EXISTING_OPENAI=$(jq -r '.models.providers.openai.apiKey // empty' "$OPENCLAW_CONFIG" 2>/dev/null)

if [ -n "$EXISTING_OPENAI" ]; then
    echo -e "${GREEN}✅${NC} OpenAI API key already configured: ${EXISTING_OPENAI:0:8}..."
    read -p "Replace existing OpenAI key? [y/N] " replace_openai
    if [[ "$replace_openai" =~ ^[Yy] ]]; then
        EXISTING_OPENAI=""
    fi
fi

if [ -z "$EXISTING_OPENAI" ]; then
    echo ""
    echo "OpenAI API key is required for semantic recall (embeddings)."
    echo "Get your API key from: https://platform.openai.com/api-keys"
    echo ""
    read -p "Enter your OpenAI API key (or press Enter to cancel): " openai_key

    if [ -z "$openai_key" ]; then
        echo -e "${RED}❌ Cancelled - OpenAI API key is required${NC}"
        exit 1
    fi

    # Backup before first modification
    if [ $CONFIG_CHANGED -eq 0 ]; then
        cp "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG.backup-$(date +%s)"
    fi

    TMP_CONFIG=$(mktemp)
    jq --arg key "$openai_key" '.models.providers.openai.apiKey = $key' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"
    mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
    CONFIG_CHANGED=1
    echo -e "${GREEN}✅${NC} OpenAI API key saved to provider config"
fi

# --- Anthropic API Key (needed by extract-memories) ---
echo ""
EXISTING_ANTHROPIC=$(jq -r '.models.providers.anthropic.apiKey // empty' "$OPENCLAW_CONFIG" 2>/dev/null)

if [ -n "$EXISTING_ANTHROPIC" ]; then
    echo -e "${GREEN}✅${NC} Anthropic API key already configured: ${EXISTING_ANTHROPIC:0:8}..."
    read -p "Replace existing Anthropic key? [y/N] " replace_anthropic
    if [[ "$replace_anthropic" =~ ^[Yy] ]]; then
        EXISTING_ANTHROPIC=""
    fi
fi

if [ -z "$EXISTING_ANTHROPIC" ]; then
    echo ""
    echo "Anthropic API key is required for memory extraction (Claude)."
    echo "Get your API key from: https://console.anthropic.com/"
    echo ""
    read -p "Enter your Anthropic API key (or press Enter to skip): " anthropic_key

    if [ -n "$anthropic_key" ]; then
        if [ $CONFIG_CHANGED -eq 0 ]; then
            cp "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG.backup-$(date +%s)"
        fi

        TMP_CONFIG=$(mktemp)
        jq --arg key "$anthropic_key" '.models.providers.anthropic.apiKey = $key' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"
        mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
        CONFIG_CHANGED=1
        echo -e "${GREEN}✅${NC} Anthropic API key saved to provider config"
    else
        echo -e "${YELLOW}⚠️${NC}  Skipped — extract-memories will not work without Anthropic key"
    fi
fi

echo ""

# Run agent installer
exec "$(dirname "$0")/agent-install.sh" "$@"
