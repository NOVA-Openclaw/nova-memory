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

const LOG_FILE = "/home/openclaw/.openclaw/workspace/db/session-init.log";

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
  const script = `
    const { Pool } = require('pg');
    const pool = new Pool({ database: 'auri_memory', host: '/var/run/postgresql' });
    (async () => {
      const { rows } = await pool.query(${JSON.stringify(sql)});
      console.log(JSON.stringify(rows));
      await pool.end();
    })().catch(() => { process.stdout.write('[]'); process.exit(0); });
  `;
  try {
    const result = execSync(`node -e ${JSON.stringify(script)}`, {
      encoding: "utf-8",
      timeout: 8000,
      cwd: "/home/openclaw/.openclaw/workspace",
    }).trim();
    return JSON.parse(result || "[]");
  } catch {
    return [];
  }
}

function formatEvents(rows: any[]): string {
  if (!rows.length) return "";
  let out = "## Recent Events (48h)\n\n";
  for (const r of rows) {
    const date = r.event_date?.slice(0, 10) || "?";
    const time = r.event_time?.slice(0, 5) || "";
    const desc = r.description ? `: ${r.description.slice(0, 200)}` : "";
    out += `- **${date}${time ? " " + time : ""}** ${r.title}${desc}\n`;
  }
  return out + "\n";
}

function formatDecisions(rows: any[]): string {
  if (!rows.length) return "";
  let out = "## Recent Decisions (7d)\n\n";
  for (const r of rows) {
    const date = r.decided_at?.slice(0, 10) || "?";
    const ctx = r.context ? ` (${r.context.slice(0, 120)})` : "";
    out += `- **${date}** ${r.decision}${ctx}\n`;
  }
  return out + "\n";
}

function formatLessons(rows: any[]): string {
  if (!rows.length) return "";
  let out = "## Active Lessons (7d)\n\n";
  for (const r of rows) {
    const ctx = r.context ? ` — ${r.context.slice(0, 120)}` : "";
    out += `- ${r.lesson}${ctx}\n`;
  }
  return out + "\n";
}

const handler = async (event: any) => {
  if (event.type !== "agent" || event.action !== "bootstrap") return;

  const ctx = event.context;
  if (!ctx?.bootstrapFiles) return;

  const sessionKey = ctx.sessionKey || event.sessionKey || "";
  if (sessionKey.includes("isolated") || sessionKey.includes("spawn")) return;

  if (!pgAvailable()) {
    log("skipped: PG unavailable");
    return;
  }

  const events = pgQuery(
    `SELECT event_date::text, event_time::text, title, description
     FROM events
     WHERE event_date >= (CURRENT_DATE - INTERVAL '2 days')
     ORDER BY event_date DESC, event_time DESC NULLS LAST
     LIMIT 30`
  );

  const decisions = pgQuery(
    `SELECT decided_at::text, decision, context
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
