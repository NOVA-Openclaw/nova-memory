# MEMORY.md - Long-Term Memory

*Last updated: 2026-01-30*

## Memory Architecture

**Primary storage:** PostgreSQL database `nova_memory` ← CHECK THIS FIRST
- Entities (people, AIs, orgs), places, projects, events, lessons, SOPs, tasks
- Query with: `psql -h localhost -U nova -d nova_memory -c "..."`
- See TOOLS.md for schema details

**This file:** Quick-reference context injected every turn
**Daily logs:** `memory/YYYY-MM-DD.md` for raw journaling

### Key Entity IDs
- **NOVA (me):** Entity ID 1
- **I)ruid:** Entity ID 2

### Important Behaviors
1. **Database first** — Check PostgreSQL before flat files
2. **SOPs exist** — Check `SELECT name, description FROM sops;` before improvising recurring tasks
3. **Log to database** — Important events → `events` table, lessons → `lessons` table
4. **Tasks table** — Check `tasks` for assigned work before picking up new things

### Common Queries
```sql
-- Who do I know?
SELECT name, type FROM entities;

-- Facts about someone
SELECT key, value FROM v_entity_facts WHERE name = 'Tabby';

-- I)ruid's partners
SELECT entity_b_name FROM v_relationships WHERE entity_a_name = 'I)ruid' AND relationship = 'partner';

-- Active projects
SELECT name, status, goal FROM projects WHERE status = 'active';
```

## My Setup (January 30, 2026)

### Accounts & Credentials (scan `op item list` periodically!)
All credentials stored in **1Password → NOVA Shared Vault**

| Service | Account | Notes |
|---------|---------|-------|
| **Google Workspace** | nova@dustintrammell.com | Gmail, Calendar, Drive, Contacts, Docs, Sheets, YouTube |
| **Google Voice** | nova@dustintrammell.com | +1 512-222-8661 (Austin, TX) |
| **Signal** | +1 512-222-8661 | My primary messaging |
| **Discord** | nova@dustintrammell.com | Created by I)ruid (CAPTCHA issues) |
| **GitHub** | NOVA-Openclaw | For repos and code |
| **X (Twitter)** | @NOVA_Openclaw | Uses `bird` CLI with cookies |
| **Instagram** | (check 1Password) | Have account, need to use it! |
| **Midjourney** | nova@dustintrammell.com | Image generation (Google OAuth) |
| **ElevenLabs** | nova@dustintrammell.com | TTS API, Voice = Bella |
| **Alpha Vantage** | — | Stock API (25 req/day - execution only!) |
| **Philips Hue** | Developer account | For smart lighting control |
| **Capital One** | VENTURE card | My credit card |

**1Password:** Family plan member, confirmed by I)ruid

### Infrastructure
- **Host:** AWS EC2 (ip-172-31-12-7), Ubuntu, user: nova
- **Browser:** Chrome 144 headless
- **GPG Key:** EF16FFEA04757CFD36F76BE529E5D6A042CD0433

## Active Projects

### Nova Android App 📱
- Custom app for voice interface + smart home control
- Architecture: `projects/nova-app/ARCHITECTURE.md`
- Stack: Kotlin, Jetpack Compose, OkHttp WebSocket, Firebase
- **Blocked:** Needs Firebase setup, Claude Code CLI API key

### Stock Paper Trading 📈
- Research completed: `research/stock-picks-2026-01-30.md`
- Picks: AMD, NVDA, SMCI, META, CRWD
- **Waiting:** I)ruid review before executing paper trades

## I)ruid Context

- Currently in **San Juan, Puerto Rico** (Casa de Verde San Juan)
- Uses calendar as day planner + personal history log
- Night owl, flexible schedule
- Polyamorous (partners include Tabby, Carla, Regan, Rayven, Christina, Lauren)

### Background
- Bitcoin OG — received 25 BTC from Satoshi Nakamoto on Jan 14, 2009
- InfoSec researcher (DEFCON, BlackHat speaker)
- CEO of Trammell Ventures (Bitcoin-focused VC)
- Runs: Blockhenge, Rogue Signal (game design), BDYHAX (bodyhacking conference)

## Preferences & Lessons

- **Yes/No questions:** Answer with "Yes, Sir." or "No, Sir." FIRST, then explanation after
- **Acknowledge directives:** "Yes, Sir." not casual "Got it!"
- Store credentials immediately when creating accounts
- Use 1Password's shared vault (NOVA Shared Vault) by default
- Alpha Vantage: execution only, web search for research

## Network Access (VPN connected)
| Location | Subnet | Theme |
|----------|--------|-------|
| Austin (New York) | 10.3.3.0/24 | Ghostbusters |
| San Juan (Hill Valley) | 10.3.6.0/24 | Back to the Future |
| Purple Palace (Tabby's) | 10.3.8.0/24 | — |

All locations VPN'd together. Hue bridges at each location.

---
*Raw daily logs: `memory/YYYY-MM-DD.md`*

## Bitcoin Node (2026-01-30)

Running Bitcoin Knots BIP-110 activation client - signaling for CTV/OP_CHECKTEMPLATEVERIFY soft fork activation.
- Pruned node (550MB) on AWS EC2
- Service: `sudo systemctl status bitcoind`
- Quick check: `bitcoin-cli -getinfo`
- RPC: 1Password "Bitcoin Node RPC"

This aligns with I)ruid's early Bitcoin history (received 25 BTC from Satoshi in 2009).
