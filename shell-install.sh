#!/bin/bash
# shell-install.sh — Interactive setup for nova-memory
# Human-facing entry point that ensures all config is in place, then execs agent-install.sh.
#
# 1. Check/prompt for database config → write to ~/.openclaw/postgres.json
# 2. Check/prompt for API keys → write to ~/.openclaw/openclaw.json env.vars
# 3. Load all config into ENV
# 4. exec agent-install.sh (which does all the real work)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR="$HOME/.openclaw"
PG_CONFIG="$CONFIG_DIR/postgres.json"
OPENCLAW_CONFIG="$CONFIG_DIR/openclaw.json"

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "═══════════════════════════════════════════"
echo "  nova-memory shell-install"
echo "═══════════════════════════════════════════"
echo ""

# Create config directory if needed
if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    echo -e "  ${GREEN}✅${NC} Created $CONFIG_DIR"
fi

# ============================================
# Part 1: Database config (postgres.json)
# ============================================
echo "Database configuration..."

# Check if postgres.json exists and has all required fields
PG_COMPLETE=true
if [ -f "$PG_CONFIG" ]; then
    if command -v jq &>/dev/null; then
        for field in host port database user; do
            val=$(jq -r ".$field // empty" "$PG_CONFIG" 2>/dev/null)
            if [ -z "$val" ]; then
                echo -e "  ${YELLOW}⚠️  $PG_CONFIG is missing '$field'${NC}"
                PG_COMPLETE=false
            fi
        done
        if [ "$PG_COMPLETE" = true ]; then
            echo -e "  ${GREEN}✅${NC} $PG_CONFIG exists and is complete"
        fi
    else
        echo -e "  ${YELLOW}⚠️  jq not installed — cannot validate $PG_CONFIG${NC}"
        PG_COMPLETE=false
    fi
else
    PG_COMPLETE=false
fi

if [ "$PG_COMPLETE" = false ]; then
    # Prompt for database connection details
    DEFAULT_HOST="localhost"
    DEFAULT_PORT="5432"
    DEFAULT_USER="$(whoami)"
    DEFAULT_DB="${DEFAULT_USER//-/_}_memory"

    echo ""
    echo "  Enter PostgreSQL connection details (press Enter for defaults):"
    echo ""

    read -rp "    Host [$DEFAULT_HOST]: " INPUT_HOST
    read -rp "    Port [$DEFAULT_PORT]: " INPUT_PORT
    read -rp "    Database [$DEFAULT_DB]: " INPUT_DB
    read -rp "    User [$DEFAULT_USER]: " INPUT_USER
    read -rsp "    Password []: " INPUT_PASS
    echo ""

    DB_HOST="${INPUT_HOST:-$DEFAULT_HOST}"
    DB_PORT="${INPUT_PORT:-$DEFAULT_PORT}"
    DB_NAME="${INPUT_DB:-$DEFAULT_DB}"
    DB_USER="${INPUT_USER:-$DEFAULT_USER}"
    DB_PASS="${INPUT_PASS:-}"

    cat > "$PG_CONFIG" <<EOF
{
  "host": "$DB_HOST",
  "port": $DB_PORT,
  "database": "$DB_NAME",
  "user": "$DB_USER",
  "password": "$DB_PASS"
}
EOF
    chmod 600 "$PG_CONFIG"
    echo -e "  ${GREEN}✅${NC} Wrote $PG_CONFIG (chmod 600)"
fi

# Load database config into ENV
PG_ENV="$SCRIPT_DIR/lib/pg-env.sh"
if [ -f "$PG_ENV" ]; then
    source "$PG_ENV"
    load_pg_env
else
    echo -e "  ${RED}❌${NC} $PG_ENV not found"
    exit 1
fi

echo "  Resolved: PGHOST=$PGHOST PGDATABASE=${PGDATABASE:-(not set)} PGUSER=$PGUSER"

# ============================================
# Part 2: API keys (openclaw.json env.vars)
# ============================================
echo ""
echo "API key configuration..."

