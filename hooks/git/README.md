# Git Hooks for nova-memory Development

## Installation

```bash
./hooks/git/install.sh
```

Or manually:
```bash
ln -sf ../../hooks/git/pre-commit .git/hooks/pre-commit
```

## Hooks

### pre-commit
Automatically keeps `schema.sql` in sync with the database:

1. Dumps current schema from PostgreSQL
2. Compares with `schema.sql`
3. If different, updates and stages `schema.sql`

**Requirements:**
- `pg_dump` available in PATH
- Database accessible (uses `$PGUSER` or current user)
- Database name: `${USER}_memory` (e.g., `nova_memory`)

**Skip if needed:**
```bash
git commit --no-verify
```
