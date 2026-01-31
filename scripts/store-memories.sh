#!/bin/bash
# store-memories.sh - Store extracted memories into PostgreSQL database
# Takes JSON from extract-memories.sh and inserts into nova_memory database

set -e

# Read JSON from stdin or argument
if [ -n "$1" ]; then
    JSON_DATA="$1"
else
    JSON_DATA=$(cat)
fi

if [ -z "$JSON_DATA" ] || [ "$JSON_DATA" = "null" ]; then
    echo "No data to store" >&2
    exit 0
fi

# Validate JSON
if ! echo "$JSON_DATA" | jq . >/dev/null 2>&1; then
    echo "Invalid JSON input" >&2
    exit 1
fi

DB="nova_memory"
DB_USER="nova"
DB_HOST="localhost"

# Function to safely escape SQL strings
sql_escape() {
    echo "$1" | sed "s/'/''/g"
}

# Function to find existing entity by name or nickname
find_entity() {
    local search_name="$1"
    # Search by name, full_name, or in nicknames array
    psql -h "$DB_HOST" -U "$DB_USER" -d "$DB" -t -A -c "
        SELECT name FROM entities 
        WHERE LOWER(name) = LOWER('$(sql_escape "$search_name")')
           OR LOWER(full_name) = LOWER('$(sql_escape "$search_name")')
           OR LOWER('$(sql_escape "$search_name")') = ANY(SELECT LOWER(unnest(nicknames)))
        LIMIT 1;
    " 2>/dev/null | head -1
}

# Process entities
echo "$JSON_DATA" | jq -c '.entities[]? // empty' | while read -r entity; do
    name=$(echo "$entity" | jq -r '.name')
    type=$(echo "$entity" | jq -r '.type // "other"')
    location=$(echo "$entity" | jq -r '.location // empty')
    
    # Map common types
    case "$type" in
        restaurant|cafe|bar|venue) 
            # It's a place - check if exists first
            existing=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB" -t -A -c "SELECT name FROM places WHERE LOWER(name) = LOWER('$(sql_escape "$name")') LIMIT 1;" 2>/dev/null)
            if [ -z "$existing" ]; then
                echo "INSERT INTO places (name, type, city) VALUES ('$(sql_escape "$name")', 'venue', '$(sql_escape "$location")') ON CONFLICT DO NOTHING;" | psql -h "$DB_HOST" -U "$DB_USER" -d "$DB" -q 2>/dev/null || true
                echo "  + Place: $name (new)"
            else
                echo "  = Place: $name (exists as: $existing)"
            fi
            ;;
        person|ai|organization)
            # Check if entity already exists by name or nickname
            existing=$(find_entity "$name")
            if [ -z "$existing" ]; then
                echo "INSERT INTO entities (name, type) VALUES ('$(sql_escape "$name")', '$type') ON CONFLICT DO NOTHING;" | psql -h "$DB_HOST" -U "$DB_USER" -d "$DB" -q 2>/dev/null || true
                echo "  + Entity: $name ($type) (new)"
            else
                echo "  = Entity: $name -> matched to: $existing"
                # Use the existing entity name for subsequent fact storage
                name="$existing"
            fi
            ;;
        *)
            echo "  ? Unknown entity type: $name ($type)"
            ;;
    esac
done

# Process facts
echo "$JSON_DATA" | jq -c '.facts[]? // empty' | while read -r fact; do
    subject=$(echo "$fact" | jq -r '.subject')
    predicate=$(echo "$fact" | jq -r '.predicate')
    value=$(echo "$fact" | jq -r '.value')
    
    # Try to add as entity_fact
    echo "INSERT INTO entity_facts (entity_id, key, value, source)
          SELECT id, '$(sql_escape "$predicate")', '$(sql_escape "$value")', 'auto-extracted'
          FROM entities WHERE name = '$(sql_escape "$subject")'
          ON CONFLICT DO NOTHING;" | psql -h "$DB_HOST" -U "$DB_USER" -d "$DB" -q 2>/dev/null || true
    echo "  + Fact: $subject.$predicate = $value"
done

# Process opinions
echo "$JSON_DATA" | jq -c '.opinions[]? // empty' | while read -r opinion; do
    holder=$(echo "$opinion" | jq -r '.holder')
    subject=$(echo "$opinion" | jq -r '.subject')
    opinion_text=$(echo "$opinion" | jq -r '.opinion')
    
    # Find the actual entity name (match by nickname if needed)
    actual_holder=$(find_entity "$holder")
    if [ -z "$actual_holder" ]; then
        actual_holder="$holder"
    fi
    
    # Store as entity_fact with opinion prefix
    echo "INSERT INTO entity_facts (entity_id, key, value, source)
          SELECT id, 'opinion_$(sql_escape "$subject")', '$(sql_escape "$opinion_text")', 'auto-extracted'
          FROM entities WHERE name = '$(sql_escape "$actual_holder")')
          ON CONFLICT DO NOTHING;" | psql -h "$DB_HOST" -U "$DB_USER" -d "$DB" -q 2>/dev/null || true
    echo "  + Opinion: $actual_holder thinks '$opinion_text' about $subject"
done

# Process preferences
echo "$JSON_DATA" | jq -c '.preferences[]? // empty' | while read -r pref; do
    person=$(echo "$pref" | jq -r '.person // .holder')
    preference=$(echo "$pref" | jq -r '.preference // .likes // .prefers')
    category=$(echo "$pref" | jq -r '.category // "general"')
    
    echo "INSERT INTO entity_facts (entity_id, key, value, source)
          SELECT id, 'preference_$(sql_escape "$category")', '$(sql_escape "$preference")', 'auto-extracted'
          FROM entities WHERE name = '$(sql_escape "$person")'
          ON CONFLICT DO NOTHING;" | psql -h "$DB_HOST" -U "$DB_USER" -d "$DB" -q 2>/dev/null || true
    echo "  + Preference: $person prefers $preference"
done

echo "Memory storage complete."
