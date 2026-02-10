#!/bin/bash
# embed-delegation-facts.sh
# Generates embeddings for delegation facts and stores them in memory_embeddings
# This makes delegation knowledge searchable via semantic recall
#
# Usage: ./scripts/embed-delegation-facts.sh

set -e

# Database configuration - use dynamic naming based on OS user
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"
DB_HOST="localhost"

# OpenAI API key
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
if [ -z "$OPENAI_API_KEY" ]; then
    if [ -f ~/.secrets/openai-api-key ]; then
        OPENAI_API_KEY=$(cat ~/.secrets/openai-api-key)
    elif [ -f ~/.openclaw/openclaw.json ]; then
        OPENAI_API_KEY=$(jq -r '.skills.entries."openai-image-gen".apiKey // empty' ~/.openclaw/openclaw.json 2>/dev/null)
    fi
fi

if [ -z "$OPENAI_API_KEY" ]; then
    echo "ERROR: OPENAI_API_KEY not found"
    echo "Set it in environment or ~/.secrets/openai-api-key"
    exit 1
fi

echo "🧠 Embedding delegation facts for semantic recall..."

# Get all delegation facts that aren't already embedded
QUERY="
SELECT 
    ef.id,
    ef.key,
    ef.value,
    ef.confidence,
    'entity_' || ef.entity_id || '_fact_' || ef.id as source_id
FROM entity_facts ef
LEFT JOIN memory_embeddings me ON me.source_id = 'entity_' || ef.entity_id || '_fact_' || ef.id
WHERE ef.entity_id = 1 
  AND ef.key IN ('delegates_to', 'task_delegation', 'agent_capability', 'agent_success', 'agent_failure')
  AND me.id IS NULL
ORDER BY ef.confidence DESC, ef.id;
"

# Export as JSON
FACTS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -F'|' -c "$QUERY" 2>/dev/null)

if [ -z "$FACTS" ]; then
    echo "✅ All delegation facts already embedded"
    exit 0
fi

COUNT=$(echo "$FACTS" | wc -l)
echo "📝 Found $COUNT new delegation facts to embed"

# Process each fact
PROCESSED=0
echo "$FACTS" | while IFS='|' read -r fact_id key value confidence source_id; do
    [ -z "$fact_id" ] && continue
    
    # Format content for embedding
    # Make it conversational and searchable
    case "$key" in
        delegates_to)
            CONTENT="NOVA delegates to $value"
            ;;
        task_delegation)
            CONTENT="For tasks involving $value, NOVA delegates appropriately"
            ;;
        agent_capability)
            CONTENT="Agent capability: $value"
            ;;
        agent_success)
            CONTENT="Success: $value"
            ;;
        agent_failure)
            CONTENT="Lesson learned: $value"
            ;;
        *)
            CONTENT="$value"
            ;;
    esac
    
    # Get embedding from OpenAI
    EMBEDDING=$(curl -s https://api.openai.com/v1/embeddings \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"input\": \"$CONTENT\",
            \"model\": \"text-embedding-3-small\"
        }" | jq -r '.data[0].embedding | @json')
    
    if [ -z "$EMBEDDING" ] || [ "$EMBEDDING" = "null" ]; then
        echo "⚠️  Failed to embed fact $fact_id: $CONTENT"
        continue
    fi
    
    # Insert into memory_embeddings
    psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
        INSERT INTO memory_embeddings (source_type, source_id, content, embedding, confidence)
        VALUES (
            'entity_fact',
            '$source_id',
            \$\$${CONTENT}\$\$,
            '$EMBEDDING'::vector,
            $confidence
        )
        ON CONFLICT (source_id) DO UPDATE SET
            content = EXCLUDED.content,
            embedding = EXCLUDED.embedding,
            updated_at = NOW();
    " 2>/dev/null
    
    PROCESSED=$((PROCESSED + 1))
    echo "✅ [$PROCESSED/$COUNT] Embedded: $CONTENT"
    
    # Rate limit (OpenAI: 3000 RPM for tier 1, ~50/sec safe)
    sleep 0.1
done

echo ""
echo "🎯 Embedding complete!"
echo ""
echo "Test with:"
echo "  python3 ~/clawd/nova-memory/scripts/proactive-recall.py 'help me debug this code'"
echo "  python3 ~/clawd/nova-memory/scripts/proactive-recall.py 'commit these changes'"
