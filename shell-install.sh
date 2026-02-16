#!/bin/bash
# shell-install.sh — Interactive config file generation for nova-memory
# Prompts for PostgreSQL connection details and writes ~/.openclaw/postgres.json
# Does NOT create databases or apply schemas — that's agent-install.sh's job.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR="$HOME/.openclaw"
CONFIG_FILE="$CONFIG_DIR/postgres.json"
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

# ============================================
# Part 1: Prompt for database connection details
# ============================================

DEFAULT_HOST="localhost"
DEFAULT_PORT="5432"
DEFAULT_USER="$(whoami)"
DEFAULT_DB="${DEFAULT_USER//-/_}_memory"
DEFAULT_PASS=""

if [ -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}⚠️  $CONFIG_FILE already exists — will not overwrite.${NC}"
    echo "   Delete it manually if you want to reconfigure."
    echo ""
else
    echo "Enter PostgreSQL connection details (press Enter for defaults):"
    echo ""

    read -rp "  Host [$DEFAULT_HOST]: " INPUT_HOST
    read -rp "  Port [$DEFAULT_PORT]: " INPUT_PORT
    read -rp "  Database [$DEFAULT_DB]: " INPUT_DB
    read -rp "  User [$DEFAULT_USER]: " INPUT_USER
    read -rsp "  Password []: " INPUT_PASS
    echo ""

    DB_HOST="${INPUT_HOST:-$DEFAULT_HOST}"
    DB_PORT="${INPUT_PORT:-$DEFAULT_PORT}"
    DB_NAME="${INPUT_DB:-$DEFAULT_DB}"
    DB_USER="${INPUT_USER:-$DEFAULT_USER}"
    DB_PASS="${INPUT_PASS:-$DEFAULT_PASS}"

    # Create config directory if needed
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        chmod 700 "$CONFIG_DIR"
        echo -e "  ${GREEN}✅${NC} Created $CONFIG_DIR"
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "host": "$DB_HOST",
  "port": $DB_PORT,
  "database": "$DB_NAME",
  "user": "$DB_USER",
  "password": "$DB_PASS"
}
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "  ${GREEN}✅${NC} Wrote $CONFIG_FILE (chmod 600)"
fi

# ============================================
# Part 2: Check for required API keys
# ============================================
echo ""
echo "Checking API keys..."

if [ -f "$OPENCLAW_CONFIG" ]; then
    if command -v jq &>/dev/null; then
        OPENAI_KEY=$(jq -r '.env.vars.OPENAI_API_KEY // empty' "$OPENCLAW_CONFIG" 2>/dev/null)
        if [ -z "$OPENAI_KEY" ]; then
            echo -e "  ${YELLOW}⚠️  OPENAI_API_KEY not found in $OPENCLAW_CONFIG (env.vars section)${NC}"
            echo "     nova-memory needs this for embeddings. Add it before running agent-install.sh."
        else
            echo -e "  ${GREEN}✅${NC} OPENAI_API_KEY is set"
        fi
    else
        echo -e "  ${YELLOW}⚠️  jq not installed — cannot check $OPENCLAW_CONFIG${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠️  $OPENCLAW_CONFIG not found — cannot check API keys${NC}"
fi

# ============================================
# Part 3: Verify config loads via pg-env.sh
# ============================================
echo ""
echo "Verifying config loads correctly..."

PG_ENV="$SCRIPT_DIR/lib/pg-env.sh"
if [ -f "$PG_ENV" ]; then
    # Subshell so we don't pollute current env
    (
        source "$PG_ENV"
        load_pg_env
        echo "  Resolved values:"
        echo "    Host:     $PGHOST"
        echo "    Port:     $PGPORT"
        echo "    Database: ${PGDATABASE:-(not set)}"
        echo "    User:     $PGUSER"
        echo "    Password: ${PGPASSWORD:+(set)}"
        [ -z "${PGPASSWORD:-}" ] && echo "    Password: (empty)"
    )
    echo -e "  ${GREEN}✅${NC} Config loaded successfully"
else
    echo -e "  ${RED}❌${NC} $PG_ENV not found — cannot verify config"
fi

echo ""
echo "Config setup complete. Running agent-install.sh..."
echo ""
exec "$SCRIPT_DIR/agent-install.sh" "$@"
