# Clawdbot Patches for Message Hooks

These patches add `message:received` and `message:sent` hook events to Clawdbot.

## Status
- **PR:** [#6797](https://github.com/openclaw/openclaw/pull/6797)
- **Status:** Open (pending review)

## Files

| File | Purpose |
|------|---------|
| `message-hooks.js` | Defines `triggerMessageReceived` and `triggerMessageSent` functions |
| `internal-hooks.js` | Hook infrastructure (registerInternalHook, triggerInternalHook) |
| `hooks.js` | Exports message hooks |
| `dispatch.js` | Calls `triggerMessageReceived` before message processing |
| `reply-dispatcher.js` | Calls `triggerMessageSent` after reply delivery |

## Installation

Copy to your Clawdbot install:
```bash
CLAWDBOT_DIR=~/.npm-global/lib/node_modules/clawdbot/dist

cp message-hooks.js $CLAWDBOT_DIR/hooks/
cp internal-hooks.js $CLAWDBOT_DIR/hooks/
cp hooks.js $CLAWDBOT_DIR/hooks/
cp dispatch.js $CLAWDBOT_DIR/auto-reply/
cp reply-dispatcher.js $CLAWDBOT_DIR/auto-reply/reply/

# Restart gateway
clawdbot gateway restart
```

## Usage

Create a hook in `~/your-workspace/hooks/my-hook/`:

**HOOK.md:**
```yaml
---
name: my-hook
description: "Handle message events"
metadata: {"clawdbot":{"emoji":"🔔","events":["message:received","message:sent"]}}
---
```

**handler.ts:**
```typescript
const handler = async (event: any) => {
  if (event.type === "message" && event.action === "received") {
    console.log("Received:", event.context.rawBody);
  }
  if (event.type === "message" && event.action === "sent") {
    console.log("Sent:", event.context.text);
  }
};
export default handler;
```
