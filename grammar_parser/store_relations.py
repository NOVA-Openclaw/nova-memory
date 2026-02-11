#!/usr/bin/env python3
"""
Store relations in memory database.
Reads JSON from stdin, writes to entity_facts and entity_relationships.

Usage:
    extract_cli.py "message" | store_relations.py
"""

import sys
import json
import os
import subprocess
from typing import List, Dict, Optional


def sql_escape(text: str) -> str:
    """Escape single quotes for SQL."""
    return text.replace("'", "''")


def run_sql(sql: str, db_user: str, db_name: str) -> Optional[str]:
    """Execute SQL and return result."""
    try:
        result = subprocess.run(
            ["psql", "-h", "localhost", "-U", db_user, "-d", db_name, "-t", "-A", "-c", sql],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            print(f"SQL error: {result.stderr}", file=sys.stderr)
            return None
    except Exception as e:
        print(f"Error running SQL: {e}", file=sys.stderr)
        return None


def find_entity(name: str, db_user: str, db_name: str) -> Optional[str]:
    """Find existing entity by name or nickname."""
    sql = f"""
        SELECT name FROM entities 
        WHERE LOWER(name) = LOWER('{sql_escape(name)}')
           OR LOWER(full_name) = LOWER('{sql_escape(name)}')
           OR LOWER('{sql_escape(name)}') = ANY(SELECT LOWER(unnest(nicknames)))
        LIMIT 1;
    """
    return run_sql(sql, db_user, db_name)


def ensure_entity_exists(name: str, entity_type: str, db_user: str, db_name: str):
    """Create entity if it doesn't exist."""
    existing = find_entity(name, db_user, db_name)
    if not existing:
        sql = f"INSERT INTO entities (name, type) VALUES ('{sql_escape(name)}', '{entity_type}') ON CONFLICT DO NOTHING;"
        run_sql(sql, db_user, db_name)


def fact_exists(entity_name: str, key: str, value: str, db_user: str, db_name: str) -> bool:
    """Check if a fact already exists (fuzzy match)."""
    sql = f"""
        SELECT COUNT(*) FROM entity_facts ef
        JOIN entities e ON e.id = ef.entity_id
        WHERE (LOWER(e.name) = LOWER('{sql_escape(entity_name)}')
               OR LOWER(e.full_name) = LOWER('{sql_escape(entity_name)}')
               OR LOWER('{sql_escape(entity_name)}') = ANY(SELECT LOWER(unnest(e.nicknames))))
          AND LOWER(ef.key) = LOWER('{sql_escape(key)}')
          AND (LOWER(ef.value) = LOWER('{sql_escape(value)}')
               OR ef.value ILIKE '%{sql_escape(value)}%'
               OR '{sql_escape(value)}' ILIKE '%' || ef.value || '%');
    """
    result = run_sql(sql, db_user, db_name)
    return result and int(result) > 0


def store_relation(relation: Dict, db_user: str, db_name: str, source_person: str = "grammar-parser"):
    """
    Store a single relation in the database.
    """
    
    rel_type = relation["relation_type"]
    subject = relation["subject"]
    obj = relation.get("object", "")
    predicate = relation["predicate"]
    confidence = relation["confidence"]
    
    # Skip low-confidence relations
    if confidence < 0.6:
        print(f"  ~ Skipping low-confidence: {subject} --{predicate}--> {obj} (confidence: {confidence:.2f})", file=sys.stderr)
        return
    
    # Ensure subject entity exists
    ensure_entity_exists(subject, "person", db_user, db_name)
    
    # Ensure object entity exists for relationship types
    if obj and rel_type in ["family", "romantic", "social", "professional"]:
        ensure_entity_exists(obj, "person", db_user, db_name)
    
    # Map relation types to database storage
    
    if rel_type in ["family", "romantic", "social", "professional"]:
        # Store in entity_relationships table
        is_symmetric = relation.get("is_symmetric", False)
        subtype = relation.get("subtype", predicate)
        
        # Check if relationship already exists
        sql = f"""
            SELECT COUNT(*) FROM entity_relationships er
            JOIN entities e1 ON er.entity_a = e1.id
            JOIN entities e2 ON er.entity_b = e2.id
            WHERE (LOWER(e1.name) = LOWER('{sql_escape(subject)}') 
                   AND LOWER(e2.name) = LOWER('{sql_escape(obj)}'))
               OR ('{is_symmetric}' = 'True' AND LOWER(e1.name) = LOWER('{sql_escape(obj)}') 
                   AND LOWER(e2.name) = LOWER('{sql_escape(subject)}'));
        """
        result = run_sql(sql, db_user, db_name)
        
        if result and int(result) > 0:
            print(f"  ~ Relationship (duplicate, skipped): {subject} --{subtype}--> {obj}", file=sys.stderr)
        else:
            # Insert relationship
            sql = f"""
                INSERT INTO entity_relationships (entity_a, entity_b, relationship, is_symmetric, source)
                SELECT e1.id, e2.id, '{sql_escape(subtype)}', {is_symmetric}, '{sql_escape(source_person)}'
                FROM entities e1, entities e2
                WHERE LOWER(e1.name) = LOWER('{sql_escape(subject)}')
                  AND LOWER(e2.name) = LOWER('{sql_escape(obj)}')
                ON CONFLICT DO NOTHING;
            """
            run_sql(sql, db_user, db_name)
            print(f"  + Relationship: {subject} --{subtype}--> {obj} (confidence: {confidence:.2f})", file=sys.stderr)
    
    elif rel_type in ["attribute", "preference", "opinion"]:
        # Store in entity_facts table
        key = predicate if rel_type == "attribute" else f"{rel_type}_{predicate}"
        
        # Check for duplicate
        if fact_exists(subject, key, obj, db_user, db_name):
            print(f"  ~ Fact (duplicate, skipped): {subject}.{key} = {obj}", file=sys.stderr)
        else:
            sql = f"""
                INSERT INTO entity_facts (entity_id, key, value, source, visibility)
                SELECT id, '{sql_escape(key)}', '{sql_escape(obj)}', '{sql_escape(source_person)}', 'public'
                FROM entities WHERE LOWER(name) = LOWER('{sql_escape(subject)}')
                ON CONFLICT DO NOTHING;
            """
            run_sql(sql, db_user, db_name)
            print(f"  + Fact: {subject}.{key} = {obj} (confidence: {confidence:.2f})", file=sys.stderr)
    
    elif rel_type in ["location", "residence", "origin"]:
        # Store as entity fact (location)
        key = rel_type
        
        if fact_exists(subject, key, obj, db_user, db_name):
            print(f"  ~ Location (duplicate, skipped): {subject} @ {obj}", file=sys.stderr)
        else:
            sql = f"""
                INSERT INTO entity_facts (entity_id, key, value, source, visibility)
                SELECT id, '{sql_escape(key)}', '{sql_escape(obj)}', '{sql_escape(source_person)}', 'public'
                FROM entities WHERE LOWER(name) = LOWER('{sql_escape(subject)}')
                ON CONFLICT DO NOTHING;
            """
            run_sql(sql, db_user, db_name)
            print(f"  + Location: {subject} @ {obj} (confidence: {confidence:.2f})", file=sys.stderr)
    
    elif rel_type in ["employment", "education"]:
        # Store as entity fact
        key = rel_type
        
        if fact_exists(subject, key, obj, db_user, db_name):
            print(f"  ~ {rel_type.title()} (duplicate, skipped): {subject} @ {obj}", file=sys.stderr)
        else:
            sql = f"""
                INSERT INTO entity_facts (entity_id, key, value, source, visibility)
                SELECT id, '{sql_escape(key)}', '{sql_escape(obj)}', '{sql_escape(source_person)}', 'public'
                FROM entities WHERE LOWER(name) = LOWER('{sql_escape(subject)}')
                ON CONFLICT DO NOTHING;
            """
            run_sql(sql, db_user, db_name)
            print(f"  + {rel_type.title()}: {subject} @ {obj} (confidence: {confidence:.2f})", file=sys.stderr)
    
    elif rel_type == "possession":
        key = "owns"
        
        if fact_exists(subject, key, obj, db_user, db_name):
            print(f"  ~ Possession (duplicate, skipped): {subject} owns {obj}", file=sys.stderr)
        else:
            sql = f"""
                INSERT INTO entity_facts (entity_id, key, value, source, visibility)
                SELECT id, '{sql_escape(key)}', '{sql_escape(obj)}', '{sql_escape(source_person)}', 'public'
                FROM entities WHERE LOWER(name) = LOWER('{sql_escape(subject)}')
                ON CONFLICT DO NOTHING;
            """
            run_sql(sql, db_user, db_name)
            print(f"  + Possession: {subject} owns {obj} (confidence: {confidence:.2f})", file=sys.stderr)
    
    else:
        # Generic storage as fact
        key = f"other_{predicate}"
        
        if not fact_exists(subject, key, obj, db_user, db_name):
            sql = f"""
                INSERT INTO entity_facts (entity_id, key, value, source, visibility)
                SELECT id, '{sql_escape(key)}', '{sql_escape(obj)}', '{sql_escape(source_person)}', 'public'
                FROM entities WHERE LOWER(name) = LOWER('{sql_escape(subject)}')
                ON CONFLICT DO NOTHING;
            """
            run_sql(sql, db_user, db_name)
            print(f"  + Other: {subject} --{predicate}--> {obj} (confidence: {confidence:.2f})", file=sys.stderr)


def main():
    # Database configuration
    db_user = os.environ.get("PGUSER", os.environ.get("USER", "nova"))
    db_name = f"{db_user.replace('-', '_')}_memory"
    source_person = os.environ.get("SENDER_NAME", "grammar-parser")
    
    # Read JSON from stdin
    try:
        input_json = sys.stdin.read()
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        sys.exit(1)
    
    if not input_json.strip():
        print("No relations to store", file=sys.stderr)
        sys.exit(0)
    
    try:
        relations = json.loads(input_json)
    except json.JSONDecodeError as e:
        print(f"Invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)
    
    if not isinstance(relations, list):
        print("Expected JSON array of relations", file=sys.stderr)
        sys.exit(1)
    
    # Store each relation
    stored_count = 0
    for rel in relations:
        try:
            store_relation(rel, db_user, db_name, source_person)
            stored_count += 1
        except Exception as e:
            print(f"Error storing relation: {e}", file=sys.stderr)
    
    print(f"Grammar parser stored {stored_count}/{len(relations)} relation(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
