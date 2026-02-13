# Issue #70: Add Outbound Send Support to agent_chat Plugin - COMPLETION

**Issue:** nova-memory#70  
**Branch:** `fix/issue-70-send-support`  
**Date:** 2026-02-13  
**Status:** ✅ COMPLETE

---

## Summary

Implemented outbound send functionality for the `agent_chat` plugin that enables sending messages to agents using human-friendly identifiers (nickname, database name, alias, or agentName). The implementation automatically resolves targets to the correct agentName and populates the mentions array for proper message routing.

---

## What Was Implemented

### 1. Core Function: `resolveAgentName()`

**Location:** `channel.ts` (after `getAgentIdentifiers()`)

**Purpose:** Reverse operation of `getAgentIdentifiers()` - takes any identifier and finds the agent's name.

**Implementation:**
```typescript
async function resolveAgentName(client: pg.Client, target: string): Promise<string>
```

**Features:**
- **Case-insensitive matching** on all identifier types
- Queries agents.name, agents.nickname, and agent_aliases.alias
- Returns the agent's `name` field (agentName) for use in mentions array
- Throws descriptive errors if agent not found
- Validates input (rejects empty targets)

**Query Logic:**
```sql
SELECT DISTINCT a.name
FROM agents a
LEFT JOIN agent_aliases aa ON a.id = aa.agent_id
WHERE 
  LOWER(a.name) = $1
  OR LOWER(a.nickname) = $1
  OR LOWER(aa.alias) = $1
LIMIT 1
```

### 2. Enhanced `insertOutboundMessage()`

**Change:** Added optional `mentions` parameter to function signature.

**Before:**
```typescript
{
  channel: string;
  sender: string;
  message: string;
  replyTo: number | null;
}
```

**After:**
```typescript
{
  channel: string;
  sender: string;
  message: string;
  mentions?: string[];  // NEW
  replyTo: number | null;
}
```

**Impact:** Enables messages to specify mentions array for routing.

### 3. Enhanced `sendText()` in Outbound Section

**Key Changes:**
1. **Target Resolution:** Calls `resolveAgentName()` to convert human-friendly target to agentName
2. **Mentions Array:** Populates `mentions: [targetAgentName]` in outbound messages
3. **Error Handling:** Provides helpful error messages when target resolution fails
4. **Channel Override:** Uses `"direct"` as default channel for agent-to-agent messages

**Example Flow:**
```
User calls: send to "Newhart" with message "Hello"
         ↓
resolveAgentName("Newhart") → "nhr-agent"
         ↓
INSERT with mentions=["nhr-agent"]
         ↓
nhr-agent's LISTEN picks up message (via getAgentIdentifiers)
```

### 4. Reply Handler Update

**Change:** Explicit `mentions: []` in reply messages

**Reasoning:** Replies don't need mentions because the original message already established routing context.

---

## Test Coverage

Created comprehensive test suite: `tests/test-issue-70.sh`

### Test Cases Implemented

| Test ID | Description | Status |
|---------|-------------|--------|
| TC-70-001 | Resolve by direct name | ✅ PASS |
| TC-70-002 | Resolve by nickname (case-insensitive) | ✅ PASS |
| TC-70-003 | Resolve by alias | ✅ PASS |
| TC-70-004 | Non-existent agent handling | ✅ PASS |
| TC-70-005 | Message insertion with mentions | ✅ PASS |
| TC-70-006 | Receiver fetch verification | ✅ PASS |
| TC-70-007 | Multiple message handling | ✅ PASS |
| TC-70-008 | Empty target validation | ✅ PASS |
| TC-70-009 | Full send workflow | ✅ PASS |

**Test Results:**
- All 9 test cases passing
- Verified on live database with real agent "nhr-agent" (nickname: "Newhart")
- Test script creates/cleans up test data automatically

---

## Integration with Issue #69

### Perfect Symmetry

**Issue #69 (getAgentIdentifiers):**
```
Given: agentName (e.g., "nhr-agent")
Find: All identifiers → ["nhr-agent", "newhart", "bob", ...]
Use: Match incoming messages
```

**Issue #70 (resolveAgentName):**
```
Given: Any identifier (e.g., "Newhart")
Find: The agentName → "nhr-agent"
Use: Send outbound messages
```

### Combined Workflow

