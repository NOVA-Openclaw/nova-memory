#!/bin/bash
# nova-memory comprehensive installer
# Idempotent - safe to run multiple times

set -e

VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use current OS user for both DB user and name
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"  # Replace hyphens with underscores (nova-staging → nova_staging_memory)
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-claude-code}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Status indicators
CHECK_MARK="${GREEN}✅${NC}"
CROSS_MARK="${RED}❌${NC}"
WARNING="${YELLOW}⚠️${NC}"

echo ""
echo "═══════════════════════════════════════════"
echo "  nova-memory installer v${VERSION}"
echo "═══════════════════════════════════════════"
echo ""

# ============================================
# Part 1: Prerequisites Check
# ============================================
echo "Checking prerequisites..."

# Check PostgreSQL installed
if command -v psql &> /dev/null; then
    PG_VERSION=$(psql --version | awk '{print $3}')
    echo -e "  ${CHECK_MARK} PostgreSQL installed ($PG_VERSION)"
else
    echo -e "  ${CROSS_MARK} PostgreSQL not found"
    echo ""
    echo "Please install PostgreSQL first:"
    echo "  Ubuntu/Debian: sudo apt install postgresql postgresql-contrib"
    echo "  macOS: brew install postgresql"
    exit 1
fi

# Check psql command available
if command -v psql &> /dev/null; then
    echo -e "  ${CHECK_MARK} psql command available"
else
    echo -e "  ${CROSS_MARK} psql command not found"
    exit 1
fi

# Check PostgreSQL service running
if pg_isready -q 2>/dev/null; then
    echo -e "  ${CHECK_MARK} PostgreSQL service running"
else
    echo -e "  ${CROSS_MARK} PostgreSQL service not running"
    echo ""
    echo "Please start PostgreSQL:"
    echo "  Ubuntu/Debian: sudo systemctl start postgresql"
    echo "  macOS: brew services start postgresql"
    exit 1
fi

# Check for required environment variables
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo -e "  ${WARNING} ANTHROPIC_API_KEY not set (memory extraction will fail)"
else
    echo -e "  ${CHECK_MARK} ANTHROPIC_API_KEY set"
fi

# Check for pgvector extension
if psql -U "$DB_USER" -d postgres -tAc "SELECT 1 FROM pg_available_extensions WHERE name='vector'" | grep -q 1; then
    echo -e "  ${CHECK_MARK} pgvector extension available"
else
    echo -e "  ${WARNING} pgvector extension not found (required for semantic search)"
    echo "      Install: sudo apt install postgresql-16-pgvector"
fi

# ============================================
# Part 2: Database Setup (Idempotent)
# ============================================
echo ""
echo "Database setup..."

# Check if database exists
if psql -U "$DB_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    echo -e "  ${CHECK_MARK} Database '$DB_NAME' exists"
    
    # Verify connection
    if psql -U "$DB_USER" -d "$DB_NAME" -c '\q' 2>/dev/null; then
        echo -e "  ${CHECK_MARK} Database connection verified"
    else
        echo -e "  ${CROSS_MARK} Cannot connect to database '$DB_NAME'"
        exit 1
    fi
else
    echo "  Creating database '$DB_NAME'..."
    createdb -U "$DB_USER" "$DB_NAME" 2>/dev/null || {
        echo -e "  ${CROSS_MARK} Failed to create database"
        echo "      Try: createdb -U $DB_USER $DB_NAME"
        exit 1
    }
    echo -e "  ${CHECK_MARK} Database '$DB_NAME' created"
fi

# Apply schema (idempotent - uses CREATE IF NOT EXISTS)
SCHEMA_FILE="$SCRIPT_DIR/schema.sql"
if [ ! -f "$SCHEMA_FILE" ]; then
    echo -e "  ${CROSS_MARK} schema.sql not found at $SCHEMA_FILE"
    exit 1
fi

echo "  Applying schema..."
SCHEMA_OUTPUT=$(psql -U "$DB_USER" -d "$DB_NAME" -f "$SCHEMA_FILE" 2>&1)
SCHEMA_EXIT_CODE=$?

