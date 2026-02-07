# NOVA's Clawdbot/OpenClaw Patches

Local modifications stored here. Reapply after OpenClaw updates until merged upstream.

## Active Patches

### 1. Message Hooks (message:received / message:sent)
- **PR:** [#6797](https://github.com/openclaw/openclaw/pull/6797)
- **Status:** Open (pending review)
- **Files:** `message-hooks.js`, `internal-hooks.js`, `hooks.js`, `dispatch.js`, `reply-dispatcher.js`
- **Docs:** `README.md`
- **Purpose:** Hook events for message processing (enables memory extraction pipeline)

### 2. Subagent Environment Variables
- **Issue:** [#11172](https://github.com/openclaw/openclaw/issues/11172)  
- **Status:** ✅ Implemented locally, PR pending
- **Patch:** `subagent-env-vars.patch`
- **Docs:** `subagent-env-vars-README.md`
- **Purpose:** Set `OPENCLAW_AGENT_ID`, `CLAWDBOT_AGENT_ID`, `OPENCLAW_SESSION_KEY` when spawning subagents
- **Modified files:**
  - `dist/agents/bash-tools.exec.js`
  - `dist/agents/bash-tools.shared.js`

## Extensions (separate repos, not patches)

### agent-chat-channel Plugin
- **Source:** `~/clawd/clawdbot-plugins/agent-chat-channel/`
- **Repo:** https://github.com/NOVA-Openclaw/nova-scripts
- **Installed to:** `~/.clawdbot/extensions/agent_chat/`
- **Purpose:** Inter-agent messaging via PostgreSQL NOTIFY

## Install Script

```bash
#!/bin/bash
# install-patches.sh - Apply NOVA's patches to Clawdbot

CLAWDBOT_DIR="${HOME}/.npm-global/lib/node_modules/clawdbot/dist"
PATCH_DIR="$(dirname "$0")"

echo "Applying NOVA patches to Clawdbot..."

# 1. Message hooks
echo "1. Message hooks..."
cp "$PATCH_DIR/message-hooks.js" "$CLAWDBOT_DIR/hooks/"
cp "$PATCH_DIR/internal-hooks.js" "$CLAWDBOT_DIR/hooks/"
cp "$PATCH_DIR/hooks.js" "$CLAWDBOT_DIR/hooks/"
cp "$PATCH_DIR/dispatch.js" "$CLAWDBOT_DIR/auto-reply/"
cp "$PATCH_DIR/reply-dispatcher.js" "$CLAWDBOT_DIR/auto-reply/reply/"

# 2. Subagent env vars
echo "2. Subagent env vars..."
cd "$CLAWDBOT_DIR/.." && patch -p1 < "$PATCH_DIR/subagent-env-vars.patch"

echo "Done! Restart gateway: clawdbot gateway restart"
```

## Update Procedure

After `npm update -g clawdbot` or system updates:

1. Check if patches still needed:
   ```bash
   gh pr view 6797 --repo openclaw/openclaw --json state
   gh issue view 11172 --repo openclaw/openclaw --json state
   ```

2. If not merged, reapply:
   ```bash
   cd ~/clawd/nova-memory/clawdbot-patches
   bash install-patches.sh
   clawdbot gateway restart
   ```

3. Test:
   ```bash
   # Verify env vars work
   sessions_spawn a test subagent that runs: env | grep OPENCLAW
   ```
