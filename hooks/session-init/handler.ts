/**
 * session-init: Inject recent activity context into agent bootstrap.
 *
 * On agent:bootstrap, queries PostgreSQL for:
 * - Events from the last 48 hours
 * - Decisions from the last 7 days
 * - Lessons from the last 7 days
 * Formats and injects as SESSION_CONTEXT.md bootstrap file.
 */

import { execSync } from "child_process";
import { appendFileSync } from "fs";
import { join } from "path";

const HOME = process.env.HOME || "/home/openclaw";
const WORKSPACE = process.env.OPENCLAW_WORKSPACE || join(HOME, ".openclaw/workspace");
const LOG_FILE = join(WORKSPACE, "db/session-init.log");
const DB_NAME = "auri_memory";

function log(msg: string) {
  try {
    appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`);
  } catch {}
}

function pgAvailable(): boolean {
  try {
    execSync("pg_isready -q", { timeout: 2000 });
    return true;
  } catch {
    return false;
  }
}

function pgQuery(sql: string): any[] {
  try {
    const result = execSync(
      `psql -d ${DB_NAME} -h /var/run/postgresql -t -A -F '\t' -c ${JSON.stringify(sql)}`,
      { encoding: "utf-8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"] }
    ).trim();
    if (!result) return [];
    return result.split("\n").map(line => line.split("\t"));
  } catch {
    return [];
  }
}

function formatEvents(rows: any[][]): string {
  if (!rows.length) return "";
  let out = "## Recent Events (48h)\n\n";
  for (const [eventDate, eventTime, title, description] of rows) {
    const time = eventTime ? ` ${eventTime}` : "";
    const desc = description ? `: ${description.slice(0, 200)}` : "";
    out += `- **${eventDate || "?"}${time}** ${title}${desc}\n`;
  }
  return out + "\n";
}

function formatDecisions(rows: any[][]): string {
  if (!rows.length) return "";
  let out = "## Recent Decisions (7d)\n\n";
  for (const [decidedAt, decision, context] of rows) {
    const ctx = context ? ` (${context.slice(0, 120)})` : "";
    out += `- **${decidedAt || "?"}** ${decision}${ctx}\n`;
  }
  return out + "\n";
}

function formatLessons(rows: any[][]): string {
  if (!rows.length) return "";
  let out = "## Active Lessons (7d)\n\n";
  for (const [lesson, context] of rows) {
    const ctx = context ? ` — ${context.slice(0, 120)}` : "";
    out += `- ${lesson}${ctx}\n`;
  }
  return out + "\n";
}

const handler = async (event: any) => {
  if (event.type !== "agent" || event.action !== "bootstrap") return;

  const ctx = event.context;
  if (!ctx?.bootstrapFiles) return;

  const sessionKey = ctx.sessionKey || event.sessionKey || "";
  if (sessionKey.includes("isolated") || sessionKey.includes("spawn") || sessionKey.includes("subagent")) return;

  if (!pgAvailable()) {
    log("skipped: PG unavailable");
    return;
  }

  const events = pgQuery(
    `SELECT event_date::text, to_char(event_time, 'HH24:MI'), title, description
     FROM events
     WHERE event_date >= (CURRENT_DATE - INTERVAL '2 days')
     ORDER BY event_date DESC, event_time DESC NULLS LAST
     LIMIT 30`
  );

  const decisions = pgQuery(
    `SELECT decided_at::date::text, decision, context
     FROM decisions
     WHERE decided_at >= (NOW() - INTERVAL '7 days')
     ORDER BY decided_at DESC
     LIMIT 10`
  );

  const lessons = pgQuery(
    `SELECT lesson, context
     FROM lessons
     WHERE learned_at >= (NOW() - INTERVAL '7 days')
       AND superseded_by IS NULL
       AND confidence > 0.3
     ORDER BY learned_at DESC
     LIMIT 10`
  );

  if (!events.length && !decisions.length && !lessons.length) {
    log("skipped: no recent data");
    return;
  }

  let content = "# Session Context\n";
  content += "*Auto-generated from PostgreSQL memory. Recent activity summary.*\n\n";
  content += formatEvents(events);
  content += formatDecisions(decisions);
  content += formatLessons(lessons);

  (ctx.bootstrapFiles as any[]).push({
    name: "SESSION_CONTEXT.md",
    content,
    missing: false,
  });

  log(`injected: ${events.length} events, ${decisions.length} decisions, ${lessons.length} lessons`);
};

export default handler;
