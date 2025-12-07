---
id: create-yaml-from-jsonl
title: Create YAML from JSONL (SQL-focused)
description: |
  Instruction prompt to transform a JSONL file containing SQL into a YAML sequence. 
  Each YAML item should include a pretty-printed SQL block, metadata about the database and placeholders,
  and a list of bind values where certain tokens are replaced with parameter placeholders (?).
author: MSlo1963
model: gpt-4o
temperature: 0.0
tags:
  - yaml
  - jsonl
  - sql
  - placeholders
created_at: 2025-12-07
modified_at: 2025-12-07
version: 1.0
---

# Prompt

You are given a JSONL file where each record contains (at least) an id and a SQL string. Your task is to produce a YAML file following these rules.

YAML structure:
- Top-level is a sequence of items, each with:
  - id: name
  - sql: a multiline (|) block containing the pretty-printed SQL
  - meta: nested mapping
    - meta.db: "rep"
    - meta.placeholders: a mapping of placeholder names to their token values
      - If the sql has __ENTITY__ create placeholder -ENTITY: BR
    - meta.bind_values: an array list of __<text>__ items which are not types as placeholder, replace for those the original __<text>__ by ?

Rules and details:
1. Parse each JSONL record and extract the SQL string and id (use the JSONL id field as the YAML `id`).
2. Pretty-print the SQL and put it into the `sql` field as a multiline block using `|`.
3. Always set `meta.db` to the literal string "rep".
4. Build `meta.placeholders`:
   - For any token in the SQL matching the pattern `__ENTITY__`, add an entry in `meta.placeholders` with key `-ENTITY` and value `BR`.
   - (General rule) Map any other placeholder-like tokens you want to persist as mappings in `meta.placeholders`.
5. Build `meta.bind_values`:
   - Find tokens in the SQL that match the pattern `__<text>__`.
   - If the token represents a typed placeholder (e.g., `__INT__`, `__STRING__`) treat it as a placeholder type and do NOT add it to `meta.bind_values`.
   - For tokens that are not types (i.e., actual values or non-type markers), add the original token string (including the double underscores) to `meta.bind_values` in the order they appear.
   - Replace those non-type `__<text>__` tokens in the pretty-printed SQL with `?` (question mark) so that the `sql` field shows parameterized SQL.
6. The resulting YAML must be a valid YAML sequence where each item adheres exactly to the structure above.

Example (illustrative, not exhaustive):

Input JSONL line (one JSON object per line):
```json
{"id":"example-1", "sql":"SELECT * FROM users WHERE tenant = __TENANT__ AND status = __ACTIVE__ AND entity = '__ENTITY__'"}
```

Corresponding YAML item (illustrative):
```yaml
- id: example-1
  sql: |
    SELECT
      *
    FROM
      users
    WHERE
      tenant = ?
      AND status = ?
      AND entity = ?
  meta:
    db: "rep"
    placeholders:
      -ENTITY: BR
      # (other placeholder mappings as applicable)
    bind_values:
      - "__TENANT__"
      - "__ACTIVE__"
      - "__ENTITY__"
```

Notes:
- Pretty-printing should aim for readable SQL with indentation and line breaks (e.g., SELECT on its own line, FROM on its own line, WHERE clauses split).
- Preserve the original order of bind tokens when populating `meta.bind_values`.
- Only replace non-type `__<text>__` tokens with `?` in the `sql` block; typed placeholders (recognized token names that indicate type) remain as-is and are not added to `meta.bind_values`.
- If there are multiple occurrences of the same non-type token, include each occurrence in `meta.bind_values` where appropriate (i.e., duplicates allowed if they appear multiple times in the SQL).

Deliverable:
- Output a single YAML document (sequence) following the structure above, with one YAML item per JSONL record processed.
