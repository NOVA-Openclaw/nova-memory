# Changelog

## Unreleased

### Added
- **Library domain schema** — New tables for storing written works (research papers, books, novels, poems, essays, articles, etc.) with normalized authors, flexible tagging, and work-to-work relationships. Database constraints enforce complete ingestion (summary, insights, and all core metadata are required). See `docs/library-schema.md` and `patches/add-library-schema.sql`.
- **Library semantic embedding** — Added `library` source type to `embed-full-database.py`. Embeds concise summaries (not full text) for high-density semantic search. Full records are fetched on recall hit.
- **embed-full-database.py** — Added full database embedding script covering all source types (entities, facts, tasks, projects, agents, lessons, events, positions, media, vocabulary, library works).

### Fixed
- **Installer now handles schema migrations automatically** — when re-running `agent-install.sh` on an existing installation, missing columns are detected and added automatically. Users no longer need to run manual `ALTER TABLE` commands when the schema evolves. (#127)
- Remove old pg-env.sh/pg_env imports from migrated scripts (#117)

### Changed
- **Migrated 11 scripts to `env-loader` pattern** — replaced direct `source lib/pg-env.sh` with `source ~/.openclaw/lib/env-loader.sh` across all Bash scripts; env-loader provides a unified, repo-agnostic interface for loading PG credentials ([#115](https://github.com/nova-openclaw/nova-memory/issues/115))
- **Fixed POSTGRES→PG env var naming in `test-entity-resolution.js`** — replaced legacy `POSTGRES_HOST`/`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` references with standard `PGHOST`/`PGUSER`/`PGPASSWORD`/`PGDATABASE` ([#115](https://github.com/nova-openclaw/nova-memory/issues/115))

### Changed
- **`shell-install.sh` now execs `agent-install.sh` after config setup** — no need to run both scripts separately; `shell-install.sh` handles the full install pipeline. Also fixed lib install ordering in `agent-install.sh` so loader functions are available before scripts that need them ([#104](https://github.com/nova-openclaw/nova-memory/issues/104))

### Added
- **Install PG loader functions to `~/.openclaw/lib/`** — `agent-install.sh` now copies `pg-env.sh`, `pg_env.py`, and `pg-env.ts` to `~/.openclaw/lib/` with SHA-256 hash-based update detection; all 12 scripts updated to import from the installed location instead of repo-relative paths ([#102](https://github.com/nova-openclaw/nova-memory/issues/102))

### Changed
- **All scripts migrated to centralized DB config** — 12 scripts (6 Bash, 4 Python, 2 shell helpers) now use shared `lib/pg-env.sh` / `lib/pg_env.py` loaders instead of hardcoded connection logic ([#95](https://github.com/nova-openclaw/nova-memory/issues/95))
  - Removed per-script `get_db_name()` functions and manual `DB_USER`/`DB_NAME`/`DB_HOST` variables
  - All connections now honor the centralized resolution order (ENV → `postgres.json` → defaults)
  - Added migration test suite: `tests/TEST-CASES-ISSUE-95.md` and `tests/verify-migration-95.sh`

### Added
- **Centralized database config** (`~/.openclaw/postgres.json`) with ENV variable fallback ([#94](https://github.com/nova-openclaw/nova-memory/issues/94))
  - Shared loader functions: `lib/pg-env.sh` (Bash), `lib/pg_env.py` (Python), `lib/pg-env.ts` (TypeScript)
  - `shell-install.sh` now writes `postgres.json` after database creation
  - `agent-install.sh` reads `postgres.json` and fails with guidance if missing
  - Resolution order: ENV vars → config file → built-in defaults
