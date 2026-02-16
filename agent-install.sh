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

# Track if gateway restart is needed
GATEWAY_RESTART_NEEDED=0

# Copy a directory tree excluding node_modules and dist directories
# Usage: copy_excluding <source_dir> <target_dir>
copy_excluding() {
    local source="$1"
    local target="$2"
    mkdir -p "$target"
    (cd "$source" && find . -type f \
        -not -path '*/node_modules/*' \
        -not -path '*/dist/*' \
        -print0 | while IFS= read -r -d '' f; do
        mkdir -p "$target/$(dirname "$f")"
        cp "$f" "$target/$f"
    done)
}

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
        target_dir="$HOME/.openclaw/hooks/$hook_name"
        
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
    
    # Check skills
    if [ -d "$SCRIPT_DIR/skills" ]; then
        local skills_target="$HOME/.openclaw/skills"
        for skill_dir in "$SCRIPT_DIR/skills"/*/; do
            if [ ! -d "$skill_dir" ]; then
                continue
            fi
            
            skill_name=$(basename "$skill_dir")
            target_skill="$skills_target/$skill_name"
            
            if [ ! -d "$target_skill" ]; then
                echo -e "  ${WARNING} skill '$skill_name' not installed"
                files_missing=$((files_missing + 1))
                continue
            fi
            
            # Check for SKILL.md file (required for OpenClaw skills)
            if [ -f "$skill_dir/SKILL.md" ]; then
                if [ -f "$target_skill/SKILL.md" ]; then
                    source_hash=$(sha256sum "$skill_dir/SKILL.md" | awk '{print $1}')
                    target_hash=$(sha256sum "$target_skill/SKILL.md" | awk '{print $1}')
                    
                    files_checked=$((files_checked + 1))
                    
                    if [ "$source_hash" = "$target_hash" ]; then
                        echo -e "  ${CHECK_MARK} skill '$skill_name' SKILL.md matches"
                        files_matching=$((files_matching + 1))
                    else
                        echo -e "  ${WARNING} skill '$skill_name' SKILL.md differs"
                        files_different=$((files_different + 1))
                    fi
                else
                    echo -e "  ${WARNING} skill '$skill_name' missing SKILL.md"
                    files_missing=$((files_missing + 1))
                fi
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
# Part 1.5: API Key Check and Configuration
# ============================================
echo ""
echo "API key configuration..."

# Check if OPENAI_API_KEY is set in environment
if [ -z "$OPENAI_API_KEY" ]; then
    echo -e "  ${WARNING} OPENAI_API_KEY not set"
    echo ""
    echo "OpenAI API key is required for semantic recall (embeddings)."
    echo "Get your API key from: https://platform.openai.com/api-keys"
    echo ""
    read -p "Enter your OpenAI API key (or press Enter to cancel): " user_api_key
    
    if [ -z "$user_api_key" ]; then
        echo -e "  ${CROSS_MARK} Installation cancelled - OPENAI_API_KEY is required"
        echo ""
        echo "Please set OPENAI_API_KEY and run the installer again:"
        echo "  export OPENAI_API_KEY='your-key-here'"
        echo "  ./install.sh"
        exit 1
    fi
    
    # Configure the key in OpenClaw config
    OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
    
    if [ ! -f "$OPENCLAW_CONFIG" ]; then
        echo -e "  ${WARNING} OpenClaw config not found at $OPENCLAW_CONFIG"
        echo "      Creating new config file..."
        mkdir -p "$HOME/.openclaw"
        echo '{}' > "$OPENCLAW_CONFIG"
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        echo -e "  ${CROSS_MARK} jq not installed (required to configure API key)"
        echo "      Install: sudo apt install jq"
        echo ""
        echo "      After installing jq, you can manually add the key to $OPENCLAW_CONFIG:"
        echo "      Or set it in your environment and restart the gateway"
        exit 1
    fi
    
    # Backup config before modification
    cp "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG.backup-$(date +%s)"
    
    # Add API key to config using jq
    TMP_CONFIG=$(mktemp)
    jq --arg key "$user_api_key" '.env.OPENAI_API_KEY = $key' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"
    mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
    
    echo -e "  ${CHECK_MARK} OPENAI_API_KEY configured in $OPENCLAW_CONFIG"
    GATEWAY_RESTART_NEEDED=1
else
    echo -e "  ${CHECK_MARK} OPENAI_API_KEY set: ${OPENAI_API_KEY:0:8}..."
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
HOOKS_TARGET="$HOME/.openclaw/hooks"

# Create hooks directory if needed
if [ ! -d "$HOOKS_TARGET" ]; then
    mkdir -p "$HOOKS_TARGET"
    echo -e "  ${CHECK_MARK} Created hooks directory: $HOOKS_TARGET"
else
    echo "  Hooks directory exists: $HOOKS_TARGET"
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
    
    # If not forcing, check if files are already up to date
    if [ $FORCE_INSTALL -eq 0 ] && [ -d "$target" ]; then
        local all_match=1
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
                    all_match=0
                    break
                fi
            else
                # Target file missing, need to reinstall
                all_match=0
                break
            fi
        done
        
        if [ $all_match -eq 1 ]; then
            echo -e "  ${INFO} $hook_name up to date"
            return 2
        fi
    fi
    
    # Remove existing target if it exists
    local was_existing=0
    if [ -e "$target" ]; then
        was_existing=1
        rm -rf "$target"
    fi
    
    # Copy hook directory (excluding node_modules and dist)
    copy_excluding "$source" "$target"
    if [ $was_existing -eq 1 ]; then
        echo -e "  ${CHECK_MARK} $hook_name updated"
    else
        echo -e "  ${CHECK_MARK} $hook_name installed"
    fi
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
SCRIPTS_TARGET_WORKSPACE="$WORKSPACE/scripts"
SCRIPTS_TARGET_OPENCLAW="$HOME/.openclaw/scripts"

# Copy scripts directory to both locations:
# 1. Workspace scripts (for hooks using relative paths)
# 2. OpenClaw scripts (where semantic-recall handler expects them)
if [ -d "$SCRIPTS_SOURCE" ]; then
    # Create both target directories
    mkdir -p "$SCRIPTS_TARGET_WORKSPACE"
    mkdir -p "$SCRIPTS_TARGET_OPENCLAW"
    
    # Copy scripts, respecting force flag
    scripts_copied=0
    scripts_updated=0
    scripts_skipped=0
    
    for source_file in "$SCRIPTS_SOURCE"/*.sh "$SCRIPTS_SOURCE"/*.py; do
        if [ ! -f "$source_file" ]; then
            continue
        fi
        
        filename=$(basename "$source_file")
        target_file_workspace="$SCRIPTS_TARGET_WORKSPACE/$filename"
        target_file_openclaw="$SCRIPTS_TARGET_OPENCLAW/$filename"
        
        # Check if we should skip (both files match source)
        if [ $FORCE_INSTALL -eq 0 ]; then
            source_hash=$(sha256sum "$source_file" | awk '{print $1}')
            
            workspace_matches=0
            openclaw_matches=0
            
            if [ -f "$target_file_workspace" ]; then
                workspace_hash=$(sha256sum "$target_file_workspace" | awk '{print $1}')
                [ "$source_hash" = "$workspace_hash" ] && workspace_matches=1
            fi
            
            if [ -f "$target_file_openclaw" ]; then
                openclaw_hash=$(sha256sum "$target_file_openclaw" | awk '{print $1}')
                [ "$source_hash" = "$openclaw_hash" ] && openclaw_matches=1
            fi
            
            # If both locations match source, skip
            if [ $workspace_matches -eq 1 ] && [ $openclaw_matches -eq 1 ]; then
                continue
            fi
        fi
        
        # Copy to both locations
        cp "$source_file" "$target_file_workspace"
        cp "$source_file" "$target_file_openclaw"
        
        if [ -f "$target_file_workspace" ] && [ -f "$target_file_openclaw" ]; then
            scripts_copied=$((scripts_copied + 1))
        fi
    done
    
    echo -e "  ${CHECK_MARK} $scripts_copied scripts installed to:"
    echo "      • $SCRIPTS_TARGET_WORKSPACE"
    echo "      • $SCRIPTS_TARGET_OPENCLAW"
else
    echo -e "  ${CROSS_MARK} Scripts directory not found at $SCRIPTS_SOURCE"
    exit 1
fi

# Ensure all scripts are executable in both locations
SCRIPT_COUNT=0
for location in "$SCRIPTS_TARGET_WORKSPACE" "$SCRIPTS_TARGET_OPENCLAW"; do
    for script in "$location"/*.sh "$location"/*.py; do
        if [ -f "$script" ]; then
            chmod +x "$script"
            SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
        fi
    done
done

echo -e "  ${CHECK_MARK} Made $SCRIPT_COUNT scripts executable"

# Check Python dependencies (if Python scripts exist)
if ls "$SCRIPTS_TARGET_WORKSPACE"/*.py &> /dev/null; then
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
# Part 4.5: Grammar Parser Installation
# ============================================
echo ""
echo "Grammar parser installation..."

GRAMMAR_SOURCE="$SCRIPT_DIR/grammar_parser"
GRAMMAR_TARGET="$HOME/.local/share/nova/grammar_parser"

# Create target directory if needed
if [ ! -d "$GRAMMAR_TARGET" ]; then
    mkdir -p "$GRAMMAR_TARGET"
    echo -e "  ${CHECK_MARK} Created grammar_parser directory: $GRAMMAR_TARGET"
else
    echo "  Grammar parser directory exists: $GRAMMAR_TARGET"
fi

# Function to install grammar parser files (similar to install_hook)
install_grammar_parser() {
    local source="$GRAMMAR_SOURCE"
    local target="$GRAMMAR_TARGET"
    
    if [ ! -d "$source" ]; then
        echo -e "  ${WARNING} Grammar parser source not found at $source (skipping)"
        return 1
    fi
    
    # If not forcing, check if files are already up to date
    if [ $FORCE_INSTALL -eq 0 ]; then
        local all_match=1
        for source_file in "$source"/*.py; do
            if [ ! -f "$source_file" ]; then
                continue
            fi
            
            filename=$(basename "$source_file")
            target_file="$target/$filename"
            
            if [ -f "$target_file" ]; then
                source_hash=$(sha256sum "$source_file" | awk '{print $1}')
                target_hash=$(sha256sum "$target_file" | awk '{print $1}')
                
                if [ "$source_hash" != "$target_hash" ]; then
                    all_match=0
                    break
                fi
            else
                # Target file missing, need to install
                all_match=0
                break
            fi
        done
        
        if [ $all_match -eq 1 ]; then
            echo -e "  ${INFO} Grammar parser files up to date"
            return 2
        fi
    fi
    
    # Copy Python files
    local files_copied=0
    for source_file in "$source"/*.py; do
        if [ ! -f "$source_file" ]; then
            continue
        fi
        
        filename=$(basename "$source_file")
        target_file="$target/$filename"
        
        cp "$source_file" "$target_file"
        chmod 644 "$target_file"
        files_copied=$((files_copied + 1))
    done
    
    if [ $files_copied -gt 0 ]; then
        echo -e "  ${CHECK_MARK} Copied $files_copied Python files to grammar_parser/"
        return 0
    else
        echo -e "  ${WARNING} No Python files found to install"
        return 1
    fi
}

# Install grammar parser files
install_grammar_parser && grammar_install_result=$? || grammar_install_result=$?

# Install Python dependencies for grammar parser
if [ $grammar_install_result -eq 0 ] || [ $grammar_install_result -eq 2 ]; then
    echo ""
    echo "Grammar parser dependencies..."
    
    # Check if venv exists
    if [ ! -d "$VENV_DIR" ]; then
        echo -e "  ${WARNING} Virtual environment not found at $VENV_DIR"
        echo "      Python dependencies will be checked in Part 5"
    else
        # Check if spacy is installed
        if "$VENV_PYTHON" -c "import spacy" &> /dev/null; then
            SPACY_VERSION=$("$VENV_PYTHON" -c "import spacy; print(spacy.__version__)" 2>/dev/null)
            echo -e "  ${CHECK_MARK} spacy already installed (version $SPACY_VERSION)"
        else
            echo "  Installing spacy>=3.7.0..."
            if "$VENV_PIP" install "spacy>=3.7.0" &> /dev/null; then
                echo -e "  ${CHECK_MARK} spacy installed successfully"
            else
                echo -e "  ${WARNING} Failed to install spacy"
                echo "      Try manually: $VENV_PIP install spacy>=3.7.0"
                VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
            fi
        fi
        
        # Check if en_core_web_sm model is installed
        if "$VENV_PYTHON" -c "import spacy; spacy.load('en_core_web_sm')" &> /dev/null; then
            echo -e "  ${CHECK_MARK} spacy model en_core_web_sm already installed"
        else
            echo "  Downloading spacy model en_core_web_sm..."
            if "$VENV_PYTHON" -m spacy download en_core_web_sm &> /dev/null; then
                echo -e "  ${CHECK_MARK} spacy model en_core_web_sm downloaded successfully"
            else
                echo -e "  ${WARNING} Failed to download spacy model"
                echo "      Try manually: $VENV_PYTHON -m spacy download en_core_web_sm"
                VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
            fi
        fi
        
        # Verify grammar_parser can be imported
        echo "  Verifying grammar_parser installation..."
        
        # Add grammar_parser to PYTHONPATH and test import
        if PYTHONPATH="$GRAMMAR_TARGET:$PYTHONPATH" "$VENV_PYTHON" -c "import grammar_parser; print('✓ Import successful')" 2>/dev/null | grep -q "✓"; then
            echo -e "  ${CHECK_MARK} grammar_parser import verified"
        else
            echo -e "  ${WARNING} grammar_parser import test failed"
            echo "      Files are installed but may need additional configuration"
            VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
        fi
    fi
fi

# ============================================
# Part 4.6: OpenClaw Config Patching
# ============================================
echo ""
echo "OpenClaw config patching..."

OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
ENABLE_HOOKS_SCRIPT="$SCRIPT_DIR/scripts/enable-hooks.sh"

# Check if jq is available (required for config patching)
if ! command -v jq &> /dev/null; then
    echo -e "  ${WARNING} jq not installed (needed for config patching)"
    echo "      Install: sudo apt install jq"
    echo "      Skipping automatic config patching"
    VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
elif [ ! -f "$OPENCLAW_CONFIG" ]; then
    echo -e "  ${WARNING} OpenClaw config not found at $OPENCLAW_CONFIG"
    echo "      Config patching skipped"
    VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
elif [ ! -f "$ENABLE_HOOKS_SCRIPT" ]; then
    echo -e "  ${WARNING} enable-hooks.sh script not found"
    echo "      Config patching skipped"
    VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
else
    # Make sure enable-hooks.sh is executable
    chmod +x "$ENABLE_HOOKS_SCRIPT"
    
    # Run the config patching script
    echo "  Enabling nova-memory hooks in OpenClaw config..."
    if "$ENABLE_HOOKS_SCRIPT" "$OPENCLAW_CONFIG" > /dev/null 2>&1; then
        echo -e "  ${CHECK_MARK} Hooks enabled in OpenClaw config"
        echo "      • memory-extract"
        echo "      • semantic-recall"
        echo "      • session-init"
        GATEWAY_RESTART_NEEDED=1
    else
        echo -e "  ${WARNING} Failed to patch OpenClaw config"
        echo "      You can run manually: $ENABLE_HOOKS_SCRIPT"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    fi
fi

# ============================================
# Part 4.7: Skills Installation
# ============================================
echo ""
echo "Skills installation..."

SKILLS_SOURCE="$SCRIPT_DIR/skills"
SKILLS_TARGET="$HOME/.openclaw/skills"

# Function to install skills (similar pattern to hooks)
install_skills() {
    if [ ! -d "$SKILLS_SOURCE" ]; then
        echo -e "  ${WARNING} Skills source directory not found: $SKILLS_SOURCE"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
        return 1
    fi
    
    # Check if source is empty
    if [ -z "$(ls -A "$SKILLS_SOURCE" 2>/dev/null)" ]; then
        echo -e "  ${WARNING} Skills source directory is empty"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
        return 1
    fi
    
    # Create target directory if needed
    if [ ! -d "$SKILLS_TARGET" ]; then
        mkdir -p "$SKILLS_TARGET"
        echo -e "  ${CHECK_MARK} Created skills directory: $SKILLS_TARGET"
    fi
    
    local skills_installed=0
    local skills_skipped=0
    local skills_updated=0
    
    # Iterate through each skill directory
    for skill_dir in "$SKILLS_SOURCE"/*/; do
        if [ ! -d "$skill_dir" ]; then
            continue
        fi
        
        skill_name=$(basename "$skill_dir")
        target_skill="$SKILLS_TARGET/$skill_name"
        
        # Check if skill already exists
        if [ -d "$target_skill" ]; then
            if [ $FORCE_INSTALL -eq 1 ]; then
                # Force mode: overwrite
                rm -rf "$target_skill"
                copy_excluding "$skill_dir" "$target_skill"
                echo -e "  ${CHECK_MARK} $skill_name updated (forced)"
                skills_updated=$((skills_updated + 1))
            else
                # Check if files match
                local needs_update=0
                
                # Find all files in source skill and compare
                while IFS= read -r -d '' source_file; do
                    rel_path="${source_file#$skill_dir}"
                    target_file="$target_skill/$rel_path"
                    
                    if [ ! -f "$target_file" ]; then
                        needs_update=1
                        break
                    fi
                    
                    source_hash=$(sha256sum "$source_file" | awk '{print $1}')
                    target_hash=$(sha256sum "$target_file" | awk '{print $1}')
                    
                    if [ "$source_hash" != "$target_hash" ]; then
                        needs_update=1
                        break
                    fi
                done < <(find "$skill_dir" -type f -print0)
                
                if [ $needs_update -eq 0 ]; then
                    echo -e "  ${INFO} $skill_name up to date"
                    skills_skipped=$((skills_skipped + 1))
                else
                    echo -e "  ${WARNING} $skill_name exists with local modifications (use --force to overwrite)"
                    skills_skipped=$((skills_skipped + 1))
                fi
            fi
        else
            # New skill: install it (excluding node_modules and dist)
            copy_excluding "$skill_dir" "$target_skill"
            echo -e "  ${CHECK_MARK} $skill_name installed"
            skills_installed=$((skills_installed + 1))
        fi
    done
    
    # Summary
    if [ $skills_installed -gt 0 ] || [ $skills_updated -gt 0 ]; then
        echo -e "  ${CHECK_MARK} Skills: $skills_installed installed, $skills_updated updated, $skills_skipped skipped"
    elif [ $skills_skipped -gt 0 ]; then
        echo -e "  ${INFO} Skills: all $skills_skipped skill(s) already present"
    fi
    
    return 0
}

