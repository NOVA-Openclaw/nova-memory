#!/bin/bash
# extract-memories.sh - Extract entities, facts, and context from text input
# Uses Claude API to parse natural language into structured memory data

set -e

# Get input text (from argument or stdin)
if [ -n "$1" ]; then
    INPUT_TEXT="$1"
else
    INPUT_TEXT=$(cat)
fi

if [ -z "$INPUT_TEXT" ]; then
    echo "Usage: extract-memories.sh <text>" >&2
    echo "   or: echo 'text' | extract-memories.sh" >&2
    exit 1
fi

# Get API key from environment or 1Password
if [ -z "$ANTHROPIC_API_KEY" ]; then
    ANTHROPIC_API_KEY=$(op item get "Anthropic API" --vault="NOVA Shared Vault" --field=credential 2>/dev/null || echo "")
fi

if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "Error: ANTHROPIC_API_KEY not set and couldn't fetch from 1Password" >&2
    exit 1
fi

# Create the extraction prompt
PROMPT='Extract structured memory data from this text. Return valid JSON only.

Categories to extract:
1. entities: People, AIs, organizations, pets, objects with names
2. places: Restaurants, cities, buildings, locations
3. facts: Objective information about entities/places
4. opinions: Subjective views held by specific people (note whose opinion)
5. preferences: What someone likes/dislikes/prefers
6. events: Things that happened with dates if mentioned
7. relationships: Connections between entities

For each item, include:
- source_person: Who said/believes this (null if objective fact)
- confidence: high/medium/low
- temporal: any time context (always, usually, once, etc.)

Example output:
{
  "entities": [
    {"name": "Niché", "type": "restaurant", "location": "San Juan, Puerto Rico"}
  ],
  "facts": [
    {"subject": "Niché", "predicate": "has_no_cell_signal", "value": true, "confidence": "high"}
  ],
  "opinions": [
    {"holder": "I)ruid", "subject": "Niché", "opinion": "best steak au poivre ever", "confidence": "high"}
  ],
  "preferences": [],
  "events": [],
  "relationships": []
}

Text to analyze:
"""
'"$INPUT_TEXT"'
"""

Return ONLY valid JSON, no markdown or explanation.'

# Call Claude API
RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "{
        \"model\": \"claude-sonnet-4-20250514\",
        \"max_tokens\": 1024,
        \"messages\": [{
            \"role\": \"user\",
            \"content\": $(echo "$PROMPT" | jq -Rs .)
        }]
    }")

# Extract the text content from the response
echo "$RESPONSE" | jq -r '.content[0].text // .error.message // "Error parsing response"'
