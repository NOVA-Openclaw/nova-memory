# Changelog

## Unreleased

### Changed — Provider Config Keys (#96)

- **agent-install.sh**: Reads OpenAI API key from `models.providers.openai.apiKey` in `~/.openclaw/openclaw.json` instead of environment variables. `verify_config()` updated to check provider config for both OpenAI and Anthropic keys.
- **shell-install.sh** (NEW): Interactive setup prompting for both OpenAI and Anthropic keys, saving to provider config, then delegating to `agent-install.sh`.
- **hooks/semantic-recall/handler.ts**: Added `getOpenAIKeyFromConfig()` — reads key from config JSON and passes it via `OPENAI_API_KEY` env to child processes.
- **scripts/proactive-recall.py**: Added `get_openai_api_key()` reading from config JSON.
- **Shell scripts** (`extract-memories.sh`, `memory-catchup.sh`, `embed-delegation-facts.sh`, `test-delegation-memory.sh`): All now use a `get_provider_key` helper to read API keys from provider config instead of expecting environment variables.
- Installer flow is now split: `shell-install.sh` for humans, `agent-install.sh` for agents.
- Environment variables `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` are no longer required to be set before running scripts.