# Install skills
install_skills

# ============================================
# Part 5: Python Virtual Environment Setup
# ============================================
echo ""
echo "Python virtual environment setup..."

VENV_DIR="$HOME/.local/share/$USER/venv"
REQUIRED_PACKAGES=("openai" "tiktoken" "psycopg2-binary" "pillow")

# Check if Python3 is available
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version | awk '{print $2}')
    echo -e "  ${CHECK_MARK} Python3 available ($PYTHON_VERSION)"
else
    echo -e "  ${CROSS_MARK} Python3 not found (required for memory scripts)"
    echo "      Install: sudo apt install python3 python3-pip"
    exit 1
fi

# Check if python3-venv is available
if python3 -m venv --help &> /dev/null; then
    echo -e "  ${CHECK_MARK} python3-venv available"
else
    echo -e "  ${CROSS_MARK} python3-venv module not found"
    echo "      Install: sudo apt install python3-venv"
    echo ""
    echo "      Note: PEP 668 restricts pip on system Python in Ubuntu 24.04+"
    echo "            Using python3-venv instead of pip virtualenv"
    exit 1
fi

# Create venv if it doesn't exist
if [ -d "$VENV_DIR" ]; then
    echo -e "  ${CHECK_MARK} Virtual environment exists at $VENV_DIR"