1. **Sending (Issue #70):**
   ```typescript
   // User wants to send to "Newhart"
   const targetAgent = await resolveAgentName(client, "Newhart");
   // → "nhr-agent"
   
   await insertOutboundMessage({
     mentions: [targetAgent],  // ["nhr-agent"]
     ...
   });
   ```

2. **Receiving (Issue #69):**
   ```typescript
   // nhr-agent checks for messages
   const identifiers = await getAgentIdentifiers(client, "nhr-agent");
   // → ["nhr-agent", "newhart", "bob", ...]
   
   // Fetch messages where mentions overlap with identifiers
   // ✓ Finds the message because "nhr-agent" ∈ identifiers
   ```

### Result

Messages sent to "Newhart" are correctly routed to "nhr-agent" because:
- **Send:** "Newhart" → resolves to → "nhr-agent" (in mentions array)
- **Receive:** "nhr-agent" → includes → "newhart" (in identifiers list)
- **Match:** "nhr-agent" (in mentions) matches "nhr-agent" (in identifiers) ✓

---

## Key Design Decisions

### 1. Channel Defaulting
**Decision:** Use `"direct"` as default channel for agent-to-agent messages  
**Reasoning:** Cleaner semantics; original `to` parameter was overloaded (target + channel)  
**Impact:** All outbound agent messages use consistent channel naming

### 2. Case-Insensitive Everywhere
**Decision:** All identifier matching uses `LOWER()` in SQL  
**Reasoning:** Matches issue #69 behavior; better UX (users don't need exact case)  
**Impact:** "Newhart" = "newhart" = "NEWHART"

### 3. Error Messages
**Decision:** Descriptive errors with actionable guidance  
**Example:**
```
Failed to resolve target agent "Unknown": Agent not found: Unknown. 
Ensure the target agent exists in the agents table with name, nickname, 
or alias matching "Unknown".
```
**Reasoning:** Helps developers debug misconfigurations quickly

### 4. Optional Mentions
**Decision:** `mentions?: string[]` (optional parameter, defaults to empty array)  
**Reasoning:** 
- Backward compatibility (replies don't need mentions)
- Forward compatibility (future: multi-target messages)
- Type safety (TypeScript enforces correct usage)

---

## Files Modified

### `channel.ts`
- **Added:** `resolveAgentName()` function (45 lines)
- **Modified:** `insertOutboundMessage()` signature (+1 parameter)
- **Modified:** `sendText()` implementation (+18 lines)
- **Modified:** Reply handler (explicit `mentions: []`)

**Total Lines Changed:** +65 / -3

### `tests/test-issue-70.sh` (NEW)
- **Created:** Comprehensive test suite
- **Lines:** 429 lines
- **Test Cases:** 9 test scenarios
- **Executable:** `chmod +x` applied

---

## Usage Examples

### Example 1: Send by Nickname
```typescript
// User says: "Send to Newhart: Meeting at 3pm"
await sendText({
  cfg,
  to: "Newhart",  // Nickname
  text: "Meeting at 3pm",
  accountId: "default"
});

// Result:
// - Resolves "Newhart" → "nhr-agent"
// - Inserts message with mentions=["nhr-agent"]
// - nhr-agent receives the message
```

### Example 2: Send by Alias
```typescript
// Agent has alias "bob"
await sendText({
  cfg,
  to: "bob",  // Alias
  text: "Status update",
  accountId: "default"
});

// Result:
// - Resolves "bob" → "nhr-agent"
// - Message routed correctly
```

### Example 3: Error Handling
```typescript
try {
  await sendText({
    cfg,
    to: "nonexistent-agent",
    text: "This will fail",
    accountId: "default"
  });
} catch (error) {
  // Error: Failed to resolve target agent "nonexistent-agent": 
  //        Agent not found: nonexistent-agent. 
  //        Ensure the target agent exists...
}
```

---

## Testing Instructions

### Run the Test Suite
```bash
cd ~/workspace/nova-memory
./tests/test-issue-70.sh
```

### Manual Testing
```bash
# 1. Ensure database is running
psql -U nova -d nova_memory -c "SELECT name, nickname FROM agents LIMIT 5;"

# 2. Test resolution directly
psql -U nova -d nova_memory -c "
SELECT DISTINCT a.name
FROM agents a
LEFT JOIN agent_aliases aa ON a.id = aa.agent_id
WHERE 
  LOWER(a.name) = LOWER('Newhart')
  OR LOWER(a.nickname) = LOWER('Newhart')
  OR LOWER(aa.alias) = LOWER('Newhart')
LIMIT 1;
"

# 3. Send a test message (requires OpenClaw runtime)
# Use message tool with target "agent_chat:Newhart"
```

---

## Verification Checklist

- [x] **Code Implementation**
  - [x] `resolveAgentName()` function added
  - [x] `insertOutboundMessage()` accepts mentions
  - [x] `sendText()` resolves targets and populates mentions
  - [x] Reply handler updated with explicit mentions

- [x] **Testing**
  - [x] Test script created (`test-issue-70.sh`)
  - [x] All 9 test cases passing
  - [x] Case-insensitive matching verified
  - [x] Error handling tested

- [x] **Integration**
  - [x] Complements issue #69 infrastructure
  - [x] Uses same query patterns (consistency)
  - [x] No duplicate resolution logic

- [x] **Documentation**
  - [x] Code comments explain functionality
  - [x] Error messages are descriptive
  - [x] This completion document

- [x] **Version Control**
  - [x] Branch created: `fix/issue-70-send-support`
  - [x] Changes committed with descriptive message
  - [x] Ready for PR

---

## Migration Notes

### No Database Changes Required
This implementation uses existing tables:
- `agents` (name, nickname)
- `agent_aliases` (agent_id, alias)
- `agent_chat` (mentions array already exists)

### Backward Compatibility
- Existing code continues to work (mentions optional)
- Reply messages still work (explicit empty array)
- No breaking changes to plugin API

---

## Performance Considerations

### Query Performance
- **Single query with LEFT JOIN:** Efficient lookup across all identifier types
- **LIMIT 1:** Stops at first match
- **Indexed columns:** 
  - `agents.name` (primary lookup)
  - `agents.nickname` (indexed)
  - `agent_aliases.alias` (indexed via `idx_agent_aliases_alias_lower`)

### Expected Performance
- **Resolution time:** <5ms (indexed lookup)
- **Message insert:** <10ms (standard INSERT)
- **Total send overhead:** <20ms per message

---

## Future Enhancements (Out of Scope)

### Potential Improvements
1. **Multi-target messages:** `mentions: [agent1, agent2, ...]`
2. **Target validation API:** Pre-check if target exists before sending
3. **Alias ambiguity handling:** If multiple agents share alias, return error or list
4. **Caching:** Cache resolveAgentName results for hot paths
5. **Metrics:** Track resolution success/failure rates

### Test Coverage Expansion
- Performance benchmarks (1000+ resolutions/sec)
- Concurrent send stress testing
- Multi-account scenarios
- Edge cases: Unicode in identifiers, very long names

---

## Related Issues

- **Issue #69:** Case-insensitive agent matching (inbound) - COMPLETED
- **Issue #70:** Outbound send support (this issue) - COMPLETED

### Dependency Chain
```
Issue #69 (getAgentIdentifiers) 
    ↓ provides infrastructure
Issue #70 (resolveAgentName)
    ↓ enables
Bidirectional agent messaging
```

---

## Commit Information

**Branch:** `fix/issue-70-send-support`  
**Commit Hash:** `3cafaff`  
**Commit Message:**
```
Issue #70: Add outbound send support to agent_chat plugin

- Add resolveAgentName() function to resolve human-friendly targets
  (nickname, dbName, alias) to agent names for mentions array
- Update insertOutboundMessage() to accept optional mentions parameter
- Enhance sendText() to resolve targets and populate mentions array
- Add comprehensive test suite (test-issue-70.sh) covering:
  * Name, nickname, and alias resolution (case-insensitive)
  * Message insertion with mentions
  * Receiver message fetching validation
  * Error handling for non-existent agents
  * Full send workflow integration

Implementation complements issue #69 getAgentIdentifiers() by providing
reverse lookup: given any identifier, find the agent's name for routing.
```

**Files Changed:**
- `channel.ts` (+65, -3)
- `tests/test-issue-70.sh` (+429, NEW)

---

## Next Steps

1. **Review:** Code review by maintainers
2. **Merge:** Merge to main after approval
3. **Deploy:** Update live OpenClaw installations
4. **Documentation:** Update plugin documentation with send examples
5. **Monitor:** Watch for any edge cases in production

---

## Conclusion

Issue #70 is **COMPLETE**. The implementation provides robust, user-friendly outbound send functionality that integrates seamlessly with issue #69's infrastructure. All test cases pass, and the code is ready for production use.

The key achievement: Users can now send messages to agents using natural identifiers ("Newhart", "bob", etc.) without needing to know the exact database agent name, and message routing works automatically through the mentions array.

---

**Implemented by:** claude-code (subagent)  
**Date:** 2026-02-13  
**Status:** ✅ READY FOR PR
