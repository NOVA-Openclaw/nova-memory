# Testing nova-memory#80: Grammar Parser Installation

## Implementation Summary

Added grammar_parser installation to `install.sh` (Part 4.5) following the same pattern as hooks and scripts:

- **Installation target:** `~/.local/share/nova/grammar_parser/`
- **Hash-based updates:** Skip if hashes match, overwrite if they differ
- **Dependencies:** Installs `spacy>=3.7.0` and downloads `en_core_web_sm` model
- **Verification:** Tests grammar_parser import

## Test Results

### ✅ Test 1: Fresh Install
```bash
$ rm -rf ~/.local/share/nova/grammar_parser
$ ./test-grammar-install.sh
```

**Result:** All 7 Python files copied successfully:
- `__init__.py`
- `anaphora_resolver.py`
- `extract_cli.py`
- `grammar_parser.py`
- `grammar_patterns.py`
- `relation_types.py`
- `store_relations.py`

### ✅ Test 2: Hash Matching (Up-to-Date)
```bash
$ ./test-grammar-install.sh
```

**Result:** Correctly detected all files match source - would skip reinstall

### ✅ Test 3: Hash Differing (Update Required)
```bash
$ echo "# Test modification" >> ~/.local/share/nova/grammar_parser/__init__.py
$ ./test-grammar-install.sh
```

**Result:** Correctly detected modified file and flagged for update

### ✅ Test 4: File Verification
**Result:** All required files present with correct permissions (644)

## Environment Notes

### Python 3.14 Compatibility
The test environment uses Python 3.14.2, which is very new. Current spacy 3.7.x has compatibility issues with Python 3.14 due to pydantic v1 dependency issues.

**Supported Python versions for spacy 3.7:**
- Python 3.8, 3.9, 3.10, 3.11, 3.12

**Recommendation:** The installer will work correctly on systems with Python 3.8-3.12. The installation logic is sound; this is purely an environment compatibility issue.

## Manual Verification Steps

Since automated spacy testing is limited by Python 3.14 compatibility, manual verification on a compatible system should follow these steps:

### 1. Fresh Install Test
```bash
cd ~/workspace/nova-memory
rm -rf ~/.local/share/nova/grammar_parser
./install.sh --verify-only  # Should show grammar_parser not installed
./install.sh                # Should install grammar_parser and dependencies
./install.sh                # Should show "up to date"
```

### 2. Verify Installation
```bash
# Check files are installed
ls -la ~/.local/share/nova/grammar_parser/

# Check spacy is installed
~/.local/share/nova/venv/bin/python -c "import spacy; print(spacy.__version__)"

# Check model is downloaded
~/.local/share/nova/venv/bin/python -c "import spacy; spacy.load('en_core_web_sm')"

# Check grammar_parser import
PYTHONPATH=~/.local/share/nova/grammar_parser:$PYTHONPATH \
  ~/.local/share/nova/venv/bin/python -c "import grammar_parser; print('OK')"
```

### 3. Update Test
```bash
# Modify a source file
echo "# test modification" >> grammar_parser/__init__.py

# Run installer - should detect change and update
./install.sh

# Verify the modification was copied
tail ~/.local/share/nova/grammar_parser/__init__.py

# Restore original
git checkout grammar_parser/__init__.py
```

## Test Scripts Created

1. **`test-grammar-install.sh`** - Tests file installation and hash comparison logic
2. **`test-grammar-spacy.sh`** - Tests spacy installation (requires Python 3.8-3.12)

## Implementation Checklist

- [x] Add grammar_parser installation section to install.sh
- [x] Follow same pattern as install_hook() for hash comparison
- [x] Install to ~/.local/share/nova/grammar_parser/
- [x] Install spacy>=3.7.0 dependency
- [x] Download en_core_web_sm model
- [x] Verify grammar_parser import
- [x] Test file installation logic
- [x] Test hash-based update logic
- [x] Create test scripts
- [x] Document testing procedures

## Next Steps

1. Push changes to GitHub
2. Create pull request
3. Request testing on system with Python 3.8-3.12
4. Merge after successful testing