else
    echo "  Creating virtual environment at $VENV_DIR..."
    # Create parent directories if needed
    mkdir -p "$(dirname "$VENV_DIR")"
    
    if python3 -m venv "$VENV_DIR" &> /dev/null; then
        echo -e "  ${CHECK_MARK} Virtual environment created"
    else
        echo -e "  ${CROSS_MARK} Failed to create virtual environment"
        echo "      Try: python3 -m venv $VENV_DIR"
        exit 1
    fi
fi

# Check and install required packages
echo "  Checking Python dependencies..."
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

if [ ! -f "$VENV_PYTHON" ]; then
    echo -e "  ${CROSS_MARK} Virtual environment Python not found at $VENV_PYTHON"
    exit 1
fi

PACKAGES_TO_INSTALL=()
PACKAGES_INSTALLED=()

for package in "${REQUIRED_PACKAGES[@]}"; do
    # Check if package is already installed in venv
    if "$VENV_PYTHON" -c "import ${package//-/_}" &> /dev/null; then
        PACKAGES_INSTALLED+=("$package")
    else
        PACKAGES_TO_INSTALL+=("$package")
    fi
done

if [ ${#PACKAGES_INSTALLED[@]} -gt 0 ]; then
    echo -e "  ${CHECK_MARK} ${#PACKAGES_INSTALLED[@]} packages already installed: ${PACKAGES_INSTALLED[*]}"
fi

if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
    echo "  Installing missing packages: ${PACKAGES_TO_INSTALL[*]}"
    if "$VENV_PIP" install "${PACKAGES_TO_INSTALL[@]}" &> /dev/null; then
        echo -e "  ${CHECK_MARK} ${#PACKAGES_TO_INSTALL[@]} packages installed successfully"
    else
        echo -e "  ${WARNING} Some packages failed to install"
        echo "      Try manually: $VENV_PIP install ${PACKAGES_TO_INSTALL[*]}"
        VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + 1))
    fi
