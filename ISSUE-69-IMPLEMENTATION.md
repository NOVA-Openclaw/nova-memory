# Issue #69 Implementation: Case-Insensitive Agent Matching

**Issue:** Enhancement: agent_chat should match on both agent_id and agent name (case-insensitive)

**Status:** ✅ Implemented

## Summary

The agent_chat channel plugin now supports flexible, case-insensitive matching on multiple agent identifiers:
- Agent name from OpenClaw config (`agentName`)
- Agent name from database (`agents.name`)
- Agent nickname from database (`agents.nickname`)
- Agent aliases from new `agent_aliases` table

## Changes Made

### 1. Database Schema (Migration: `patches/069-add-agent-aliases-table.sql`)

Created new `agent_aliases` table to store alternative identifiers for agents:

```sql
CREATE TABLE agent_aliases (
    agent_id INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    alias VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    PRIMARY KEY (agent_id, alias)
);

CREATE INDEX idx_agent_aliases_alias_lower ON agent_aliases (LOWER(alias));
```

**Features:**
- Foreign key to `agents.id` with CASCADE delete
- Composite primary key prevents duplicate aliases per agent
- Index on `LOWER(alias)` for fast case-insensitive lookup

### 2. Agent Chat Plugin (`channel.ts`)

#### New Function: `getAgentIdentifiers()`

Fetches all identifiers for an agent from the database:

```typescript
async function getAgentIdentifiers(client: pg.Client, agentName: string): Promise<string[]>
```

**Returns:** Array of lowercase-normalized identifiers including:
- Config `agentName`
- Database `agents.name`
- Database `agents.nickname` (if exists)
- All `agent_aliases.alias` entries

**Error Handling:** Falls back to config `agentName` only if database query fails (backward compatibility).

#### Updated Function: `fetchUnprocessedMessages()`

Now queries for messages where **any mention** matches **any agent identifier** (case-insensitive):

**Before:**
```sql
WHERE LOWER($1) = ANY(SELECT LOWER(unnest(ac.mentions)))
```

**After:**
```sql
WHERE EXISTS (
  SELECT 1
  FROM unnest(ac.mentions) AS mention
  WHERE LOWER(mention) = ANY($2::text[])
)
```

This allows matching like:
- Config: `agentName: "nhr-agent"`
- Database: `agents.name = "newhart"`
- Message with `mentions: ["newhart"]` → ✅ Delivered
- Message with `mentions: ["NHR-AGENT"]` → ✅ Delivered (case-insensitive)

## Example Scenarios

### Scenario 1: Config vs Database Name

**Setup:**
- OpenClaw config: `agentName: "nhr-agent"`
- Database: `INSERT INTO agents (name) VALUES ('newhart')`

**Result:**
- `@newhart help me` → Delivered ✅
- `@nhr-agent status` → Delivered ✅
- `@NEWHART urgent` → Delivered ✅ (case-insensitive)

### Scenario 2: Aliases

**Setup:**
- Config: `agentName: "Nova"`
- Database: `agents.name = "Nova"`, `agents.id = 1`
- Aliases: `INSERT INTO agent_aliases VALUES (1, 'assistant'), (1, 'helper')`

**Result:**
- `@nova schedule meeting` → Delivered ✅
- `@assistant check calendar` → Delivered ✅
- `@HELPER remind me` → Delivered ✅
- `@AI summarize` → Not delivered (no match)

### Scenario 3: Nickname

**Setup:**
- Config: `agentName: "code-bot"`
- Database: `agents.name = "code-bot"`, `agents.nickname = "coder"`

**Result:**
- `@code-bot review` → Delivered ✅
- `@coder optimize` → Delivered ✅
- `@CODER fix bugs` → Delivered ✅

## Migration Path

### For Existing Installations

1. **Apply database migration:**
   ```bash
   psql -U nova -d nova_memory -f patches/069-add-agent-aliases-table.sql
   ```

2. **Restart OpenClaw gateway:**
   ```bash
   openclaw gateway restart
   ```

3. **(Optional) Add aliases for existing agents:**
   ```sql
   -- Add nicknames as aliases
   INSERT INTO agent_aliases (agent_id, alias)
   SELECT id, nickname FROM agents WHERE nickname IS NOT NULL
   ON CONFLICT DO NOTHING;
   
   -- Add custom aliases
   INSERT INTO agent_aliases (agent_id, alias) VALUES
     (1, 'assistant'),
     (1, 'helper'),
     (2, 'coder');
   ```

### Backward Compatibility

- ✅ Works without database changes (falls back to config `agentName` only)
- ✅ Works without `agent_aliases` table (uses `agents.name` and `nickname` only)
- ✅ Existing mention patterns continue to work
- ✅ No breaking changes to existing behavior

## Testing

Test cases available in: `tests/TEST-CASES-ISSUE-69.md`

Key test scenarios:
- ✅ Case-insensitive matching on all identifiers
- ✅ Multiple agents with similar names (no collision)
- ✅ Special characters in agent names
- ✅ Empty/malformed mentions (handled gracefully)
- ✅ Performance with multiple agents and aliases

## Performance Considerations

- **Index:** `idx_agent_aliases_alias_lower` speeds up case-insensitive lookups
- **Caching:** Agent identifiers could be cached (future enhancement)
- **Query complexity:** Single join + unnest, efficient for typical workloads

## Files Changed

1. `patches/069-add-agent-aliases-table.sql` - Database migration (NEW)
2. `channel.ts` - Agent chat plugin implementation (MODIFIED)
3. `ISSUE-69-IMPLEMENTATION.md` - This documentation (NEW)

## Future Enhancements

- [ ] Cache agent identifiers to reduce database queries
- [ ] Admin UI for managing agent aliases
- [ ] Bulk import aliases from configuration
- [ ] Alias precedence rules (if multiple agents share an alias)
- [ ] Wildcard/pattern matching for mentions

## References

- Issue: nova-memory#69
- Test Cases: `tests/TEST-CASES-ISSUE-69.md`
- OpenClaw Plugin SDK: https://github.com/NOVA-Openclaw/openclaw

---

**Implementation Date:** 2026-02-13  
**Status:** Ready for Review & Testing
