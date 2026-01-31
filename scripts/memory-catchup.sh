#!/bin/bash
# memory-catchup.sh - Process unprocessed messages from session transcripts
# Tracks position and only processes new input since last run

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${HOME}/.clawdbot/memory-catchup-state.json"
TRANSCRIPT_DIR="${HOME}/.clawdbot/agents/main/sessions"
EXTRACT_SCRIPT="${SCRIPT_DIR}/process-input.sh"

# Ensure state file exists
mkdir -p "$(dirname "$STATE_FILE")"
if [ ! -f "$STATE_FILE" ]; then
    echo '{"last_processed_ts": "1970-01-01T00:00:00.000Z", "processed_count": 0}' > "$STATE_FILE"
fi

# Get last processed timestamp
LAST_TS=$(jq -r '.last_processed_ts // "1970-01-01T00:00:00.000Z"' "$STATE_FILE")
CURRENT_TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

echo "[memory-catchup] Last processed: $LAST_TS"
echo "[memory-catchup] Looking for new messages..."

# Find the most recent session transcript
MAIN_SESSION=$(ls -t "$TRANSCRIPT_DIR"/*.jsonl 2>/dev/null | head -1)

if [ -z "$MAIN_SESSION" ] || [ ! -f "$MAIN_SESSION" ]; then
    echo "[memory-catchup] No session transcripts found"
    exit 0
fi

echo "[memory-catchup] Processing: $MAIN_SESSION"

# Extract user messages from transcript
# Format: {"type":"message","message":{"role":"user","content":[{"type":"text","text":"..."}]}}
MESSAGES_TO_PROCESS=$(mktemp)

# Parse JSONL and filter for user messages newer than last_ts
jq -c --arg last_ts "$LAST_TS" '
    select(.type == "message") |
    select(.message.role == "user") |
    select(.timestamp > $last_ts) |
    {
        content: (
            if (.message.content | type) == "array" then
                (.message.content[] | select(.type == "text") | .text) // ""
            elif (.message.content | type) == "string" then
                .message.content
            else
                ""
            end
        ),
        timestamp: .timestamp
    } |
    select(.content != "" and .content != null)
' "$MAIN_SESSION" 2>/dev/null > "$MESSAGES_TO_PROCESS" || true

MSG_COUNT=$(wc -l < "$MESSAGES_TO_PROCESS" | tr -d ' ')
echo "[memory-catchup] Found $MSG_COUNT new user messages"

if [ "$MSG_COUNT" -eq 0 ] || [ ! -s "$MESSAGES_TO_PROCESS" ]; then
    rm -f "$MESSAGES_TO_PROCESS"
    # Update timestamp even if no messages to avoid reprocessing
    TOTAL=$(jq -r '.processed_count // 0' "$STATE_FILE")
    echo "{\"last_processed_ts\": \"$CURRENT_TS\", \"processed_count\": $TOTAL}" > "$STATE_FILE"
    echo "[memory-catchup] No new messages"
    exit 0
fi

# Process each message
PROCESSED=0
NEWEST_TS="$LAST_TS"
while IFS= read -r line; do
    CONTENT=$(echo "$line" | jq -r '.content // empty' 2>/dev/null)
    MSG_TS=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)
    
    # Skip empty or very short messages
    if [ -z "$CONTENT" ] || [ ${#CONTENT} -lt 20 ]; then
        continue
    fi
    
    # Skip messages that look like commands or system
    if [[ "$CONTENT" == /* ]] || [[ "$CONTENT" == "HEARTBEAT"* ]] || [[ "$CONTENT" == "NO_REPLY"* ]]; then
        continue
    fi
    
    # Skip messages that are just prompts/instructions
    if [[ "$CONTENT" == *"Pre-compaction memory flush"* ]] || [[ "$CONTENT" == *"Read HEARTBEAT.md"* ]]; then
        continue
    fi
    
    echo "[memory-catchup] Processing: ${CONTENT:0:80}..."
    
    # Run extraction (background, don't wait)
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(grep ANTHROPIC_API_KEY ~/.bashrc | cut -d= -f2 | tr -d \"\'\" | head -1)}"
    "$EXTRACT_SCRIPT" "I)ruid said: $CONTENT" &>/dev/null &
    
    PROCESSED=$((PROCESSED + 1))
    
    # Track newest timestamp
    if [[ "$MSG_TS" > "$NEWEST_TS" ]]; then
        NEWEST_TS="$MSG_TS"
    fi
    
    # Rate limit - max 3 per run to avoid API spam
    if [ "$PROCESSED" -ge 3 ]; then
        echo "[memory-catchup] Rate limit reached (3/run), will continue next run"
        break
    fi
    
    # Small delay between extractions
    sleep 1
done < "$MESSAGES_TO_PROCESS"

rm -f "$MESSAGES_TO_PROCESS"

# Update state with the newest timestamp we processed
TOTAL=$(jq -r '.processed_count // 0' "$STATE_FILE")
NEW_TOTAL=$((TOTAL + PROCESSED))

if [[ "$NEWEST_TS" > "$LAST_TS" ]]; then
    echo "{\"last_processed_ts\": \"$NEWEST_TS\", \"processed_count\": $NEW_TOTAL}" > "$STATE_FILE"
else
    echo "{\"last_processed_ts\": \"$CURRENT_TS\", \"processed_count\": $NEW_TOTAL}" > "$STATE_FILE"
fi

echo "[memory-catchup] Processed $PROCESSED messages (total: $NEW_TOTAL)"