else
    echo -e "  ${CHECK_MARK} All required packages already installed"
fi

# Verify all packages are now available
MISSING_PACKAGES=()
for package in "${REQUIRED_PACKAGES[@]}"; do
    if ! "$VENV_PYTHON" -c "import ${package//-/_}" &> /dev/null; then
        MISSING_PACKAGES+=("$package")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo -e "  ${WARNING} Missing packages after installation: ${MISSING_PACKAGES[*]}"
    VERIFICATION_WARNINGS=$((VERIFICATION_WARNINGS + ${#MISSING_PACKAGES[@]}))
else
    echo -e "  ${CHECK_MARK} All Python dependencies verified"
fi

# ============================================
# Part 6: Cron Job Setup (Memory Maintenance)
# ============================================
echo ""
echo "Cron job setup (memory maintenance)..."

CRON_FILE="/etc/cron.d/nova-memory-maintenance"
CRON_USER="${DB_USER//-/_}"  # Use same user as database
SCRIPT_PATH="$SCRIPTS_TARGET_OPENCLAW/memory-maintenance.py"

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
# Part 7: Verification
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

# Check if we patched the config successfully
if [ -n "${GATEWAY_RESTART_NEEDED:-}" ]; then
    echo "1. Restart OpenClaw gateway to enable hooks:"
    echo "   openclaw gateway restart"
    echo ""
    echo "2. Verify installation:"
    echo "   $0 --verify-only"
    echo ""
    echo "3. Check logs:"
    echo "   tail -f ~/clawd/logs/memory-extract-hook.log"
    echo ""
else
    echo "1. Hooks were not automatically enabled. Enable them manually:"
    for hook in "${INSTALLED_HOOKS[@]}"; do
        echo "   openclaw hooks enable $hook"
    done
    echo ""
    echo "2. Or use the enable-hooks.sh script:"
    echo "   $SCRIPT_DIR/scripts/enable-hooks.sh"
    echo ""
    echo "3. Then restart OpenClaw gateway:"
    echo "   openclaw gateway restart"
    echo ""
    echo "4. Verify installation:"
    echo "   $0 --verify-only"
    echo ""
    echo "5. Check logs:"
    echo "   tail -f ~/clawd/logs/memory-extract-hook.log"
    echo ""
fi
