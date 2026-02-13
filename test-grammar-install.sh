#!/bin/bash
# Test script for grammar_parser installation

set -e

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
CHECK_MARK="${GREEN}✅${NC}"
INFO="${YELLOW}ℹ️${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAMMAR_SOURCE="$SCRIPT_DIR/grammar_parser"
GRAMMAR_TARGET="$HOME/.local/share/nova/grammar_parser"
FORCE_INSTALL=0

echo "Testing grammar_parser installation..."
echo ""

# Test 1: Fresh install
echo "Test 1: Fresh install"
rm -rf "$GRAMMAR_TARGET"

if [ ! -d "$GRAMMAR_TARGET" ]; then
    mkdir -p "$GRAMMAR_TARGET"
    echo -e "  ${CHECK_MARK} Created grammar_parser directory: $GRAMMAR_TARGET"
fi

# Copy Python files
files_copied=0
for source_file in "$GRAMMAR_SOURCE"/*.py; do
    if [ ! -f "$source_file" ]; then
        continue
    fi
    
    filename=$(basename "$source_file")
    target_file="$GRAMMAR_TARGET/$filename"
    
    cp "$source_file" "$target_file"
    chmod 644 "$target_file"
    files_copied=$((files_copied + 1))
done

echo -e "  ${CHECK_MARK} Copied $files_copied Python files"
echo ""

# Test 2: Hash matching (should skip)
echo "Test 2: Hash matching (files up to date)"
all_match=1
for source_file in "$GRAMMAR_SOURCE"/*.py; do
    if [ ! -f "$source_file" ]; then
        continue
    fi
    
    filename=$(basename "$source_file")
    target_file="$GRAMMAR_TARGET/$filename"
    
    if [ -f "$target_file" ]; then
        source_hash=$(sha256sum "$source_file" | awk '{print $1}')
        target_hash=$(sha256sum "$target_file" | awk '{print $1}')
        
        if [ "$source_hash" != "$target_hash" ]; then
            all_match=0
            break
        fi
    fi
done

if [ $all_match -eq 1 ]; then
    echo -e "  ${CHECK_MARK} All files match - would skip reinstall"
else
    echo -e "  ❌ Hash mismatch detected"
    exit 1
fi
echo ""

# Test 3: Modified file (should update)
echo "Test 3: Hash differing (update required)"
echo "# Test modification" >> "$GRAMMAR_TARGET/__init__.py"

all_match=1
for source_file in "$GRAMMAR_SOURCE"/*.py; do
    if [ ! -f "$source_file" ]; then
        continue
    fi
    
    filename=$(basename "$source_file")
    target_file="$GRAMMAR_TARGET/$filename"
    
    if [ -f "$target_file" ]; then
        source_hash=$(sha256sum "$source_file" | awk '{print $1}')
        target_hash=$(sha256sum "$target_file" | awk '{print $1}')
        
        if [ "$source_hash" != "$target_hash" ]; then
            all_match=0
            echo -e "  ${INFO} File differs: $filename (would update)"
        fi
    fi
done

if [ $all_match -eq 0 ]; then
    echo -e "  ${CHECK_MARK} Correctly detected modified files"
else
    echo -e "  ❌ Failed to detect modifications"
    exit 1
fi
echo ""

# Test 4: List installed files
echo "Test 4: Verify all required files installed"
required_files=("__init__.py" "grammar_parser.py" "grammar_patterns.py" "relation_types.py" "anaphora_resolver.py" "extract_cli.py")
missing_files=0

for file in "${required_files[@]}"; do
    if [ -f "$GRAMMAR_TARGET/$file" ]; then
        echo -e "  ${CHECK_MARK} $file"
    else
        echo -e "  ❌ Missing: $file"
        missing_files=$((missing_files + 1))
    fi
done

if [ $missing_files -eq 0 ]; then
    echo -e "  ${CHECK_MARK} All required files present"
else
    echo -e "  ❌ $missing_files files missing"
    exit 1
fi
echo ""

echo "═══════════════════════════════════════════"
echo -e "  ${CHECK_MARK} All tests passed!"
echo "═══════════════════════════════════════════"
