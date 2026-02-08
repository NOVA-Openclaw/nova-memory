import { exec } from "child_process";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "fs";

const ACTIVITY_STATE = "/home/nova/clawd/logs/activity-state.json";
const ACTIVITY_LOG = "/home/nova/clawd/logs/session-activity.jsonl";

interface ActivityState {
  activeMinutesToday: number;
  lastActiveAt: number | null;
  todayDate: string | null;
  userMessages: number;
  heartbeats: number;
}

function updateActivityState(isUserMessage: boolean) {
  let state: ActivityState = {
    activeMinutesToday: 0,
    lastActiveAt: null,
    todayDate: null,
    userMessages: 0,
    heartbeats: 0
  };
  
  try {
    if (existsSync(ACTIVITY_STATE)) {
      state = JSON.parse(readFileSync(ACTIVITY_STATE, 'utf8'));
    }
  } catch (e) {}
  
  const today = new Date().toISOString().split('T')[0];
  const now = Date.now();
  
  // Reset if new day
  if (state.todayDate !== today) {
    state = { activeMinutesToday: 0, lastActiveAt: null, todayDate: today, userMessages: 0, heartbeats: 0 };
  }
  
  if (isUserMessage) {
    state.userMessages++;
    if (state.lastActiveAt) {
      const gap = (now - state.lastActiveAt) / 60000;
      if (gap <= 5) state.activeMinutesToday += gap;
    }
    state.lastActiveAt = now;
  } else {
    state.heartbeats++;
  }
  
  writeFileSync(ACTIVITY_STATE, JSON.stringify(state, null, 2));
  appendFileSync(ACTIVITY_LOG, JSON.stringify({ timestamp: new Date().toISOString(), isUserMessage, activeMinutes: state.activeMinutesToday }) + '\n');
}

const handler = async (event) => {
  const LOG = "/home/nova/clawd/logs/memory-extract-hook.log";
  const ts = new Date().toISOString();
  
  appendFileSync(LOG, `${ts} | Event: ${event.type}:${event.action}\n`);
  
  // Track activity for cost/hour calculations
  if (event.type === "message") {
    const ctx = event.context ?? {};
    const rawBody = ctx.rawBody ?? ctx.message ?? "";
    const isHeartbeat = rawBody.includes("HEARTBEAT") || rawBody.includes("DASHBOARD UPDATE") || rawBody.startsWith("System: [");
    updateActivityState(!isHeartbeat);
  }
  
  if (event.type !== "message" || event.action !== "received") return;
  
  const ctx = event.context ?? {};
  const rawBody = ctx.rawBody ?? ctx.message ?? "";
  if (!rawBody || rawBody.trim().length < 10) return;
  
  // Skip commands
  if (rawBody.startsWith("/")) return;
  
  // Get sender info for attribution
  const senderName = ctx.senderName ?? "unknown";
  const senderId = ctx.senderId ?? "";  // Phone number or UUID for unique matching
  const isGroup = ctx.isGroup ?? false;
  
  appendFileSync(LOG, `${ts} | From: ${senderName} (${senderId}) (group: ${isGroup}) | Message: ${rawBody.substring(0, 80)}...\n`);
  
  // Run extraction with attribution env vars (include senderId for unique matching)
  const escaped = rawBody.replace(/'/g, "'\\''");
  const envVars = `SENDER_NAME='${senderName}' SENDER_ID='${senderId}' IS_GROUP='${isGroup}'`;
  
  exec(`${envVars} /home/nova/clawd/scripts/process-input.sh '${escaped}'`, (err) => {
    appendFileSync(LOG, `${ts} | ${err ? 'Error: ' + err.message : 'Extraction complete for ' + senderName}\n`);
  });
};

export default handler;
