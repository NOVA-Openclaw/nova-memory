#!/bin/bash
# Install git hooks for nova-memory development
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "Installing git hooks..."

# Create hooks directory if needed
mkdir -p "$REPO_ROOT/.git/hooks"

# Symlink pre-commit hook
ln -sf "../../hooks/git/pre-commit" "$REPO_ROOT/.git/hooks/pre-commit"

echo "✅ Git hooks installed"
echo "   pre-commit: Auto-updates schema.sql when database schema changes"
