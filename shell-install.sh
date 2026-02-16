#!/bin/bash
# shell-install.sh — Database setup and config file generation
# Creates the PostgreSQL database and writes ~/.openclaw/postgres.json
# Issue: nova-memory #94
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Derive DB settings
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_PASSWORD="${PGPASSWORD:-}"

CONFIG_DIR="$HOME/.openclaw"
CONFIG_FILE="$CONFIG_DIR/postgres.json"

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "═══════════════════════════════════════════"
echo "  nova-memory shell-install"
echo "═══════════════════════════════════════════"
echo ""

# ============================================
# Part 1: Database Setup
# ============================================
echo "Database setup..."

# Check PostgreSQL available
if ! command -v psql &>/dev/null; then
    echo "ERROR: psql not found. Install PostgreSQL first." >&2
    exit 1
fi

if ! pg_isready -q 2>/dev/null; then
    echo "ERROR: PostgreSQL service not running." >&2
    exit 1
fi

# Create database if needed
if psql -U "$DB_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    echo -e "  ${GREEN}✅${NC} Database '$DB_NAME' already exists"
else
    echo "  Creating database '$DB_NAME'..."
    createdb -U "$DB_USER" "$DB_NAME"
    echo -e "  ${GREEN}✅${NC} Database '$DB_NAME' created"
fi

# Apply schema if present
SCHEMA_FILE="$SCRIPT_DIR/schema.sql"
if [ -f "$SCHEMA_FILE" ]; then
    echo "  Applying schema..."
    psql -U "$DB_USER" -d "$DB_NAME" -f "$SCHEMA_FILE" > /dev/null 2>&1
    echo -e "  ${GREEN}✅${NC} Schema applied"
fi

# ============================================
# Part 2: Write ~/.openclaw/postgres.json
# ============================================
echo ""
echo "Config file setup..."

# Create directory if needed
if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    echo -e "  ${GREEN}✅${NC} Created $CONFIG_DIR"
fi

# Do NOT overwrite existing config file
if [ -f "$CONFIG_FILE" ]; then
    echo -e "  ${YELLOW}⚠️${NC}  $CONFIG_FILE already exists, skipping (will not overwrite)"
else
    cat > "$CONFIG_FILE" <<EOF
{
  "host": "$DB_HOST",
  "port": $DB_PORT,
  "database": "$DB_NAME",
  "user": "$DB_USER",
  "password": "$DB_PASSWORD"
}
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "  ${GREEN}✅${NC} Wrote $CONFIG_FILE (chmod 600)"
fi

echo ""
echo "Done. Next: run agent-install.sh"
