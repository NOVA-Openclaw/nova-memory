#!/bin/bash
# nova-memory comprehensive installer
# Idempotent - safe to run multiple times

set -e

VERSION="2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use current OS user for both DB user and name
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"  # Replace hyphens with underscores (nova-staging → nova_staging_memory)
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace-claude-code}"

# Parse arguments
VERIFY_ONLY=0
FORCE_INSTALL=0
DB_NAME_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --verify-only)
            VERIFY_ONLY=1
            shift
            ;;
        --force)
            FORCE_INSTALL=1
            shift
            ;;
        --database|-d)
            DB_NAME_OVERRIDE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verify-only         Check installation without modifying anything"
            echo "  --force               Force overwrite existing files (skip file verification)"
            echo "  --database, -d NAME   Override database name (default: \${USER}_memory)"
            echo "  --help                Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                              # Use default database name"
            echo "  $0 --database nova_memory       # Use specific database"
            echo "  $0 -d nova_memory               # Short form"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage information"
            exit 1
            ;;
    esac
done

# Apply database name override if provided
if [ -n "$DB_NAME_OVERRIDE" ]; then
    DB_NAME="$DB_NAME_OVERRIDE"
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Status indicators
CHECK_MARK="${GREEN}✅${NC}"
CROSS_MARK="${RED}❌${NC}"
WARNING="${YELLOW}⚠️${NC}"
INFO="${BLUE}ℹ️${NC}"

# Verification results
VERIFICATION_PASSED=0
VERIFICATION_WARNINGS=0
VERIFICATION_ERRORS=0

echo ""
echo "═══════════════════════════════════════════"
if [ $VERIFY_ONLY -eq 1 ]; then
    echo "  nova-memory verification v${VERSION}"
else
    echo "  nova-memory installer v${VERSION}"
fi
echo "═══════════════════════════════════════════"
echo ""

# ============================================
# Verification Functions
# ============================================

