# Pull Request: Add Outbound Send Support to agent_chat Plugin

## Issue
Fixes #70: Add outbound send support to agent_chat plugin

## Summary
This PR implements outbound send functionality that enables agents to send messages using human-friendly target identifiers (nickname, alias, or agent name). The implementation automatically resolves targets to the correct agentName and populates the mentions array for proper message routing.

## Key Changes

### 1. New Function: `resolveAgentName()`
- **Purpose:** Reverse lookup of `getAgentIdentifiers()` from #69
- **Input:** Any identifier (nickname, alias, or agent name)
- **Output:** The agent's canonical name for use in mentions array
- **Features:**
  - Case-insensitive matching across all identifier types
  - Queries `agents.name`, `agents.nickname`, and `agent_aliases.alias`
  - Descriptive error handling for non-existent agents

### 2. Enhanced `insertOutboundMessage()`
- Added optional `mentions?: string[]` parameter
- Maintains backward compatibility (defaults to empty array)
- Enables proper message routing via mentions array

### 3. Enhanced `sendText()` in Outbound Section
- Resolves human-friendly targets to agentNames using `resolveAgentName()`
- Populates mentions array with resolved target
- Uses "direct" as default channel for agent-to-agent messages
- Provides helpful error messages when resolution fails

### 4. Updated Reply Handler
- Explicit `mentions: []` for reply messages
- Clarifies that replies inherit routing from original message

## Integration with Issue #69

This implementation perfectly complements #69's `getAgentIdentifiers()`:

**Issue #69 (Receiving):**
```
Agent "nhr-agent" checks for messages
→ getAgentIdentifiers() returns ["nhr-agent", "newhart", "bob", ...]
→ Fetches messages where mentions overlap with identifiers
```

**Issue #70 (Sending):**
```
User sends to "Newhart"
→ resolveAgentName() returns "nhr-agent"
→ Inserts message with mentions=["nhr-agent"]
→ nhr-agent's listener picks it up (matches identifier)
```

**Result:** Messages sent to "Newhart" are correctly routed to "nhr-agent" ✓

## Example Usage

```typescript
// Send by nickname
await sendText({
  cfg,
  to: "Newhart",  // Resolves to "nhr-agent"
  text: "Meeting at 3pm",
  accountId: "default"
});

// Send by alias
await sendText({
  cfg,
  to: "bob",  // Resolves to configured agent
  text: "Status update",
  accountId: "default"
});
```

## Test Coverage

Created comprehensive test suite: `tests/test-issue-70.sh`

**Test Cases:**
- ✅ TC-70-001: Resolve by direct name
- ✅ TC-70-002: Resolve by nickname (case-insensitive)
- ✅ TC-70-003: Resolve by alias
- ✅ TC-70-004: Non-existent agent error handling
- ✅ TC-70-005: Message insertion with mentions
- ✅ TC-70-006: Receiver fetch verification
- ✅ TC-70-007: Multiple message handling
- ✅ TC-70-008: Empty target validation
- ✅ TC-70-009: Full send workflow integration

**Test Results:** All 9 test cases passing ✅

## Files Changed

- **`channel.ts`** (+65, -3)
  - Added `resolveAgentName()` function
  - Updated `insertOutboundMessage()` signature
  - Enhanced `sendText()` with target resolution
  - Updated reply handler

- **`tests/test-issue-70.sh`** (+429, NEW)
  - Comprehensive test suite with 9 test cases
  - Verifies all resolution paths
  - Tests error handling and edge cases

## Backward Compatibility

✅ **No breaking changes**
- Existing code continues to work
- `mentions` parameter is optional (defaults to `[]`)
- Reply messages still function correctly
- No database migrations required

## Performance Impact

**Expected overhead per message:**
- Target resolution: <5ms (indexed SQL query)
- Message insert: <10ms (standard INSERT)
- **Total:** <20ms additional latency

**Query optimization:**
- Single query with LEFT JOIN (efficient)
- LIMIT 1 (stops at first match)
- Uses existing indexes on name, nickname, alias

## Database Requirements

**No migrations required** - uses existing schema:
- `agents` table (name, nickname columns)
- `agent_aliases` table (agent_id, alias columns)
- `agent_chat` table (mentions array already exists)

## Testing Instructions

### Automated Testing
```bash
cd ~/workspace/nova-memory
./tests/test-issue-70.sh
```

### Manual Testing
```bash
# Verify agent exists
psql -U nova -d nova_memory -c \
  "SELECT name, nickname FROM agents WHERE nickname = 'Newhart';"

# Test resolution query
psql -U nova -d nova_memory -c "
SELECT DISTINCT a.name
FROM agents a
LEFT JOIN agent_aliases aa ON a.id = aa.agent_id
WHERE 
  LOWER(a.name) = LOWER('Newhart')
  OR LOWER(a.nickname) = LOWER('Newhart')
  OR LOWER(aa.alias) = LOWER('Newhart')
LIMIT 1;"
```

## Design Decisions

### 1. Case-Insensitive Matching
**Why:** Matches #69 behavior; better UX (users don't need exact case)  
**Impact:** "Newhart" = "newhart" = "NEWHART"

### 2. Default Channel = "direct"
**Why:** Cleaner semantics for agent-to-agent messages  
**Impact:** Consistent channel naming across outbound messages

### 3. Descriptive Errors
**Why:** Helps developers debug configuration issues quickly  
**Example:**
```
Failed to resolve target agent "Unknown": Agent not found: Unknown.
Ensure the target agent exists in the agents table with name, 
nickname, or alias matching "Unknown".
```

### 4. Reverse Lookup Pattern
**Why:** Symmetry with #69; clear separation of concerns (send vs receive)  
**Impact:** Two functions (`getAgentIdentifiers` + `resolveAgentName`) that mirror each other

## Known Limitations

1. **Single target only:** Current implementation supports one target per message
2. **No ambiguity handling:** If multiple agents share an alias, first match wins (LIMIT 1)
3. **No caching:** Resolution happens on every send (acceptable for current load)

These are documented as potential future enhancements.

## Documentation

- **Code comments:** All new functions fully documented
- **Completion doc:** `ISSUE-70-COMPLETION.md` provides detailed implementation guide
- **Test cases:** `tests/TEST-CASES-ISSUE-70.md` defines expected behavior

## Checklist

- [x] Implementation complete
- [x] All test cases passing
- [x] Code documented with comments
- [x] No breaking changes
- [x] Backward compatible
- [x] Integration with #69 verified
- [x] Completion document created
- [x] PR description written

## Reviewers

Please verify:
1. ✅ Query logic matches #69 pattern (consistency)
2. ✅ Error messages are helpful
3. ✅ Type safety (TypeScript signatures correct)
4. ✅ Test coverage adequate
5. ✅ No performance regressions

## Related PRs

- PR #69: Case-insensitive agent matching (merged)

## Deployment Notes

**No special deployment steps required:**
- Works with existing database schema
- No configuration changes needed
- Backward compatible with existing installations

Simply merge and deploy as normal.

---

**Ready for review!** 🚀

This implementation completes the agent-to-agent messaging infrastructure by enabling natural, user-friendly outbound sends that automatically route to the correct agent using the mentions array.
