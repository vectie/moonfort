# Reuse retained JSON Lines diagnostics as CSV

Execution tools often write one JSON value per line (`.jsonl` or `.ndjson`).
`browse-retention jsonl-csv` turns these records into a complete CSV candidate,
with chosen nested fields and a physical source-line number for every row.
Unlike `json-csv`, it does not require wrapping the log in a JSON array first.
The retained artifact remains the original evidence.

## Choose the fields and export

Save a local `columns.json` mapping:

```json
{
  "version": 1,
  "columns": [
    {"header": "ID", "pointer": "/id"},
    {"header": "Status", "pointer": "/result/status"},
    {"header": "Duration", "pointer": "/result/duration"},
    {"header": "Owner", "pointer": "/owner"},
    {"header": "Note", "pointer": "/note"}
  ]
}
```

Use the existing executor configuration and exact five-field receipt binding
from the [artifact browser](RETAINED_ARTIFACT_BROWSER.md):

```sh
browse-retention jsonl-csv diagnostics.jsonl --mapping columns.json \
  < receipt-binding.json > new-candidate.csv 2> new-candidate.context.json
```

The first CSV field is always `__source_line`, a one-based physical line number
in the original file. The remaining fields follow the mapping order. Every
nonblank input line becomes one row; no records are filtered or truncated.
A final LF terminates the final record and does not create an extra blank line.
LF and CRLF are supported; the final record may have no newline.

Blank or whitespace-only lines are errors by default. To handle a log that
intentionally uses blank separators, add `--skip-blank-lines`. The context
records this choice, the skipped count, and the total physical line count.
Line numbers still include skipped lines. Only ASCII spaces, tabs and carriage
returns count as blank; malformed records are never silently skipped.

To reopen a record of interest, use the existing text browser with a literal
field/value fragment and a cursor immediately before its source line:

```sh
browse-retention search diagnostics.jsonl --query '"id":2' \
  --after-line 2 --limit 1 --json < receipt-binding.json
```

This example finds the original record on physical line 3. Check the returned
line and file fingerprint against the CSV/context. Text search returns bounded
excerpts, so use `export` when the full original record is needed.

## Mapping and scalar semantics

The mapping has exactly `version` (literal integer `1`) and `columns`; there is
no `rows` selector. Each column has exactly a unique nonempty `header` and a
JSON `pointer` relative to one complete source-line value. Select 1–63 fields;
`__source_line` is reserved, keeping the final CSV within 64 columns. Unknown
fields and duplicate decoded JSON keys are rejected.

JSON Pointer escaping and scalar rules match [JSON array projection](RETAINED_JSON_CSV.md):
`~1` means `/`, `~0` means `~`, and array positions use canonical zero-based
decimals. An empty pointer selects the entire record, useful for scalar logs.
Records can be objects, arrays or scalars. A missing object member and JSON
null produce a blank CSV cell, with separate aggregate counts in context.
Traversing a scalar, selecting an absent array position, or selecting a
container as a cell refuses the complete export. A record may not span physical
lines. JSON escaped newlines inside string values are preserved in CSV cells.

Numbers retain their exact source spellings, including large integers, trailing
zeros, exponents and negative zero. Unicode, whitespace, commas, quotes and
formula-like strings remain unchanged. All cells are quoted and records use
CRLF. CSV does not retain JSON types or distinguish missing/null/empty at the
cell level. Import precision-sensitive or untrusted data as text in spreadsheet
tools; formulas are neither evaluated nor neutralized here.

## Provenance and failure behavior

On success stdout is complete CSV; stderr is one JSON context record containing
source receipt binding, source fingerprint/size, exact local mapping digest,
ordered mapped columns, line/row/blank/missing/null counts, and candidate
fingerprint/size. Keep the CSV, context and mapping together. Repeating with the
same verified bytes and choices produces identical CSV and context.

The command validates all records and the completed candidate before emitting
CSV. A malformed later line cannot leave a valid-looking partial CSV or header.
Check the exit status: failure stderr is a diagnostic, not context. An output
I/O failure can still leave partial redirected files. Choose fresh output paths,
since shell redirection truncates destinations before invocation.

This creates a derived candidate, not an execution receipt, accepted artifact
or promotion. No workloads run, grants are consumed, original bytes are changed
or durable destinations are written. It reuses the existing retained binding,
lifetime and fingerprint checks; it is not an atomic filesystem snapshot.

## Bounds and API

- Retained source: at most 1 MiB, strict UTF-8, no BOM
- At most 20,000 physical lines, counting explicit skipped blanks
- At most 20,000 JSON values across all records, including containers, with
  at most 64 levels per record; duplicate decoded object keys refuse
- Local mapping: at most 64 KiB; pointers at most 4096 UTF-8 bytes
- Headers/cells: at most 16,384 UTF-16 units, without NUL
- Complete CSV: at most 1 MiB, including source-line column and final CRLF
- Context: must fit the configured protocol budget

`@executor.tabulate_retained_jsonl(binding, path, config, mapping_bytes,
skip_blank_lines=false)` returns `RetentionJsonLinesTable`. Its `csv` holds the
complete candidate and `context()` exposes provenance without the payload.
This is bounded local projection, not a streaming parser or unbounded log query.
