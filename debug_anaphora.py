#!/usr/bin/env python3
"""Debug script to test anaphora resolution."""

import sys
sys.path.insert(0, "grammar_parser")

from grammar_parser import GrammarParser

parser = GrammarParser()

text = "I met Sarah yesterday. She works at Google."
print(f"Input: {text}\n")

# Parse with multi-sentence
relations = parser.parse_multi_sentence(text)

print(f"Found {len(relations)} relation(s):\n")
for i, rel in enumerate(relations, 1):
    print(f"{i}. {rel.subject} --[{rel.predicate}]--> {rel.object}")
    print(f"   Type: {rel.relation_type.value}")
    print(f"   Confidence: {rel.confidence:.2f}\n")

# Let's also test the resolver directly
from anaphora_resolver import AnaphoraResolver

resolver = AnaphoraResolver(nlp=parser.nlp)
doc = parser.nlp(text)

print("\n=== Entity Extraction ===")
for sent_idx, sent in enumerate(doc.sents):
    resolver.current_sentence_index = sent_idx
    entities = resolver.extract_entities_from_doc(sent)
    print(f"Sentence {sent_idx}: {sent.text}")
    print(f"  Entities: {entities}")
    print(f"  Entity stack: {[(e.name, e.gender) for e in resolver.entity_stack]}")

print("\n=== Pronoun Resolution ===")
resolver.current_sentence_index = 0
for sent in doc.sents:
    print(f"Sentence: {sent.text}")
    for token in sent:
        if token.lower_ in {"she", "he", "her", "his", "they"}:
            resolved = resolver.resolve(token.lower_)
            print(f"  {token.text} -> {resolved}")
    resolver.next_sentence()

# Let's also check POS tags and dependencies
print("\n=== Token Analysis ===")
doc = parser.nlp("I met Sarah yesterday.")
for token in doc:
    print(f"{token.text:15} POS={token.pos_:8} TAG={token.tag_:6} DEP={token.dep_:10} ENT={token.ent_type_}")
