/**
 * memory-extract: Extract and store memories from conversation turns.
 *
 * On message:sent (assistant response):
 * 1. Read recent transcript lines
 * 2. Heuristic check — skip heartbeats, short messages, routine responses
 * 3. If extractable content detected, call Claude Haiku to parse structured entries
 * 4. Shell out to memory-db CLI to store facts, events, lessons
 *
 * Never blocks message delivery. All errors are swallowed and logged.
 */

import { execSync, execFileSync } from "child_process";
import { readFileSync, existsSync, readdirSync, statSync, appendFileSync, writeFileSync } from "fs";
import { join } from "path";

const HOME = process.env.HOME || "/home/openclaw";
const WORKSPACE = process.env.OPENCLAW_WORKSPACE || join(HOME, ".openclaw/workspace");
const MEMORY_DB = join(WORKSPACE, "tools/memory-db");
const SESSIONS_DIR = join(HOME, ".openclaw/agents/main/sessions");
const LOG_FILE = join(WORKSPACE, "db/memory-extract.log");
const STATE_FILE = join(WORKSPACE, "db/memory-extract-state.json");
const COOLDOWN_MS = 5 * 60 * 1000; // 5 minutes between extractions
const MIN_MESSAGE_LENGTH = 80;

// Heuristic keywords that suggest extractable content
const EXTRACT_SIGNALS = [
  // People / entities
  /\b(?:name is|called|known as|nickname)\b/i,
  /\b(?:lives in|moved to|works at|job is|employed)\b/i,
  /\b(?:birthday|born on|anniversary)\b/i,
  /\b(?:allergic|allergy|intolerant)\b/i,
  /\b(?:prefer|favorite|loves|hates|dislikes)\b/i,
  // Events
  /\b(?:happened|occurred|took place|event|trip|visited|traveled)\b/i,
  /\b(?:meeting|appointment|scheduled|booked)\b/i,
  /\b(?:bought|purchased|ordered|received|shipped)\b/i,
  // Decisions
  /\b(?:decided|decision|going to|plan to|will switch|chose|picked)\b/i,
  /\b(?:signed up|subscribed|cancelled|enrolled)\b/i,
  // Lessons / insights
  /\b(?:learned|lesson|realize|figured out|turns out|note to self)\b/i,
  /\b(?:important to remember|don't forget|keep in mind)\b/i,
  // Projects / goals
  /\b(?:project|goal|milestone|deadline|launch|shipped|deployed)\b/i,
];

const SKIP_PATTERNS = [
  /HEARTBEAT/i,
  /heartbeat poll/i,
  /DASHBOARD UPDATE/i,
  /^System: \[/,
  /^HEARTBEAT_OK$/,
  /^\//,  // commands
];

interface ExtractState {
  lastExtractTime: Record<string, number>; // sessionId -> timestamp
}

function log(msg: string) {
  try {
    const ts = new Date().toISOString();
    appendFileSync(LOG_FILE, `${ts} ${msg}\n`);
  } catch {}
}

function loadState(): ExtractState {
  try {
    if (existsSync(STATE_FILE)) {
      return JSON.parse(readFileSync(STATE_FILE, "utf-8"));
    }
  } catch {}
  return { lastExtractTime: {} };
}

function saveState(state: ExtractState) {
  try {
    writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
  } catch {}
}

function getRecentTranscript(sessionId?: string, lineCount = 20): string[] {
  try {
    let sessionFile: string | null = null;

    if (sessionId) {
      const candidate = join(SESSIONS_DIR, `${sessionId}.jsonl`);
      if (existsSync(candidate)) sessionFile = candidate;
    }

    if (!sessionFile) {
      const files = readdirSync(SESSIONS_DIR)
        .filter(f => f.endsWith(".jsonl"))
        .map(f => ({ name: f, mtime: statSync(join(SESSIONS_DIR, f)).mtimeMs }))
        .sort((a, b) => b.mtime - a.mtime);
      if (files.length > 0) sessionFile = join(SESSIONS_DIR, files[0].name);
    }

    if (!sessionFile) return [];

    let content: string;
    try {
      content = execSync(`tail -n ${lineCount} ${JSON.stringify(sessionFile)}`, { encoding: "utf-8" }).trim();
    } catch {
      content = readFileSync(sessionFile, "utf-8").trim();
    }
    const lines = content.split("\n");
    const messages: string[] = [];

    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        const msg = entry.message || entry;
        const role = msg.role;
        const rawContent = msg.content;
        if (!role || !rawContent) continue;

        const text = typeof rawContent === "string"
          ? rawContent
          : Array.isArray(rawContent)
            ? rawContent.filter((b: any) => b.type === "text").map((b: any) => b.text).join(" ")
            : null;

        if (text) messages.push(`${role}: ${text}`);
      } catch { continue; }
    }

    return messages;
  } catch {
    return [];
  }
}

function shouldSkip(messages: string[]): boolean {
  if (messages.length < 2) return true;

  const lastAssistant = [...messages].reverse().find(m => m.startsWith("assistant:"));
  const lastUser = [...messages].reverse().find(m => m.startsWith("user:"));

  if (!lastAssistant || !lastUser) return true;

  // Skip short responses
  if (lastAssistant.length < MIN_MESSAGE_LENGTH && lastUser.length < MIN_MESSAGE_LENGTH) return true;

  // Skip heartbeats and commands
  for (const pattern of SKIP_PATTERNS) {
    if (pattern.test(lastUser) || pattern.test(lastAssistant)) return true;
  }

  return false;
}

