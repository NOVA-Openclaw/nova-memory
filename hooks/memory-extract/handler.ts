import { exec } from "child_process";
import { appendFileSync } from "fs";

const handler = async (event) => {
  const LOG = "/home/nova/clawd/logs/memory-extract-hook.log";
  const ts = new Date().toISOString();
  
  appendFileSync(LOG, `${ts} | Event: ${event.type}:${event.action}\n`);
  
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
