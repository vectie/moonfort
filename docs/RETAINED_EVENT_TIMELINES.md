# Correlate retained JSONL events on one timeline

`browse-retention timeline` merges explicitly selected JSONL/NDJSON artifacts
from one retained run into chronological CSV. This helps reconstruct a sequence
split across worker, build, or diagnostic logs, including files whose own events
arrived out of order. Every event keeps its original retained path and physical
line, so an interesting transition can be reopened in the existing browser.

## Select logs and fields

Save this local `timeline.json`:

```json
{
  "version": 1,
  "files": ["logs/worker.jsonl", "logs/build.jsonl"],
  "timestamp": "/at",
  "columns": [
    {"header": "Event", "pointer": "/event"},
    {"header": "Detail", "pointer": "/detail"}
  ]
}
```

With the existing trusted executor configuration and exact original receipt
binding, export to fresh files:

```sh
browse-retention timeline --mapping timeline.json \
  < receipt-binding.json > new-timeline.csv 2> new-timeline.context.json
```

For intentionally blank separators, explicitly add `--skip-blank-lines`.
The first three CSV columns are `__source_path`, `__source_line`, `__timestamp`;
the rest follow the mapping. All nonblank records are included, without a
page limit, deduplication, or dropped ties. Source lines are one-based physical
lines, including skipped blanks. A final LF does not add a blank line.

For an event on physical line 4 in `logs/worker.jsonl`, reopen it by searching
an exact identifying fragment with the cursor just before that line:

```sh
browse-retention search logs/worker.jsonl --query '"event":"retry"' \
  --after-line 3 --limit 1 --json < receipt-binding.json
```

Check returned line and file fingerprint against the timeline context. Search
returns bounded excerpts; `export` retrieves the complete original bytes.

## Time and ordering

The timestamp pointer must select a present JSON string in every event, in the
exact format `YYYY-MM-DDTHH:mm:ss.SSSZ`. Years 0001–9999 and Gregorian calendar
dates are checked, including century leap-year rules. Hours are 00–23, minutes
and seconds 00–59. Exactly three millisecond digits and uppercase T/Z are
required. Missing/null/numeric timestamps, timezone offsets, local times,
leap seconds, omitted milliseconds, and invalid dates refuse the complete
export. Normalize other timestamp representations upstream; no time zone or
unit is guessed.

Events sort ascending by timestamp, then lexical retained path, then physical
source line. Original file order need not be chronological. Equal timestamps
remain separate records; path/line tie breaking is deterministic and does not
claim causal order. The tool does not correct skew between source clocks.
Empty selected files contribute provenance but no events. An all-empty
selection exports only headers with empty first/last timestamps in context.

## Mapping and scalar values

The mapping has exactly `version` (literal integer 1), `files`, `timestamp`, and
`columns`. Choose 1–32 distinct exact retained paths; patterns are not expanded.
Every named file must exist in the saved reviewable inventory. A missing,
changed, malformed, or oversized selected file refuses the entire export;
unselected artifacts do not enter the timeline.

Use 1–61 uniquely named scalar columns. The three generated headers are reserved.
Pointers use the same JSON Pointer rules as [JSON projection](RETAINED_JSON_CSV.md),
including `~1` for slash, `~0` for tilde, and canonical zero-based array positions.
The same timestamp and field mapping applies to all selected files. Unknown
mapping fields, duplicate decoded JSON keys, and invalid pointers refuse.

Mapped numbers retain their original spellings, including large integers,
trailing zeros, exponents and negative zero. Strings, Unicode, embedded newlines,
quotes, and formula-looking values are preserved. Missing object fields and
JSON null become blank cells, counted separately in context. Invalid traversal,
absent array positions, or container-valued cells refuse. CSV does not preserve
JSON types or distinguish missing/null/empty per cell. Import sensitive numeric
spellings and untrusted spreadsheet values as text.

## Provenance, limits, and failures

Success writes a complete quoted CRLF CSV to stdout and a single context JSON
record to stderr. Keep the mapping, CSV, and context together. Context includes:

- Original receipt binding and every selected source fingerprint/size
- Per-file physical-line, event, and explicitly skipped-blank counts
- Exact mapping digest, timestamp pointer, mapped columns, and ordering contract
- Overall event/line/blank/missing/null counts and first/last timestamps
- Exact candidate SHA-256 and byte size

Unchanged source bytes, binding, mapping and options produce identical outputs.
Reordering the mapping's files array keeps CSV order unchanged but changes the
mapping digest. Context is derivation metadata, not a new execution receipt,
accepted artifact, signature, or promotion authority. No payload is executed,
grant consumed, source changed, or durable file promoted.

All selected sources validate and the complete candidate is prepared before CSV
emission. A late error produces no partial CSV or header. Check exit status:
output I/O failure can still leave partial files, and stderr on failure is a
diagnostic rather than success context. Use fresh destinations because shell
redirection truncates files before the command starts. The existing retained
binding, lifetime, saved-record, and fingerprint checks apply; sequential reads
and the final saved-record recheck are not an atomic filesystem snapshot.

Bounds:

- Local mapping: 64 KiB; 1–32 distinct files
- Each source: 1 MiB; all selected source sizes combined: 4 MiB
- 20,000 physical lines and 20,000 JSON values across the entire selection,
  including containers; at most 64 nesting levels per record
- 1–61 mapped columns; headers/cells at most 16,384 UTF-16 units and no NUL
- Completed CSV: 1 MiB; context must fit the executor protocol budget

Native API: `merge_retained_timeline(binding, config, mapping_bytes,
skip_blank_lines=false) -> RetentionTimeline`; `csv` holds the candidate and
`context()` its provenance. This is bounded correlation of already retained
logs, not live streaming, cross-run comparison, causal tracing, execution, or
production containment qualification.
