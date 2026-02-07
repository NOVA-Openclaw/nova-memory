# Subagent Environment Variable Injection - Implementation Report

**Related Issue:** https://github.com/openclaw/openclaw/issues/11172

## Problem Statement
When subagents are spawned via `sessions_spawn`, they don't have environment variables identifying which agent they are. External tools (git hooks, scripts) cannot identify the running agent.

## Goal
Inject these environment variables when a subagent session spawns:
- `OPENCLAW_AGENT_ID` = the agentId (e.g., "git-agent")
- `CLAWDBOT_AGENT_ID` = same (for backward compatibility)
- `OPENCLAW_SESSION_KEY` = the session key

## Investigation Findings

### Architecture Overview
1. **Subagent Spawning**: `sessions-spawn-tool.js` handles the `sessions_spawn` tool
2. **Execution Flow**: 
   - Subagents run via `agent-runner-execution.js`
   - Can use either embedded API (`pi-embedded.js`) or CLI backend (`cli-runner.js`)
   - Most commonly use embedded API (direct Anthropic API calls)
3. **Process Spawning**: When agents use `exec` or `process` tools:
   - Environment is built in `bash-tools.exec.js`
   - Sandbox environments use `bash-tools.shared.js`

### Key Files Modified

#### 1. `/home/nova/.npm-global/lib/node_modules/clawdbot/dist/agents/bash-tools.exec.js`
**Location:** Lines ~646-658 (environment building section)

**Changes:**
- Added code to extract `agentId` from the `defaults` object (already available)
- Created `agentEnvVars` object with the three environment variables
- Injected `agentEnvVars` into both non-sandbox and sandbox execution paths
- Ensured proper merge order: `process.env` ← `agentEnvVars` ← `params.env`

**Code Added:**
```javascript
// Inject agent environment variables for subagent sessions
const agentEnvVars = {};
if (agentId) {
    agentEnvVars.OPENCLAW_AGENT_ID = agentId;
    agentEnvVars.CLAWDBOT_AGENT_ID = agentId;
}
if (defaults?.sessionKey) {
    agentEnvVars.OPENCLAW_SESSION_KEY = defaults.sessionKey;
}
```

#### 2. `/home/nova/.npm-global/lib/node_modules/clawdbot/dist/agents/bash-tools.shared.js`
**Location:** `buildSandboxEnv()` function

**Changes:**
- Modified `buildSandboxEnv()` to accept `agentEnvVars` parameter
- Added loop to merge `agentEnvVars` into sandbox environment
- Ensures proper precedence: sandbox env ← agent env ← params env

**Code Added:**
```javascript
for (const [key, value] of Object.entries(params.agentEnvVars ?? {})) {
    env[key] = value;
}
```

## Implementation Details

### Environment Variable Precedence
The merge order ensures that:
1. Base environment from `process.env`
2. Agent-specific variables (`OPENCLAW_AGENT_ID`, etc.)
3. User-provided `params.env` (can override if needed)

This allows users to override agent env vars if needed, while ensuring they're set by default.

### Where Variables Are Available
The environment variables will be available in:
- ✅ All `exec` tool invocations (both sync and background)
- ✅ All `process` tool operations
- ✅ Sandboxed execution contexts
- ✅ Node-based execution (when `host=node`)
- ✅ Gateway-based execution
- ✅ PTY (pseudo-terminal) sessions

### Context Availability
- `agentId`: Extracted from `defaults.sessionKey` via `parseAgentSessionKey()`
- `sessionKey`: Available directly in `defaults.sessionKey`
- Both are passed to the exec tool when created (already in place)

## Files Created

### 1. `subagent-env-vars.patch`
Unified diff patch file showing the exact changes made.

### 2. `test-agent-env.sh`
Test script that can be run by a subagent to verify environment variables are set:
```bash
./test-agent-env.sh
```

### 3. Backups Created
- `bash-tools.exec.js.backup`
- `bash-tools.shared.js.backup`

## Testing Instructions

### Manual Test
1. **Restart the Clawdbot Gateway:**
   ```bash
   clawdbot gateway restart
   ```

2. **Spawn a subagent and run the test script:**
   ```javascript
   // In your main agent session
   sessions_spawn({
     task: "Run the command: /home/nova/clawd-claude-code/test-agent-env.sh and report what you see"
   })
   ```

3. **Expected Output:**
   ```
   === Agent Environment Variables ===
   OPENCLAW_AGENT_ID: claude-code
   CLAWDBOT_AGENT_ID: claude-code
   OPENCLAW_SESSION_KEY: agent:claude-code:subagent:<uuid>
   ====================================
   ✓ Success: Agent environment variables are set
   ```

### Git Hook Test
Create a test git hook to verify the variables are available:
```bash
#!/bin/bash
# .git/hooks/pre-commit

echo "Git hook running in agent: $OPENCLAW_AGENT_ID"

if [ "$OPENCLAW_AGENT_ID" = "git-agent" ]; then
    echo "✓ Detected git-agent, proceeding with special validation..."
fi
```

## Edge Cases Handled

1. **No agentId available**: Variables simply won't be set (graceful degradation)
2. **User overrides in params.env**: User's values take precedence
3. **Sandbox vs non-sandbox**: Both paths inject variables correctly
4. **Node execution**: Variables are included in node RPC calls
5. **Main agent sessions**: Variables are also available (sessionKey will be main session key)

## Limitations & Future Work

1. **CLI Backend Sessions**: 
   - If using `cli-runner.js` (claude-cli backend), the environment is built differently
   - Current implementation covers `bash-tools.exec.js` which is used by most agents
   - CLI backend could be enhanced separately if needed

2. **Non-exec Tools**:
   - Some tools (browser, canvas) don't spawn processes, so env vars aren't relevant
   - Only process-spawning tools benefit from these variables

3. **Persistence**:
   - Changes are in compiled `dist/` files
   - Will be overwritten on `npm install` or `clawdbot` updates
   - Should be contributed upstream to the Clawdbot/OpenClaw project

## Recommended Next Steps

1. **Test thoroughly** with various subagent scenarios
2. **Submit PR** to openclaw/openclaw repository with these changes
3. **Document** in Clawdbot docs for tool authors who need agent context
4. **Consider** adding `OPENCLAW_RUN_ID` for run-level tracking

## Rollback Instructions

If issues arise, restore from backups:
```bash
cp /home/nova/.npm-global/lib/node_modules/clawdbot/dist/agents/bash-tools.exec.js.backup \
   /home/nova/.npm-global/lib/node_modules/clawdbot/dist/agents/bash-tools.exec.js

cp /home/nova/.npm-global/lib/node_modules/clawdbot/dist/agents/bash-tools.shared.js.backup \
   /home/nova/.npm-global/lib/node_modules/clawdbot/dist/agents/bash-tools.shared.js

clawdbot gateway restart
```

## Summary

✅ **Implementation Complete**

The environment variables are now injected into all subagent exec/process sessions. External tools like git hooks can now identify which agent is running by checking `OPENCLAW_AGENT_ID` or `CLAWDBOT_AGENT_ID`.

**Status:** Ready for testing after gateway restart.
