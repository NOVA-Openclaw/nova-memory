import { exec } from "child_process";
import { appendFileSync } from "fs";

const LOG = "/home/nova/clawd/logs/message-hooks.log";
const processedIds = new Set<string>();

function log(msg: string) {
  try {
    appendFileSync(LOG, `${new Date().toISOString()} | ${msg}\n`);
  } catch (e) {}
}

const handler = async (event: any) => {
  // Deduplicate by message ID
  const msgId = event.context?.messageId;
  if (event.action === "received" && msgId) {
    if (processedIds.has(msgId)) {
      return; // Skip duplicate
    }
    processedIds.add(msgId);
    // Cleanup old IDs after 5 minutes
    setTimeout(() => processedIds.delete(msgId), 300000);
  }
  
  log(`${event.type}:${event.action}`);
  
  if (event.type === "message" && event.action === "received") {
    const rawBody = event.context?.rawBody;
    if (rawBody && rawBody.length > 5) {
      log(`Extracting: ${rawBody.substring(0, 60)}...`);
      const escaped = rawBody.replace(/'/g, "'\\''");
      exec(`/home/nova/clawd/scripts/process-input.sh '${escaped}' >> /home/nova/clawd/logs/memory-extract.log 2>&1`);
    }
  }
};

export default handler;
