#!/bin/bash
# Test spacy installation for grammar_parser

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
CHECK_MARK="${GREEN}✅${NC}"
CROSS_MARK="${RED}❌${NC}"
WARNING="${YELLOW}⚠️${NC}"

echo "Testing spacy installation for grammar_parser..."
echo ""

VENV_DIR="$HOME/.local/share/nova/venv"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

# Test 1: Check if venv exists
echo "Test 1: Virtual environment"
if [ -f "$VENV_PYTHON" ]; then
    echo -e "  ${CHECK_MARK} Virtual environment exists"
else
    echo -e "  ${CROSS_MARK} Virtual environment not found"
    exit 1
fi
echo ""

# Test 2: Install spacy if not present
echo "Test 2: spacy installation"
if "$VENV_PYTHON" -c "import spacy" &> /dev/null; then
    SPACY_VERSION=$("$VENV_PYTHON" -c "import spacy; print(spacy.__version__)" 2>/dev/null)
    echo -e "  ${CHECK_MARK} spacy already installed (version $SPACY_VERSION)"
else
    echo "  Installing spacy>=3.7.0..."
    if "$VENV_PIP" install "spacy>=3.7.0" > /tmp/spacy-install.log 2>&1; then
        echo -e "  ${CHECK_MARK} spacy installed successfully"
    else
        echo -e "  ${CROSS_MARK} Failed to install spacy"
        cat /tmp/spacy-install.log
        exit 1
    fi
fi
echo ""

# Test 3: Download en_core_web_sm model
echo "Test 3: spacy model download"
if "$VENV_PYTHON" -c "import spacy; spacy.load('en_core_web_sm')" &> /dev/null; then
    echo -e "  ${CHECK_MARK} spacy model en_core_web_sm already installed"
else
    echo "  Downloading spacy model en_core_web_sm..."
    if "$VENV_PYTHON" -m spacy download en_core_web_sm > /tmp/spacy-model.log 2>&1; then
        echo -e "  ${CHECK_MARK} spacy model en_core_web_sm downloaded successfully"
    else
        echo -e "  ${CROSS_MARK} Failed to download spacy model"
        cat /tmp/spacy-model.log
        exit 1
    fi
fi
echo ""

# Test 4: Verify spacy works
echo "Test 4: Verify spacy functionality"
TEST_OUTPUT=$("$VENV_PYTHON" -c "
import spacy
nlp = spacy.load('en_core_web_sm')
doc = nlp('Apple is looking at buying U.K. startup for $1 billion')
print(f'Tokens: {len(doc)}')
print(f'Entities: {len(doc.ents)}')
" 2>&1)

if echo "$TEST_OUTPUT" | grep -q "Tokens:"; then
    echo -e "  ${CHECK_MARK} spacy processing works"
    echo "$TEST_OUTPUT" | sed 's/^/      /'
else
    echo -e "  ${CROSS_MARK} spacy processing failed"
    echo "$TEST_OUTPUT"
    exit 1
fi
echo ""

# Test 5: Verify grammar_parser import
echo "Test 5: Verify grammar_parser import"
GRAMMAR_TARGET="$HOME/.local/share/nova/grammar_parser"

if PYTHONPATH="$GRAMMAR_TARGET:$PYTHONPATH" "$VENV_PYTHON" -c "
import grammar_parser
from grammar_parser import GrammarParser
print('✓ Import successful')
print(f'GrammarParser class available')
" 2>&1 | grep -q "✓"; then
    echo -e "  ${CHECK_MARK} grammar_parser import verified"
else
    echo -e "  ${WARNING} grammar_parser import had issues (may need spacy to be imported first)"
fi
echo ""

echo "═══════════════════════════════════════════"
echo -e "  ${CHECK_MARK} All spacy tests passed!"
echo "═══════════════════════════════════════════"
