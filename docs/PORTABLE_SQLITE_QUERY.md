# Query a retained SQLite copy

Use custom SQL when a question needs a join or a derived column beyond the
existing row, group, histogram and crosstab commands. This uses the same verified
retained ZIP reader and in-memory read-only connection, not a live database.

First inspect the retained schema and copy the exact database fingerprint from
`source.source_file.fingerprint`:

```sh
python3 -B tools/sqlite_review.py review.zip --database results/samples.sqlite schema
```

Write a UTF-8 file `question.sql`, using ordinary stored columns and explicit
ordering when it matters:

```sql
SELECT o.name, s.id, s.score * ? AS weighted,
       CASE WHEN s.note IS NULL THEN ? ELSE s.note END AS note
FROM samples AS s JOIN owners AS o ON o.id = s.owner_id
WHERE o.name = ?
ORDER BY s.id;
```

Write `parameters.json` with the current fingerprint and positional typed values:

```json
{
  "database_sha256": "REPLACE_WITH_EXACT_RETAINED_DATABASE_SHA256",
  "parameters": [
    {"type": "real", "value": "2.0"},
    {"type": "text", "value": "missing"},
    {"type": "text", "value": "月"}
  ]
}
```

```sh
python3 -B tools/sqlite_review.py review.zip --database results/samples.sqlite query --sql question.sql --parameters parameters.json --max-rows 1000
python3 -B tools/sqlite_review.py review.zip --database results/samples.sqlite query --sql question.sql --parameters parameters.json --format csv
```

Use `?` placeholders; parameters are bound as data and never interpolated.
Even a query with no placeholders requires the fingerprint file and an empty
`parameters` array. Null uses JSON null. Text, canonical base64 BLOB, signed
64-bit integer and finite real use strings, matching the existing typed filters.
SQLite's normal expression and affinity semantics apply to SQL; use `typeof`
and explicit predicates when exact storage-class distinctions matter.

## Result and limits

JSON preserves columns by position, including duplicate/empty labels, and rows
as arrays of typed cells. CSV includes position-qualified column headings and
JSON-encoded typed cells, preserving NULL, BLOB, Unicode, multiline strings and
64-bit integers. It is a typed interchange CSV, not a plain presentation grid.
The context on stderr binds result bytes, retained ZIP/manifest/database bytes,
exact SQL bytes and parameter-file bytes by SHA-256. JSON includes that same
source/query context, except the result-byte fingerprint is only on stderr.

Only one statement returning a result set is accepted. There is no automatic
pagination or truncation. Default maximum is 1000 rows, configurable from 1 to
10000. Exceeding it refuses the entire output. SQL `LIMIT` intentionally defines
the requested result and does not certify that all matching source rows were
returned. No order is guaranteed without SQL `ORDER BY`. Derived/joined rows do
not acquire fabricated source row locators; select original keys explicitly
when needed.

The retained database remains at most 1 MiB; SQL and parameter files each at
most 64 KiB; at most 128 parameters and 256 result columns; at most 16 MiB typed
projection and encoded output. The existing SQLite length bound and roughly
5-million-instruction progress budget apply. Bounds, malformed SQL, binding
errors, nonfinite results and stale fingerprints produce an error with empty
stdout. No partial successful result is emitted.

## Unchanged boundary

Only direct reads of listed ordinary main-table stored columns are allowed.
Joins, arithmetic, CASE, comparisons, EXISTS, and the small function set
`typeof`, `instr`, `count`, `sum`, `avg`, `min`, `max`, `coalesce` are supported.
Views, virtual/shadow/schema tables, generated columns and indirect CTE-origin
reads are refused. Recursive CTEs are refused. Unsupported functions fail
instead of expanding access. PRAGMA, writes, schema changes, transactions,
ATTACH, extension loading and external-file functions are denied by the shared
authorizer. Query-only mode, untrusted-schema mode, memory-only temp storage,
disabled extensions and existing SQLite limits remain enabled.

No artifact is extracted, no source-side WAL/journal is opened, and no source
bytes change. This does not authenticate the archive, authorize execution or
promotion, demonstrate sandbox containment, or qualify a host/full release.
All previously blocked release requirements remain blocked.

Tests: `python3 -B scripts/test-sqlite-query.py -v`. Set
`MOONFORT_QUERY_EVIDENCE` to a fresh directory to retain the synthetic SQLite
databases, real review ZIPs, SQL, typed parameters, commands and full outputs.
