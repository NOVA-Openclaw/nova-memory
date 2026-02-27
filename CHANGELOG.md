# Changelog

## Unreleased

### Added
- **Declarative schema management via `pg-schema-diff`** (#128) — `agent-install.sh` now uses [Stripe's `pg-schema-diff`](https://github.com/stripe/pg-schema-diff) to apply schema changes declaratively.
  - `pg-schema-diff` is now a **required prerequisite** (install via `brew install pg-schema-diff` or `go install github.com/stripe/pg-schema-diff/cmd/pg-schema-diff@latest`).
  - `schema.sql` has been moved to `schema/schema.sql` (pg-schema-diff expects `--to-dir`).
  - New **`pre-migrations/` directory** for numbered SQL scripts that run *before* the schema diff — required for renames, data migrations, and any operation `pg-schema-diff` can't handle declaratively (it treats renames as drop+add, flagging them as hazards).
  - **Hazard-safe apply:** The installer runs `pg-schema-diff plan` first. If any hazardous statements are detected (drops, renames, etc.) the entire schema apply is **skipped** (all-or-nothing) and a warning is printed. The installer continues with hooks and other steps.
  - **Plan validation fallback:** The installer first tries plan validation (requires `CREATEDB`); if that fails it retries with `--disable-plan-validation` and logs a warning.
  - `migrate_schema()` and all hand-written `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` blocks have been **removed** from `agent-install.sh`.
- **`agent_turn_context` table and per-turn injection hook** (#143) — New table stores short critical-context records (≤500 chars each) injected before every agent response. `get_agent_turn_context(agent_name)` aggregates context in priority order (UNIVERSAL → GLOBAL → DOMAIN → AGENT) up to a 2000-character budget with truncation warning. The new `agent-turn-context` hook fires on `message:received`, queries the table, and injects results into the agent's turn context with a 5-minute cache TTL per agent. Migration: `migrations/065_agent_turn_context.sql`.
- **Library domain schema** — New tables for storing written works (research papers, books, novels, poems, essays, articles, etc.) with normalized authors, flexible tagging, and work-to-work relationships. Database constraints enforce complete ingestion (summary, insights, and all core metadata are required). See `docs/library-schema.md` and `patches/add-library-schema.sql`.
- **Library semantic embedding** — Added `library` source type to `embed-full-database.py`. Embeds concise summaries (not full text) for high-density semantic search. Full records are fetched on recall hit.
- **embed-full-database.py** — Added full database embedding script covering all source types (entities, facts, tasks, projects, agents, lessons, events, positions, media, vocabulary, library works).

### Fixed
- **Installer handles schema migrations automatically** (#127) — superseded by #128. Schema evolution is now managed declaratively via `pg-schema-diff` rather than hand-written `ALTER TABLE` blocks.
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
