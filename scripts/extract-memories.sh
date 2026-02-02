#!/bin/bash
set -e

INPUT_TEXT="${1:-$(cat)}"
[ -z "$INPUT_TEXT" ] && exit 1

# Sender info from environment (set by hook)
SENDER="${SENDER_NAME:-unknown}"
SENDER_ID="${SENDER_ID:-}"
IS_GROUP="${IS_GROUP:-false}"

[ -z "$ANTHROPIC_API_KEY" ] && [ -f ~/.secrets/anthropic-api-key ] && ANTHROPIC_API_KEY=$(cat ~/.secrets/anthropic-api-key)
[ -z "$ANTHROPIC_API_KEY" ] && exit 1

# Look up user's default visibility preference
DEFAULT_VIS="public"
if [ -n "$SENDER_ID" ]; then
    # Try to find default_visibility by phone number match
    DEFAULT_VIS=$(psql -h localhost -U nova -d nova_memory -t -A -c "
        SELECT ef2.value FROM entity_facts ef1
        JOIN entity_facts ef2 ON ef1.entity_id = ef2.entity_id
        WHERE ef1.key IN ('phone', 'has_phone_number', 'signal')
          AND REPLACE(REPLACE(ef1.value, '-', ''), ' ', '') LIKE '%$(echo "$SENDER_ID" | tr -d '+- ')%'
          AND ef2.key = 'default_visibility'
        LIMIT 1;
    " 2>/dev/null || echo "public")
    [ -z "$DEFAULT_VIS" ] && DEFAULT_VIS="public"
fi

# Build prompt with sender attribution
PROMPT="Extract memory data as JSON from this message.

SENDER: ${SENDER}
IS_GROUP_CHAT: ${IS_GROUP}
USER_DEFAULT_VISIBILITY: ${DEFAULT_VIS}
MESSAGE: ${INPUT_TEXT}

IMPORTANT: For EVERY extracted item, include:
- source_person: \"${SENDER}\" (who said this)
- visibility: privacy level (see below)
- visibility_reason: ONLY if visibility differs from user default

PRIVACY DETECTION:
The user's default visibility is \"${DEFAULT_VIS}\". 
- If default is \"private\": everything is private UNLESS they say otherwise
- If default is \"public\": everything is public UNLESS they say otherwise

Look for privacy cues that OVERRIDE the default:
- Make PUBLIC (override private default): \"feel free to share\", \"this is public\", \"you can tell others\", \"not a secret\"
- Make PRIVATE (override public default): \"just between us\", \"don't tell anyone\", \"keep this secret\", \"confidential\", \"private\"

If a cue overrides the default, set visibility_reason to quote the relevant phrase.
If no cue found, use the default and omit visibility_reason.

Return JSON with these categories (only include non-empty ones):

entities: [{name, type (person|ai|organization|place), location?, source_person, visibility, visibility_reason?}]
facts: [{subject, predicate, value, source_person, confidence, visibility, visibility_reason?}]
opinions: [{holder, subject, opinion, source_person, confidence, visibility, visibility_reason?}]
preferences: [{person, category, preference, source_person, confidence, visibility, visibility_reason?}]
vocabulary: [{word, category, misheard_as?, source_person, visibility}]
events: [{description, date?, source_person, visibility, visibility_reason?}]

Examples:
- Default private + \"I love pizza\" -> visibility: \"private\" (no reason, matches default)
- Default private + \"I love pizza, feel free to share that\" -> visibility: \"public\", visibility_reason: \"feel free to share that\"
- Default public + \"Just between us, I'm thinking of quitting\" -> visibility: \"private\", visibility_reason: \"Just between us\"

Return ONLY valid JSON, no markdown fences."

# Build JSON payload
PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
  model: "claude-sonnet-4-20250514",
  max_tokens: 2048,
  messages: [{role: "user", content: $prompt}]
}')

curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$PAYLOAD" | jq -r '.content[0].text // empty'
