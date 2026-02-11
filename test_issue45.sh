#!/bin/bash
# Integration test for Issue #45: Anaphora Resolution

set -e

cd "$(dirname "$0")"

echo "=========================================="
echo "Testing Issue #45: Anaphora Resolution"
echo "=========================================="
echo

# Activate venv
source grammar_parser/venv/bin/activate

# Run anaphora-specific tests
echo "Running anaphora resolution tests..."
python tests/test_anaphora.py

echo
echo "=========================================="
echo "Testing with real examples..."
echo "=========================================="
echo

# Create a quick integration test
python3 << 'EOF'
import sys
sys.path.insert(0, "grammar_parser")

from grammar_parser import GrammarParser

parser = GrammarParser()

test_cases = [
    ("I met Sarah yesterday. She works at Google.", "Sarah", "Google"),
    ("John is my friend. He lives in Austin.", "John", "Austin"),
    ("Tom met Lisa. She invited him to dinner.", "Lisa", "Tom"),
]

print("Testing real-world examples:")
print()

all_passed = True

for text, expected_subject, expected_object in test_cases:
    print(f"Input: {text}")
    relations = parser.parse_multi_sentence(text)
    
    # Find relations with expected object
    matching = [r for r in relations if expected_object in (r.object or "")]
    
    if matching:
        rel = matching[0]
        if rel.subject == expected_subject:
            print(f"✓ Correctly resolved: {rel.subject} -> {rel.object}")
        else:
            print(f"✗ Expected subject '{expected_subject}', got '{rel.subject}'")
            all_passed = False
    else:
        print(f"✗ No relation found with object '{expected_object}'")
        all_passed = False
    print()

if all_passed:
    print("========================================")
    print("All integration tests PASSED!")
    print("========================================")
    sys.exit(0)
else:
    print("========================================")
    print("Some integration tests FAILED!")
    print("========================================")
    sys.exit(1)
EOF

echo
echo "=========================================="
echo "Issue #45 Tests Complete!"
echo "=========================================="