# Ensure openclaw.json exists
if [ ! -f "$OPENCLAW_CONFIG" ]; then
    echo -e "  ${YELLOW}⚠️  $OPENCLAW_CONFIG not found — creating minimal config${NC}"
    echo '{}' > "$OPENCLAW_CONFIG"
fi

if ! command -v jq &>/dev/null; then
    echo -e "  ${RED}❌${NC} jq is required to manage openclaw.json"
    echo "      Install: sudo apt install jq"
    exit 1
fi

# Check OPENAI_API_KEY
OPENAI_KEY=$(jq -r '.env.vars.OPENAI_API_KEY // empty' "$OPENCLAW_CONFIG" 2>/dev/null)
if [ -z "$OPENAI_KEY" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
    echo -e "  ${YELLOW}⚠️  OPENAI_API_KEY not found${NC}"
    echo "      Required for semantic recall (embeddings)."
    echo "      Get a key from: https://platform.openai.com/api-keys"
    echo ""
    read -rp "    Enter your OpenAI API key (or press Enter to skip): " INPUT_OPENAI_KEY
    if [ -n "$INPUT_OPENAI_KEY" ]; then
        # Write to openclaw.json env.vars
        TMP_CONFIG=$(mktemp)
        jq --arg key "$INPUT_OPENAI_KEY" '.env.vars.OPENAI_API_KEY = $key' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"
        mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
        export OPENAI_API_KEY="$INPUT_OPENAI_KEY"
        echo -e "  ${GREEN}✅${NC} OPENAI_API_KEY written to $OPENCLAW_CONFIG"
    else
        echo -e "  ${YELLOW}⚠️  Skipped — semantic recall will not work without OPENAI_API_KEY${NC}"
    fi
elif [ -n "$OPENAI_KEY" ]; then
    export OPENAI_API_KEY="$OPENAI_KEY"
    echo -e "  ${GREEN}✅${NC} OPENAI_API_KEY found in $OPENCLAW_CONFIG"
else
    echo -e "  ${GREEN}✅${NC} OPENAI_API_KEY set in environment"
fi

# Check ANTHROPIC_API_KEY
ANTHROPIC_KEY=$(jq -r '.env.vars.ANTHROPIC_API_KEY // empty' "$OPENCLAW_CONFIG" 2>/dev/null)
if [ -z "$ANTHROPIC_KEY" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo -e "  ${YELLOW}⚠️  ANTHROPIC_API_KEY not found${NC}"
    echo "      Required for memory extraction (LLM calls)."
    echo "      Get a key from: https://console.anthropic.com/settings/keys"
    echo ""
    read -rp "    Enter your Anthropic API key (or press Enter to skip): " INPUT_ANTHROPIC_KEY
    if [ -n "$INPUT_ANTHROPIC_KEY" ]; then
        # Write to openclaw.json env.vars
        TMP_CONFIG=$(mktemp)
        jq --arg key "$INPUT_ANTHROPIC_KEY" '.env.vars.ANTHROPIC_API_KEY = $key' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"
        mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
        export ANTHROPIC_API_KEY="$INPUT_ANTHROPIC_KEY"
        echo -e "  ${GREEN}✅${NC} ANTHROPIC_API_KEY written to $OPENCLAW_CONFIG"
    else
        echo -e "  ${YELLOW}⚠️  Skipped — memory extraction will not work without ANTHROPIC_API_KEY${NC}"
    fi
elif [ -n "$ANTHROPIC_KEY" ]; then
    export ANTHROPIC_API_KEY="$ANTHROPIC_KEY"
    echo -e "  ${GREEN}✅${NC} ANTHROPIC_API_KEY found in $OPENCLAW_CONFIG"
else
    echo -e "  ${GREEN}✅${NC} ANTHROPIC_API_KEY set in environment"
fi

# ============================================
# Part 3: Hand off to agent-install.sh
# ============================================
echo ""
echo "Config setup complete. Running agent-install.sh..."
echo ""
exec "$SCRIPT_DIR/agent-install.sh" "$@"