if [ $SCHEMA_EXIT_CODE -eq 0 ]; then
    # Count tables created vs already existed
    CREATED_COUNT=$(echo "$SCHEMA_OUTPUT" | grep -c "CREATE TABLE" 2>/dev/null || echo "0")
    SKIPPED_COUNT=$(echo "$SCHEMA_OUTPUT" | grep -c "already exists" 2>/dev/null || echo "0")
    
    # Get total table count
    TABLE_COUNT=$(psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" | tr -d '[:space:]')
    
    echo -e "  ${CHECK_MARK} Schema applied successfully"
    if [ "$CREATED_COUNT" -gt 0 ] 2>/dev/null; then
        echo "      Created $CREATED_COUNT new tables"
    fi
    if [ "$SKIPPED_COUNT" -gt 0 ] 2>/dev/null; then
        echo "      Skipped $SKIPPED_COUNT existing objects"
    fi
    echo "      Total tables in database: $TABLE_COUNT"
else
    echo -e "  ${CROSS_MARK} Schema application failed"
    echo "$SCHEMA_OUTPUT"
    exit 1
fi

# ============================================
# Part 3: Hooks Installation
# ============================================
echo ""
echo "Hooks installation..."

HOOKS_SOURCE="$SCRIPT_DIR/hooks"
HOOKS_TARGET="$WORKSPACE/hooks"

# Create hooks directory if needed
if [ ! -d "$HOOKS_TARGET" ]; then
    mkdir -p "$HOOKS_TARGET"
    echo "  Created hooks directory: $HOOKS_TARGET"
fi

# Function to install a hook (copy, not symlink)
install_hook() {
    local hook_name="$1"
    local source="$HOOKS_SOURCE/$hook_name"
    local target="$HOOKS_TARGET/$hook_name"
    
    if [ ! -d "$source" ]; then
        echo -e "  ${WARNING} Hook not found: $hook_name (skipping)"
        return 1
    fi
    
    # Remove existing target if it exists
    if [ -e "$target" ]; then
        rm -rf "$target"
    fi
    
    # Copy hook directory
    cp -r "$source" "$target"
    echo -e "  ${CHECK_MARK} $hook_name installed"
    return 0
}

# Install each hook
INSTALLED_HOOKS=()
for hook in "memory-extract" "semantic-recall" "session-init"; do
    if install_hook "$hook"; then
        INSTALLED_HOOKS+=("$hook")
    fi
done

if [ ${#INSTALLED_HOOKS[@]} -eq 0 ]; then
    echo -e "  ${CROSS_MARK} No hooks installed"
    exit 1
fi

# ============================================
# Part 4: Scripts Setup
# ============================================
echo ""
echo "Scripts setup..."

SCRIPTS_SOURCE="$SCRIPT_DIR/scripts"
SCRIPTS_TARGET="$WORKSPACE/scripts"

# Copy scripts directory to workspace (so hooks can find them via relative path)
if [ -d "$SCRIPTS_SOURCE" ]; then
    # Create or update scripts directory
    mkdir -p "$SCRIPTS_TARGET"
    
    # Copy all scripts
    cp -r "$SCRIPTS_SOURCE"/* "$SCRIPTS_TARGET/" 2>/dev/null || true
    
    echo -e "  ${CHECK_MARK} Scripts copied to workspace"
else
    echo -e "  ${CROSS_MARK} Scripts directory not found at $SCRIPTS_SOURCE"
    exit 1
fi

# Ensure all scripts are executable
SCRIPT_COUNT=0
for script in "$SCRIPTS_TARGET"/*.sh "$SCRIPTS_TARGET"/*.py; do
    if [ -f "$script" ]; then
        chmod +x "$script"
        SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
    fi
done

echo -e "  ${CHECK_MARK} Made $SCRIPT_COUNT scripts executable"

# Check Python dependencies (if Python scripts exist)
if ls "$SCRIPTS_TARGET"/*.py &> /dev/null; then
    if command -v python3 &> /dev/null; then
        echo -e "  ${CHECK_MARK} Python3 available"
        
        # Check for common dependencies
        MISSING_DEPS=()
        for dep in "psycopg2" "anthropic" "openai"; do
            if ! python3 -c "import $dep" 2>/dev/null; then
                MISSING_DEPS+=("$dep")
            fi
        done
        
        if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
            echo -e "  ${WARNING} Missing Python dependencies: ${MISSING_DEPS[*]}"
            echo "      Install: pip3 install ${MISSING_DEPS[*]}"
        else
            echo -e "  ${CHECK_MARK} Python dependencies verified"
        fi
    else
        echo -e "  ${WARNING} Python3 not found (required for some scripts)"
    fi
fi

# ============================================
# Part 5: Verification
# ============================================
echo ""
echo "Verification..."

# Test database connection
if psql -U "$DB_USER" -d "$DB_NAME" -c '\q' 2>/dev/null; then
    echo -e "  ${CHECK_MARK} Database connection OK"
else
    echo -e "  ${CROSS_MARK} Database connection failed"
    exit 1
fi

# Test a simple query
QUERY_RESULT=$(psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null)
if [ $? -eq 0 ]; then
    echo -e "  ${CHECK_MARK} Test query OK (found $QUERY_RESULT tables)"
else
    echo -e "  ${CROSS_MARK} Test query failed"
fi

# List installed hooks
echo -e "  ${CHECK_MARK} Installed hooks:"
for hook in "${INSTALLED_HOOKS[@]}"; do
    echo "      • $hook"
done

# ============================================
# Installation Complete
# ============================================
echo ""
echo "═══════════════════════════════════════════"
echo -e "  ${GREEN}Installation complete!${NC}"
echo "═══════════════════════════════════════════"
echo ""
echo "Next steps:"
echo ""
echo "1. Enable hooks in OpenClaw:"
for hook in "${INSTALLED_HOOKS[@]}"; do
    echo "   openclaw hooks enable $hook"
done
echo ""
echo "2. Verify installation:"
echo "   openclaw hooks list"
echo ""
echo "3. Set environment variables (if not already set):"
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "   export ANTHROPIC_API_KEY='your-key-here'"
fi
echo ""
echo "4. Check logs:"
echo "   tail -f ~/clawd/logs/memory-extract-hook.log"
echo ""
