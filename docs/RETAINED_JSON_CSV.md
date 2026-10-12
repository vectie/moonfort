# Turn a retained JSON report into CSV

A report often contains an array of checks, measurements or generated results
nested inside JSON. `browse-retention json-csv` projects that array into named
CSV columns for a spreadsheet or another local data tool. Use the existing
`json` command to inspect the report and find the array and field pointers first.

## Map the columns once, then export

Save this local mapping as `columns.json`:

```json
{
  "version": 1,
  "rows": "/checks",
  "columns": [
    {"header": "ID", "pointer": "/id"},
    {"header": "Status", "pointer": "/result/status"},
    {"header": "Duration", "pointer": "/result/duration"},
    {"header": "Owner", "pointer": "/owner"},
    {"header": "Note", "pointer": "/note"}
  ]
}
```

Use the existing executor configuration and exact receipt binding from the
[artifact browser](RETAINED_ARTIFACT_BROWSER.md):

```sh
browse-retention json report.json --pointer /checks < receipt-binding.json
browse-retention json-csv report.json --mapping columns.json \
  < receipt-binding.json > new-candidate.csv 2> new-candidate.context.json
```

On success stdout contains only CSV. Stderr contains one JSON context record
with the receipt binding, original file size/hash, mapping hash, rows pointer,
ordered columns, row count, missing/null cell counts and candidate size/hash.
Keep the exact mapping, CSV and context together. The hashes describe a local
projection; they do not create a new execution receipt or approve an artifact.

Choose fresh output paths. Shell redirection creates or truncates them before
the command runs. Check exit status: failure stderr is a diagnostic, not a
context record; output I/O failure may leave partial files. Validation completes
before any CSV is emitted. This command does not launch workloads, consume
grants, change retained originals or promote files.

## Mapping and value rules

- `version` must be the literal integer `1`; `rows` selects an array. Empty
  `rows` selects a top-level array. All elements become rows in original order.
  An empty array produces the header record only.
- `columns` is an ordered list of 1–64 objects with exactly `header` and
  `pointer`. Headers must be nonempty and unique (exact, case-sensitive).
  Unknown fields and duplicate JSON keys are rejected.
- Each column pointer is relative to one array element. An empty pointer
  selects that entire element, which is useful for an array of scalar values.
  Nested object fields and array positions are supported; no automatic
  flattening, wildcard expansion, filtering or numeric computation is performed.
- JSON Pointer uses `/` separators, `~1` for `/` inside a key and `~0` for `~`.
  `/` selects an empty object key. Array indices are zero-based canonical
  decimals: `0` is valid, `01`, `-`, and out-of-range positions are errors.
- A missing object member gives a blank cell, including when an intermediate
  object member is missing. JSON `null` also gives a blank cell. Missing and
  null counts are separate in context, but their row-level distinction and
  distinction from an empty string require the retained JSON source.
- Traversing a scalar (including null) or selecting an object/array as a cell
  fails the export. Select its scalar children explicitly instead.
- Strings preserve Unicode, whitespace, commas, quotes and embedded newlines.
  Numbers retain exact source tokens, including large integers, trailing zeros,
  exponent spelling and negative zero. Booleans become `true` or `false`.
  CSV itself has no value types; import ID/precision-sensitive columns as text
  in downstream tools. Spreadsheet formulas are not neutralized or evaluated;
  inspect untrusted values and use the destination's safe text-import options.
- Every cell is quoted, inner quotes are doubled, records use CRLF, and the
  last record ends with CRLF. Candidate size/hash include that final CRLF.

## Limits and native API

The local mapping is a regular UTF-8 JSON file of at most 64 KiB. The retained
source is at most 1 MiB with the existing JSON reader's 64-container depth,
20,000-value and duplicate-key restrictions. Each pointer is at most 4096 UTF-8
bytes. Header/cell strings are at most 16,384 UTF-16 units and cannot contain
NUL. The completed CSV is at most 1 MiB. Source and mapping decode strictly;
no BOM or malformed UTF-8 input is accepted. Existing retention lifetime,
binding and file-fingerprint checks apply. Context, including selected column
metadata, must fit the configured protocol budget. No partial valid-looking
CSV is returned when these limits fail.

`@executor.tabulate_retained_json(binding, path, config, mapping_bytes)` returns
`RetentionJsonTable`: `csv`, candidate hash/size, source file and binding,
mapping hash, pointer, columns and counts. `result.context()` exports provenance
without the CSV payload. Source and local mapping bytes are not mutated.

This is one-way scalar projection for reuse. It does not promise a lossless
JSON round-trip or a spreadsheet's numeric/formula interpretation. Review and
promotion remain separate existing workflows.
