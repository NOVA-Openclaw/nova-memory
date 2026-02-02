#!/bin/bash
set -e

INPUT_TEXT="${1:-$(cat)}"
[ -z "$INPUT_TEXT" ] && exit 1

[ -z "$ANTHROPIC_API_KEY" ] && [ -f ~/.secrets/anthropic-api-key ] && ANTHROPIC_API_KEY=$(cat ~/.secrets/anthropic-api-key)
[ -z "$ANTHROPIC_API_KEY" ] && exit 1

# Build JSON payload
PAYLOAD=$(jq -n --arg text "$INPUT_TEXT" '{
  model: "claude-sonnet-4-20250514",
  max_tokens: 2048,
  messages: [{
    role: "user", 
    content: ("Extract memory data as JSON. Categories: entities, facts, opinions, events. Include source_person, confidence. Text: " + $text)
  }]
}')

curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$PAYLOAD" | jq -r '.content[0].text // empty'