verify_schema() {
    echo "Schema verification..."
    
    # Check if database exists
    if ! psql -U "$DB_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        echo -e "  ${CROSS_MARK} Database '$DB_NAME' does not exist"
        VERIFICATION_ERRORS=$((VERIFICATION_ERRORS + 1))
        return 1
    fi
    
    # Count expected tables from schema.sql
    EXPECTED_TABLES=$(grep "^CREATE TABLE" "$SCRIPT_DIR/schema.sql" 2>/dev/null | wc -l)
    
    # Count actual tables in database
    ACTUAL_TABLES=$(psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" | tr -d '[:space:]')
    
    if [ "$ACTUAL_TABLES" -eq "$EXPECTED_TABLES" ]; then
        echo -e "  ${CHECK_MARK} All $EXPECTED_TABLES tables present"
    elif [ "$ACTUAL_TABLES" -lt "$EXPECTED_TABLES" ]; then
        echo -e "  ${WARNING} Only $ACTUAL_TABLES/$EXPECTED_TABLES tables found (missing tables)"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    else
        echo -e "  ${WARNING} Found $ACTUAL_TABLES tables (expected $EXPECTED_TABLES, extra tables present)"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    fi
    
    # Verify individual table existence (detailed check)
    # Extract table names from schema.sql
    TABLE_NAMES=$(grep "^CREATE TABLE" "$SCRIPT_DIR/schema.sql" | sed -E 's/CREATE TABLE [^.]+\.([^ ]+).*/\1/' | sort)
    
    local tables_missing=()
    local tables_present=0
    
    for table in $TABLE_NAMES; do
        # Check if table exists
        TABLE_EXISTS=$(psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table'" | tr -d '[:space:]')
        
        if [ "$TABLE_EXISTS" -eq 0 ]; then
            tables_missing+=("$table")
        else
            tables_present=$((tables_present + 1))
        fi
    done
    
    if [ ${#tables_missing[@]} -gt 0 ]; then
        echo -e "  ${WARNING} Missing tables:"
        for table in "${tables_missing[@]}"; do
            echo "      • $table"
        done
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + ${#tables_missing[@]}))
    fi
    
    # Sample column count check for a few key tables
    local sample_tables=("entities" "entity_facts" "events" "lessons" "agents")
    local column_issues=0
    
    for table in "${sample_tables[@]}"; do
        # Get column count from database
        COL_COUNT=$(psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$table'" 2>/dev/null | tr -d '[:space:]')
        
        if [ -n "$COL_COUNT" ] && [ "$COL_COUNT" -gt 0 ]; then
            echo -e "  ${CHECK_MARK} Table '$table' schema present ($COL_COUNT columns)"
        elif psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table'" | grep -q 1; then
            echo -e "  ${WARNING} Table '$table' exists but column check failed"
            column_issues=$((column_issues + 1))
        fi
    done
    
    if [ $column_issues -gt 0 ]; then
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + column_issues))
    fi
    
    return 0
}

verify_files() {
    echo ""
    echo "File verification..."
    
    local files_checked=0
    local files_matching=0
    local files_different=0
    local files_missing=0
    
    # Check hooks
    for hook_dir in "$SCRIPT_DIR/hooks"/*; do
        if [ ! -d "$hook_dir" ]; then
            continue
        fi
        
        hook_name=$(basename "$hook_dir")
        target_dir="$WORKSPACE/hooks/$hook_name"
        
        if [ ! -d "$target_dir" ]; then
            echo -e "  ${WARNING} Hook '$hook_name' not installed"
            files_missing=$((files_missing + 1))
            continue
        fi
        
        # Check each file in the hook
        for source_file in "$hook_dir"/*.ts "$hook_dir"/*.js "$hook_dir"/*.sh; do
            if [ ! -f "$source_file" ]; then
                continue
            fi
            
            filename=$(basename "$source_file")
            target_file="$target_dir/$filename"
            
            if [ ! -f "$target_file" ]; then
                echo -e "  ${WARNING} $hook_name/$filename missing"
                files_missing=$((files_missing + 1))
                continue
            fi
            
            # Compare checksums
            source_hash=$(sha256sum "$source_file" | awk '{print $1}')
            target_hash=$(sha256sum "$target_file" | awk '{print $1}')
            
            files_checked=$((files_checked + 1))
            
            if [ "$source_hash" = "$target_hash" ]; then
                echo -e "  ${CHECK_MARK} $hook_name/$filename matches source"
                files_matching=$((files_matching + 1))
            else
                echo -e "  ${WARNING} $hook_name/$filename differs (local modifications?)"
                files_different=$((files_different + 1))
            fi
        done
    done
    
    # Check scripts
    if [ -d "$SCRIPT_DIR/scripts" ]; then
        for source_file in "$SCRIPT_DIR/scripts"/*.sh "$SCRIPT_DIR/scripts"/*.py; do
            if [ ! -f "$source_file" ]; then
                continue
            fi
            
            filename=$(basename "$source_file")
            target_file="$WORKSPACE/scripts/$filename"
            
            if [ ! -f "$target_file" ]; then
                echo -e "  ${WARNING} scripts/$filename missing"
                files_missing=$((files_missing + 1))
                continue
            fi
            
            # Compare checksums
            source_hash=$(sha256sum "$source_file" | awk '{print $1}')
            target_hash=$(sha256sum "$target_file" | awk '{print $1}')
            
            files_checked=$((files_checked + 1))
            
            if [ "$source_hash" = "$target_hash" ]; then
                echo -e "  ${CHECK_MARK} scripts/$filename matches source"
                files_matching=$((files_matching + 1))
            else
                echo -e "  ${WARNING} scripts/$filename differs (local modifications?)"
                files_different=$((files_different + 1))
            fi
        done
    fi
    
    if [ $files_different -gt 0 ]; then
        echo -e "  ${INFO} Run with --force to overwrite modified files"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + files_different))
    fi
    
    if [ $files_missing -gt 0 ]; then
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + files_missing))
    fi
    
    return 0
}

verify_config() {
    echo ""
    echo "Config verification..."
    
    # Check environment variables
    # Note: Hooks run as child processes of OpenClaw and inherit its environment
    # API keys should be configured in OpenClaw, not separately for nova-memory
    
    if [ -z "$PGUSER" ]; then
        echo -e "  ${WARNING} PGUSER not set (using current user: $(whoami))"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    else
        echo -e "  ${CHECK_MARK} PGUSER set: $PGUSER"
    fi
    
    if [ -z "$ANTHROPIC_API_KEY" ]; then
        echo -e "  ${WARNING} ANTHROPIC_API_KEY not set in environment"
        echo -e "      Hooks will inherit from OpenClaw's environment"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    else
        echo -e "  ${CHECK_MARK} ANTHROPIC_API_KEY set: ${ANTHROPIC_API_KEY:0:8}..."
    fi
    
    if [ -z "$OPENAI_API_KEY" ]; then
        echo -e "  ${WARNING} OPENAI_API_KEY not set in environment"
        echo -e "      Hooks will inherit from OpenClaw's environment"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    else
        echo -e "  ${CHECK_MARK} OPENAI_API_KEY set: ${OPENAI_API_KEY:0:8}..."
    fi
    
    if [ -z "$OPENCLAW_WORKSPACE" ]; then
        echo -e "  ${INFO} OPENCLAW_WORKSPACE not set (using default: $WORKSPACE)"
    else
        echo -e "  ${CHECK_MARK} OPENCLAW_WORKSPACE set: $OPENCLAW_WORKSPACE"
    fi
    
    # Check database connection
    if psql -U "$DB_USER" -d "$DB_NAME" -c '\q' 2>/dev/null; then
        echo -e "  ${CHECK_MARK} Database connection works"
    else
        echo -e "  ${CROSS_MARK} Database connection failed"
        VERIFICATION_ERRORS=$((VERIFICATION_ERRORS + 1))
        return 1
    fi
    
    # Check OpenClaw hook config
    HOOK_CONFIG="$HOME/.openclaw/hooks.json"
    if [ -f "$HOOK_CONFIG" ]; then
        echo -e "  ${CHECK_MARK} OpenClaw hook config exists"
        
        # Check if our hooks are registered
        for hook in "memory-extract" "semantic-recall" "session-init"; do
            if grep -q "\"$hook\"" "$HOOK_CONFIG" 2>/dev/null; then
                ENABLED=$(grep -A5 "\"$hook\"" "$HOOK_CONFIG" | grep -c "\"enabled\": true" || echo "0")
                if [ "$ENABLED" -gt 0 ]; then
                    echo -e "  ${CHECK_MARK} Hook '$hook' enabled in OpenClaw"
                else
                    echo -e "  ${WARNING} Hook '$hook' exists but not enabled"
                    VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
                fi
            else
                echo -e "  ${WARNING} Hook '$hook' not found in OpenClaw config"
                VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
            fi
        done
    else
        echo -e "  ${WARNING} OpenClaw hook config not found at $HOOK_CONFIG"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    fi
    
    # Check cron job installation
    CRON_FILE="/etc/cron.d/nova-memory-maintenance"
    if [ -f "$CRON_FILE" ]; then
        echo -e "  ${CHECK_MARK} Cron job installed at $CRON_FILE"
        # Verify it has correct content
        if grep -q "memory-maintenance.py" "$CRON_FILE"; then
            echo -e "  ${CHECK_MARK} Cron job configured correctly"
        else
            echo -e "  ${WARNING} Cron job exists but may need updating"
            VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
        fi
    else
        echo -e "  ${WARNING} Cron job not installed (requires manual setup)"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    fi
    
    return 0
}

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

# Check for pgvector extension
if psql -U "$DB_USER" -d postgres -tAc "SELECT 1 FROM pg_available_extensions WHERE name='vector'" | grep -q 1; then
    echo -e "  ${CHECK_MARK} pgvector extension available"
else
    echo -e "  ${WARNING} pgvector extension not found (required for semantic search)"
    echo "      Install: sudo apt install postgresql-16-pgvector"
fi

# ============================================
# Run Verification if --verify-only
# ============================================
if [ $VERIFY_ONLY -eq 1 ]; then
    echo ""
    verify_schema
    verify_files
    verify_config
    
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Verification Summary"
    echo "═══════════════════════════════════════════"
    if [ $VERIFICATION_ERRORS -gt 0 ]; then
        echo -e "  ${CROSS_MARK} $VERIFICATION_ERRORS errors found"
        exit 1
    elif [ $VERIFICATION_WARNINGS -gt 0 ]; then
        echo -e "  ${WARNING} $VERIFICATION_WARNINGS warnings found"
        exit 0
    else
        echo -e "  ${CHECK_MARK} All checks passed"
        exit 0
    fi
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
    
    # If not forcing, check if files differ
    if [ $FORCE_INSTALL -eq 0 ] && [ -d "$target" ]; then
        local files_differ=0
        for source_file in "$source"/*.ts "$source"/*.js "$source"/*.sh; do
            if [ ! -f "$source_file" ]; then
                continue
            fi
            
            filename=$(basename "$source_file")
            target_file="$target/$filename"
            
            if [ -f "$target_file" ]; then
                source_hash=$(sha256sum "$source_file" | awk '{print $1}')
                target_hash=$(sha256sum "$target_file" | awk '{print $1}')
                
                if [ "$source_hash" != "$target_hash" ]; then
                    files_differ=1
                    break
                fi
            fi
        done
        
        if [ $files_differ -eq 1 ]; then
            echo -e "  ${WARNING} $hook_name has local modifications, skipping (use --force to overwrite)"
            return 2
        fi
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
SKIPPED_HOOKS=()
for hook in "memory-extract" "semantic-recall" "session-init"; do
    install_hook "$hook" && result=$? || result=$?
    if [ $result -eq 0 ]; then
        INSTALLED_HOOKS+=("$hook")
    elif [ $result -eq 2 ]; then
        SKIPPED_HOOKS+=("$hook")
    fi
done

if [ ${#INSTALLED_HOOKS[@]} -eq 0 ] && [ ${#SKIPPED_HOOKS[@]} -eq 0 ]; then
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
    
    # Copy scripts, respecting force flag
    scripts_copied=0
    scripts_skipped=0
    
    for source_file in "$SCRIPTS_SOURCE"/*.sh "$SCRIPTS_SOURCE"/*.py; do
        if [ ! -f "$source_file" ]; then
            continue
        fi
        
        filename=$(basename "$source_file")
        target_file="$SCRIPTS_TARGET/$filename"
        
        # Check if file differs
        if [ $FORCE_INSTALL -eq 0 ] && [ -f "$target_file" ]; then
            source_hash=$(sha256sum "$source_file" | awk '{print $1}')
            target_hash=$(sha256sum "$target_file" | awk '{print $1}')
            
            if [ "$source_hash" != "$target_hash" ]; then
                echo -e "  ${WARNING} scripts/$filename differs, skipping (use --force to overwrite)"
                scripts_skipped=$((scripts_skipped + 1))
                continue
            fi
        fi
        
        cp "$source_file" "$target_file"
        scripts_copied=$((scripts_copied + 1))
    done
    
    echo -e "  ${CHECK_MARK} $scripts_copied scripts copied to workspace"
    if [ $scripts_skipped -gt 0 ]; then
        echo -e "  ${WARNING} $scripts_skipped scripts skipped (local modifications)"
    fi
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
# Part 5: Cron Job Setup (Memory Maintenance)
# ============================================
echo ""
echo "Cron job setup (memory maintenance)..."

CRON_FILE="/etc/cron.d/nova-memory-maintenance"
CRON_USER="${DB_USER//-/_}"  # Use same user as database
SCRIPT_PATH="$SCRIPTS_TARGET/memory-maintenance.py"

# Check if script exists
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "  ${WARNING} memory-maintenance.py not found at $SCRIPT_PATH"
    echo "      Cron job setup skipped"
else
    # Create cron file content
    CRON_CONTENT="# nova-memory daily maintenance - added by install.sh
# Runs memory confidence decay, duplicate merging, and archival
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
PGDATABASE=$DB_NAME

# Run at 6:00 AM daily
0 6 * * * $CRON_USER $SCRIPT_PATH >> /var/log/nova-memory-maintenance.log 2>&1
"

    # Check if we have sudo access
    if sudo -n true 2>/dev/null; then
        # We have passwordless sudo, install directly
        echo "$CRON_CONTENT" | sudo tee "$CRON_FILE" > /dev/null
        sudo chmod 644 "$CRON_FILE"
        echo -e "  ${CHECK_MARK} Cron job installed at $CRON_FILE"
        echo "      Schedule: Daily at 6:00 AM"
        echo "      Script: $SCRIPT_PATH"
        echo "      Database: $DB_NAME"
        echo "      Log: /var/log/nova-memory-maintenance.log"
    else
        # Need password or don't have sudo
        echo -e "  ${INFO} Cron job requires sudo access to install"
        echo ""
        echo "      To complete installation, run:"
        echo ""
        echo "      sudo tee $CRON_FILE > /dev/null << 'EOF'"
        echo "$CRON_CONTENT"
        echo "EOF"
        echo "      sudo chmod 644 $CRON_FILE"
        echo ""
        echo "      Or manually create $CRON_FILE with the above content"
        echo ""
        
        # Try to save to a temp file for easy installation
        TEMP_CRON="/tmp/nova-memory-cron-$(date +%s)"
        echo "$CRON_CONTENT" > "$TEMP_CRON"
        echo "      Temp cron file created at: $TEMP_CRON"
        echo "      Run: sudo cp $TEMP_CRON $CRON_FILE && sudo chmod 644 $CRON_FILE"
        echo ""
        
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    fi
fi

# ============================================
# Part 6: Verification
# ============================================
echo ""
verify_schema
verify_files
verify_config

# ============================================
# Installation Complete
# ============================================
echo ""
echo "═══════════════════════════════════════════"
if [ $VERIFICATION_ERRORS -gt 0 ]; then
    echo -e "  ${CROSS_MARK} Installation completed with errors"
elif [ $VERIFICATION_WARNINGS -gt 0 ]; then
    echo -e "  ${WARNING} Installation completed with warnings"
else
    echo -e "  ${GREEN}Installation complete!${NC}"
fi
echo "═══════════════════════════════════════════"
echo ""

if [ ${#INSTALLED_HOOKS[@]} -gt 0 ]; then
    echo "Installed hooks:"
    for hook in "${INSTALLED_HOOKS[@]}"; do
        echo "  • $hook"
    done
    echo ""
fi

if [ ${#SKIPPED_HOOKS[@]} -gt 0 ]; then
    echo "Skipped hooks (local modifications):"
    for hook in "${SKIPPED_HOOKS[@]}"; do
        echo "  • $hook"
    done
    echo ""
fi

echo "Next steps:"
echo ""
echo "1. Enable hooks in OpenClaw:"
for hook in "${INSTALLED_HOOKS[@]}"; do
    echo "   openclaw hooks enable $hook"
done
echo ""
echo "2. Verify installation:"
echo "   $0 --verify-only"
echo ""
echo "3. Check logs:"
echo "   tail -f ~/clawd/logs/memory-extract-hook.log"
echo ""