function hasExtractableContent(messages: string[]): boolean {
  const combined = messages.slice(-6).join("\n");
  return EXTRACT_SIGNALS.some(pattern => pattern.test(combined));
}

interface MemoryEntry {
  type: "fact" | "event" | "lesson" | "decision";
  entity?: string;
  key?: string;
  value?: string;
  title?: string;
  description?: string;
  lesson?: string;
  context?: string;
}

async function extractWithLLM(messages: string[]): Promise<MemoryEntry[]> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    log("no ANTHROPIC_API_KEY");
    return [];
  }

  const transcript = messages.slice(-8).join("\n");

  const systemPrompt = `You extract structured memories from conversations. Output ONLY a JSON array of memory entries. Each entry has a "type" field:

- fact: { "type": "fact", "entity": "PersonName", "key": "fact_key", "value": "fact value" }
  For facts about people, places, things. Use snake_case keys like "lives_in", "birthday", "job_title", "favorite_food"
- event: { "type": "event", "title": "Short title", "description": "What happened" }
  For things that happened or were scheduled
- lesson: { "type": "lesson", "lesson": "The insight", "context": "Where it came from" }
  For insights, lessons learned, things to remember
- decision: { "type": "decision", "title": "What was decided", "description": "Details and rationale" }

Rules:
- Only extract NEW information explicitly stated in the conversation
- Skip greetings, meta-discussion, status updates, and routine exchanges
- Skip anything the assistant already knew (don't re-extract existing knowledge)
- If nothing is worth extracting, return an empty array []
- Entity names should be proper names (e.g., "Eiwe" not "the user")
- Be conservative — only extract clear, concrete facts`;

  try {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-20250414",
        max_tokens: 1024,
        system: systemPrompt,
        messages: [{ role: "user", content: `Extract memories from this conversation:\n\n${transcript}` }],
      }),
    });

    if (!resp.ok) {
      log(`LLM error: ${resp.status}`);
      return [];
    }

    const data = await resp.json();
    const text = data.content?.[0]?.text || "[]";

    // Parse JSON from response (handle markdown code blocks)
    const jsonMatch = text.match(/\[[\s\S]*\]/);
    if (!jsonMatch) return [];

    const entries: MemoryEntry[] = JSON.parse(jsonMatch[0]);
    return Array.isArray(entries) ? entries : [];
  } catch (err) {
    log(`LLM parse error: ${err}`);
    return [];
  }
}

function storeMemory(entry: MemoryEntry) {
  try {
    const execOpts = { timeout: 5000, stdio: "pipe" as const };

    switch (entry.type) {
      case "fact":
        if (entry.entity && entry.key && entry.value) {
          execFileSync(MEMORY_DB, ["add-fact", entry.entity, entry.key, entry.value], execOpts);
          log(`stored fact: ${entry.entity}.${entry.key} = ${entry.value}`);
        }
        break;

      case "event":
        if (entry.title) {
          const today = new Date().toISOString().split("T")[0];
          const args = ["log-event", today, entry.title];
          if (entry.description) args.push(entry.description);
          execFileSync(MEMORY_DB, args, execOpts);
          log(`stored event: ${entry.title}`);
        }
        break;

      case "lesson":
        if (entry.lesson) {
          const args = ["add-lesson", entry.lesson];
          if (entry.context) args.push(entry.context);
          execFileSync(MEMORY_DB, args, execOpts);
          log(`stored lesson: ${entry.lesson.slice(0, 60)}`);
        }
        break;

      case "decision":
        if (entry.title) {
          const today = new Date().toISOString().split("T")[0];
          const args = ["log-event", today, `Decision: ${entry.title}`];
          if (entry.description) args.push(entry.description);
          execFileSync(MEMORY_DB, args, execOpts);
          log(`stored decision: ${entry.title}`);
        }
        break;
    }
  } catch (err) {
    log(`store error (${entry.type}): ${err}`);
  }
}

const handler = async (event: any) => {
  try {
    // Fire on message:sent (after assistant responds)
    if (event.type !== "message" || event.action !== "sent") return;

    const ctx = event.context ?? {};
    const sessionKey = ctx.sessionKey || event.sessionKey || "";

    // Skip isolated/spawn sessions and subagents
    if (sessionKey.includes("isolated") || sessionKey.includes("spawn") || sessionKey.includes("subagent")) return;

    const sessionId = ctx.sessionId as string | undefined;

    // Cooldown check
    const state = loadState();
    const sid = sessionId || sessionKey || "default";
    const now = Date.now();
    const lastExtract = state.lastExtractTime[sid] || 0;
    if (now - lastExtract < COOLDOWN_MS) return;

    // Get recent transcript
    const messages = getRecentTranscript(sessionId);
    if (shouldSkip(messages)) return;

    // Heuristic gate
    if (!hasExtractableContent(messages)) {
      return;
    }

    log(`extracting from session ${sid}`);

    // Update cooldown before async work
    state.lastExtractTime[sid] = now;
    // Prune old entries (older than 1 day)
    for (const key of Object.keys(state.lastExtractTime)) {
      if (now - state.lastExtractTime[key] > 86400000) delete state.lastExtractTime[key];
    }
    saveState(state);

    // Call LLM for structured extraction
    const entries = await extractWithLLM(messages);
    if (entries.length === 0) {
      log("no entries extracted");
      return;
    }

    log(`extracted ${entries.length} entries`);

    // Store each entry
    for (const entry of entries) {
      storeMemory(entry);
    }

    log(`extraction complete: ${entries.length} entries stored`);
  } catch (err) {
    log(`handler error: ${err}`);
    // Never throw — don't block message delivery
  }
};

export default handler;
