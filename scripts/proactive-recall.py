#!/usr/bin/env python3
"""
Proactive Recall: Get relevant memories before processing a message.

Usage (as a standalone):
    python proactive-recall.py "user's message here"
    python proactive-recall.py "message" --max-tokens 500
    python proactive-recall.py "message" --inject
    
Output: JSON with relevant memories to inject into context.

For Clawdbot integration, call this from a hook or message preprocessor.
"""

import os
import sys
import json
import argparse
from pathlib import Path
import psycopg2
import openai
import subprocess

EMBEDDING_MODEL = "text-embedding-3-small"

# Database configuration - use dynamic naming based on OS user
def get_db_name():
    """Get database name based on current OS user."""
    db_user = os.environ.get('PGUSER')
    if not db_user:
        try:
            db_user = subprocess.check_output(['whoami'], text=True).strip()
        except:
            db_user = 'nova'  # fallback
    # Replace hyphens with underscores (PostgreSQL doesn't allow hyphens)
    db_user = db_user.replace('-', '_')
    return f"{db_user}_memory"

DB_NAME = get_db_name()

# Default configuration
DEFAULT_MAX_RESULTS = 10  # Fetch more, then filter by token budget
DEFAULT_TOKEN_BUDGET = 1000  # Max tokens to inject
DEFAULT_THRESHOLD = 0.4  # Minimum similarity
HIGH_CONFIDENCE_THRESHOLD = 0.7  # Above this, inject full content

# Dynamic content limits - adjusted based on result count
# Fewer results = more content each, more results = less content each
CONTENT_LIMITS = {
    "min_summary": 100,   # Absolute minimum chars
    "max_summary": 200,   # Summary when many results
    "min_full": 300,      # Full content when many results  
    "max_full": 600,      # Full content when few results
}

def get_openai_client():
    """Get OpenAI client with API key from environment.
    
    API key must be set in environment (inherited from OpenClaw).
    """
    api_key = os.environ.get("OPENAI_API_KEY")
    
    if not api_key:
        print("ERROR: OPENAI_API_KEY not set in environment", file=sys.stderr)
        print("This script should be run from OpenClaw hooks which inherit the API key", file=sys.stderr)
        return None
    
    return openai.OpenAI(api_key=api_key)

def get_embedding(client, text):
    """Get embedding vector from OpenAI."""
    response = client.embeddings.create(
        model=EMBEDDING_MODEL,
        input=text
    )
    return response.data[0].embedding

def estimate_tokens(text):
    """Rough token estimate: ~4 chars per token for English."""
    return len(text) // 4

def calculate_dynamic_limits(result_count):
    """
    Dynamic limits: fewer results = more content each, more results = shorter content.
    Scales linearly between 1 result (max content) and 10+ results (min content).
    """
    # Clamp result count to reasonable range
    count = max(1, min(result_count, 10))
    
    # Linear interpolation: 1 result = max, 10 results = min
    factor = (10 - count) / 9  # 1.0 at count=1, 0.0 at count=10
    
    summary_len = int(CONTENT_LIMITS["min_summary"] + 
                      factor * (CONTENT_LIMITS["max_summary"] - CONTENT_LIMITS["min_summary"]))
    full_len = int(CONTENT_LIMITS["min_full"] + 
                   factor * (CONTENT_LIMITS["max_full"] - CONTENT_LIMITS["min_full"]))
    
    return summary_len, full_len


def truncate_content(content, similarity, result_count=5, high_threshold=HIGH_CONFIDENCE_THRESHOLD):
    """
    Tiered retrieval with dynamic limits:
    - High confidence (>= threshold): return more content
    - Low confidence: return summary only
    - Content length adjusts based on how many results we're showing
    """
    summary_len, full_len = calculate_dynamic_limits(result_count)
    
    if similarity >= high_threshold:
        max_len = full_len
        suffix = "..." if len(content) > max_len else ""
    else:
        max_len = summary_len
        suffix = " [summary]" if len(content) > max_len else ""
    
    if len(content) <= max_len:
        return content
    
    return content[:max_len].rsplit(' ', 1)[0] + suffix

