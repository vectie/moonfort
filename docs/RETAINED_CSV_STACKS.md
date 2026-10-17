# Consolidate retained CSV report shards

`browse-retention stack-csv` combines explicitly selected CSV artifacts from one
retained run into one reusable report. Use it when a bounded job writes one
report per partition, region, batch or test shard, and you need all its records
in one file. Every output row keeps a source path and logical data-row number.

This extends the existing inventory and table browser. It does not run a job,
change an original, consume a grant, extend retention or accept/promote a result.

## Inventory → select → combine → inspect an original

Use the existing operator-owned `MOONFORT_EXECUTOR_CONFIG` and actual receipt
binding from [the retained artifact browser](RETAINED_ARTIFACT_BROWSER.md):

```sh
browse-retention list --prefix logs/ --json < receipt-binding.json > inventory.json
browse-retention table logs/west.csv --json < receipt-binding.json
browse-retention table logs/east.csv --json < receipt-binding.json
```

Choose 2–32 files and copy their exact paths and SHA-256 fingerprints from the
inventory into a local manifest. This example's fingerprints are placeholders:

```json
{
  "version": 1,
  "files": [
    {"path": "logs/west.csv", "fingerprint": "COPY_WEST_SHA256_FROM_INVENTORY"},
    {"path": "logs/east.csv", "fingerprint": "COPY_EAST_SHA256_FROM_INVENTORY"}
  ]
}
```

There is no wildcard or automatic inclusion of future files. Each path must be
unique and relative, without empty, dot or parent components or backslashes.
The manifest rejects unknown/duplicate fields and noncanonical version values.
The actual source bytes must still match the selected fingerprints.

```sh
browse-retention stack-csv --manifest combine.json \
  < receipt-binding.json > new-combined.csv 2> new-combined.context.json
```

The first two output columns are `__source_path` and `__source_row`, followed by
the original columns. For example:

```csv
"__source_path","__source_row","id","area","seconds","note"
"logs/west.csv","1","01","docs","2.5","review, then fix"
"logs/east.csv","1","01","docs","3.25","=A1"
```

To inspect the original behind the second row, use its path and one less than
its `__source_row` as `--after-row`. Rows are one-based logical data records;
the header and embedded newlines do not increment data-row numbers:

```sh
browse-retention table logs/east.csv --after-row 0 --limit 1 --json \
  < receipt-binding.json
```

Open the combined CSV with an ordinary CSV-aware data tool. Numeric measurement
columns remain exact strings, ready for an explicitly chosen aggregation. The
compiled journey tests reopen the actual saved output and reuse Fort's existing
internal numeric aggregation engine to sum `seconds` by `area` across shards.
The `aggregate-csv`, `table`, and `compare-retained-csv` CLIs still require real
retained artifacts; this command does not import a candidate or fabricate a new
retention record. Source locators always refer to the original receipt.

## Data contract

- Ordered headers must match exactly across every selected file, including a
  header-only shard. Reordered, renamed, missing, extra or whitespace-different
  columns refuse. The native API identifies the affected source path; the CLI
  retains its existing generic refusal diagnostic. Inspect each source with
  `table` when resolving a schema mismatch. No schema mapping is inferred.
- Between 1 and 62 source columns, so the candidate fits the existing 64-column
  parser. Blank/duplicate headers are preserved, except the two generated
  locator names are reserved and refuse if present in the original headers.
- Manifest file order, then original row order. No sorting, joining, automatic
  key detection or deduplication. Repeated IDs/rows across shards remain separate
  observations with distinct source locators. Users choose whether combining
  those observations is appropriate for their analysis.
- Header-only shards contribute zero rows and still appear in context. All
  header-only shards produce a header-only candidate. A zero-byte file is not a
  valid header-only CSV and refuses.
- Strict UTF-8 CSV with an optional initial BOM, comma separators, quoted cells,
  doubled quote escapes, LF/CRLF/CR record endings, and consistent row widths.
  Exact strings, whitespace, leading zeros, Unicode and embedded newlines are
  preserved. Output is fully quoted CRLF CSV without BOM. No formulas are
  executed, converted or neutralized; import untrusted CSV as text in spreadsheets.

## Bounds, context and failure

Each source is at most 1 MiB; all selected source bytes together at most 4 MiB.
The complete candidate is at most 1 MiB and 20,000 data rows. Each original cell
is at most 16,384 UTF-16 units. The manifest is at most 64 KiB. Existing receipt,
expiry, configuration, path, disk, fingerprint and protocol budgets still apply.
Source bytes are reverified and parsed, and the saved record is checked again
before returning. This is not an atomic multi-file filesystem snapshot.

Success writes complete CSV to stdout and one JSON context to stderr. Context
includes the original binding, every source fingerprint and row count, exact
manifest size/SHA-256 and exact candidate size/SHA-256. Keep the manifest, CSV
and context together. Context is local derivation metadata, not a signature,
new execution receipt, permission or acceptance.

A missing, expired, changed, malformed or incompatible selected source refuses
the complete export; no best-effort omission or partial CSV is emitted on a
validation error. Output I/O failures may still leave partial files. Use new
filenames because shell redirection truncates before execution; check exit status
before treating stderr as context. When a result exceeds these bounds, use the
existing verified raw export and a separate data tool.

## Native API and portable example

`stack_retained_csv(binding, config, manifest_bytes) -> RetentionCsvStack` returns
the CSV and typed source metadata. `result.context()` excludes cell contents
and local filesystem paths. Its public types round-trip through JSON.

The self-contained source examples under `examples/csv-stack/` contain synthetic
shards and their exact manifest, with no receipt or configuration secrets. They
demonstrate the portable data contract; copying them does not create an active
retained run. The native test `executor/retention_csv_stack_wbtest.mbt` creates
fresh synthetic retained evidence, invokes the compiled CLI for inventory,
consolidation and source-row drillback, and reopens the saved candidate. Set
`MOONFORT_ARTIFACT_READER_CLI` to the native executable and optionally
`MOONFORT_CSV_STACK_EVIDENCE` to an existing private directory for actual outputs.

These bounded tests do not qualify execution containment, production arbitrary
code, AEN/microVM deployments, reviewed promotion, MoonBook acceptance, installed
lifecycle or live host/browser integration. Broader release gates remain open.