def recall(message, token_budget=DEFAULT_TOKEN_BUDGET, threshold=DEFAULT_THRESHOLD, 
           max_results=DEFAULT_MAX_RESULTS, high_confidence=HIGH_CONFIDENCE_THRESHOLD):
    """
    Get relevant memories for a message with token budget control.
    
    Args:
        message: Query text
        token_budget: Maximum tokens to return (approximate)
        threshold: Minimum similarity score
        max_results: Maximum results to fetch from DB
        high_confidence: Threshold for full content vs summary
    """
    client = get_openai_client()
    if not client:
        return {"error": "No OpenAI API key", "memories": []}
    
    try:
        conn = psycopg2.connect(dbname=DB_NAME, host="localhost", user="nova")
        query_embedding = get_embedding(client, message)
        
        cur = conn.cursor()
        cur.execute("""
            SELECT 
                source_type,
                source_id,
                content,
                1 - (embedding <=> %s::vector) AS similarity
            FROM memory_embeddings
            WHERE 1 - (embedding <=> %s::vector) > %s
            ORDER BY embedding <=> %s::vector
            LIMIT %s
        """, (query_embedding, query_embedding, threshold, query_embedding, max_results))
        
        results = cur.fetchall()
        conn.close()
        
        # Apply token budget with tiered retrieval and dynamic limits
        memories = []
        tokens_used = 0
        result_count = len(results)  # Use actual result count for dynamic sizing
        
        for source_type, source_id, content, similarity in results:
            # Apply tiered truncation based on confidence AND result count
            truncated = truncate_content(content, similarity, result_count, high_confidence)
            entry_tokens = estimate_tokens(truncated) + 20  # +20 for formatting overhead
            
            # Check if we'd exceed budget
            if tokens_used + entry_tokens > token_budget:
                # Try to fit a shorter version if high-confidence
                if similarity >= high_confidence:
                    shorter = truncate_content(content, 0, result_count, high_confidence)  # Force summary
                    shorter_tokens = estimate_tokens(shorter) + 20
                    if tokens_used + shorter_tokens <= token_budget:
                        truncated = shorter
                        entry_tokens = shorter_tokens
                    else:
                        continue  # Skip this one
                else:
                    continue  # Skip - can't fit
            
            memories.append({
                "source": f"{source_type}/{source_id}",
                "content": truncated,
                "similarity": round(similarity, 3),
                "full": similarity >= high_confidence
            })
            tokens_used += entry_tokens
            
            # Stop if we've used most of the budget
            if tokens_used >= token_budget * 0.95:
                break
        
        return {
            "query": message,
            "memories": memories,
            "count": len(memories),
            "tokens_used": tokens_used,
            "token_budget": token_budget
        }
        
    except Exception as e:
        return {"error": str(e), "memories": []}

def format_for_injection(recall_result):
    """Format recall results for context injection."""
    if not recall_result.get("memories"):
        return ""
    
    lines = ["## Relevant Memories (auto-recalled)"]
    for mem in recall_result["memories"]:
        confidence = "🎯" if mem.get("full") else "📝"
        lines.append(f"- {confidence} [{mem['source']}] ({mem['similarity']:.0%}): {mem['content']}")
    
    return "\n".join(lines)

def main():
    parser = argparse.ArgumentParser(description="Proactive memory recall with semantic search")
    parser.add_argument("message", nargs="*", help="Message to search for")
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_TOKEN_BUDGET,
                        help=f"Maximum tokens to return (default: {DEFAULT_TOKEN_BUDGET})")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD,
                        help=f"Minimum similarity threshold (default: {DEFAULT_THRESHOLD})")
    parser.add_argument("--high-confidence", type=float, default=HIGH_CONFIDENCE_THRESHOLD,
                        help=f"Threshold for full content (default: {HIGH_CONFIDENCE_THRESHOLD})")
    parser.add_argument("--inject", action="store_true",
                        help="Output formatted for context injection")
    
    args = parser.parse_args()
    
    if not args.message:
        parser.print_help()
        sys.exit(1)
    
    message = " ".join(args.message)
    result = recall(
        message, 
        token_budget=args.max_tokens,
        threshold=args.threshold,
        high_confidence=args.high_confidence
    )
    
    if args.inject:
        print(format_for_injection(result))
    else:
        print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
