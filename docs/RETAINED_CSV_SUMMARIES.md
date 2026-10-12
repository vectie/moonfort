# Summarize repeated rows in a retained CSV report

`browse-retention summarize-csv` condenses a verified report into exact-key
frequency groups. Find the most common failing component/status combinations,
count checks by owner, or inspect repeated labels without paging through every
original row. Export a complete CSV summary, keep its separate provenance, and
use the first original row in each group to reopen an example with `table`.

This is derived exploration of retained execution output. It never changes the
source artifact or its receipt, executes a workload, consumes an approval,
promotes files, or establishes acceptance or stronger containment.

## End-to-end example

Use the existing trusted `MOONFORT_EXECUTOR_CONFIG` and actual five-field receipt
binding described in [the retained browser guide](RETAINED_ARTIFACT_BROWSER.md).
Run the compiled command rather than `moon run`, so build diagnostics cannot mix
with the context record.

```sh
browse-retention table checks.csv --limit 5 < receipt-binding.json
browse-retention summarize-csv checks.csv --group-by 2,3 \
  --where-column 3 --equals error \
  < receipt-binding.json > new-summary.csv 2> new-summary.context.json
```

If columns 2/3 are `area`/`status`, the candidate might contain:

```csv
"area","status","row_count","first_source_row"
"docs","error","2","2"
"ui","error","1","4"
"core","error","1","5"
"","error","1","7"
```

The first `docs/error` example is original data row 2, so reopen it with an
exclusive cursor of 1 (one less than `first_source_row`):

```sh
browse-retention table checks.csv --after-row 1 --limit 1 --json < receipt-binding.json
```

Row numbers count logical CSV data records, excluding the header. Newlines inside
quoted fields do not change them. Reopen against the same original binding and
path; positions refer to that source, not to the summary's ranking or filtered
row numbers. To count every row by area without filtering:

```sh
browse-retention summarize-csv checks.csv --group-by 2 \
  < receipt-binding.json > new-areas.csv 2> new-areas.context.json
```

## Semantics

- `--group-by` is required: 1–62 distinct one-based source column numbers, in the
  desired output order. Headers may be blank or repeated; positions select them
  unambiguously. No implicit default grouping is chosen.
- `--where-column` and `--equals` must appear together. Filtering uses exact,
  case-sensitive cell equality before grouping. `--equals ''` matches empty
  cells. The filter column can also be a group column, but need not be.
- Group identity is the complete tuple of selected exact strings. Empty cells
  form ordinary groups. Case, spaces, leading zeroes, Unicode and numeric token
  spellings remain distinct; no trimming, numeric conversion or fuzzy matching.
- Every matching data row contributes exactly once. Repeated group keys are
  expected. The header never contributes a count.
- Sort is descending `row_count`, then ascending `first_source_row` for ties.
  This is deterministic for the same input/options and never relies on map order.
- Original selected headers are followed by `row_count` and `first_source_row`.
  If selected headers use those names, duplicates remain; the last two columns
  always have the documented generated meanings.
- Header-only sources and filters with no matches produce a header-only summary
  with zero groups. There is no special grand-total row mixed into group data.
- Output is complete, without a page, top-N cutoff or hidden truncation. A
  summary that exceeds the output bound fails rather than dropping groups.

CSV fields are all quoted, embedded quotes doubled, and records end in CRLF.
Exact strings and embedded newlines survive reopening. Formula-looking cells
remain unchanged; import untrusted CSV as text in spreadsheet software. This
command counts rows, not distinct IDs or numeric quantities, and evaluates no
formulas. A repeated source row contributes another count.

## Context and output handling

On success stdout is only the complete candidate CSV. Stderr is one JSON record:

- `derived_candidate: true`, `derivation: moonfort-csv-frequency-v1`
- Original binding and fingerprinted `source_file`
- `group_by`, `where_column`, `equals` and the fixed `order`
- `source_rows`, `matching_rows`, `excluded_rows` and `group_count`
- `candidate_fingerprint` and `candidate_size_bytes` of exact output bytes,
  including CRLF record endings

Native API uses `where_column=0, equals=""` to mean no filter; a positive column
with an empty equals value means filter empty cells. Preserve context with the
candidate. Source and candidate fingerprints describe different byte streams;
local derivation metadata is not a new receipt, signature or promotion approval.
There is no separate local recipe file or new credential/configuration required.

All validation completes before stdout begins. On failure, exit is nonzero and
stderr is a diagnostic, not context. I/O failures may still leave partial output.
Check the exit status before consuming either file. Shell redirection creates or
truncates its destinations before the command starts: use new paths, never an
original artifact or valuable existing file.

## Limits and native API

Source and candidate each at most 1 MiB; at most 20,000 source data rows, 64 source
columns and 16,384 UTF-16 units per field. At most 62 group columns leaves room
for the two generated columns in a reusable 64-column CSV. Filter values are at
most 16,384 UTF-8 bytes. The existing strict UTF-8/BOM/comma/quoted CSV dialect,
ragged-record, NUL and malformed-quote refusals apply. Context including its LF
must fit the configured protocol budget. Existing retention expiry, path,
fingerprint, disk and promotion-lock checks still apply.

`summarize_retained_csv(binding, path, config, group_by~, where_column?, equals?)`
returns `RetentionCsvSummary`. Its `csv` is the candidate, and `context()` returns
the provenance without candidate content or host-local paths. Every request
verifies the source bytes and rechecks its saved retained record. This is not an
atomic filesystem snapshot. It supports one source table and row counts, not
numeric aggregation, cross-file queries, a spreadsheet editor, or new authority.

## Focused native verification

`executor/retention_csv_summary_wbtest.mbt` exercises exact tuples, count ranking,
ties, quotes/Unicode/multiline cells, blank and duplicate headers, empty groups,
filtering, original row drillback, 20,000 rows/groups, limits, source/context
fingerprints, unchanged evidence, malformed/changed/expired sources, and the
actual compiled CLI with rejected options and deterministic reopened output.
Set `MOONFORT_ARTIFACT_READER_CLI` to the freshly built native command and
`MOONFORT_CSV_SUMMARY_EVIDENCE` to an existing private directory to retain examples.
Synthetic fixtures are evidence of this workflow only, not qualified payload
execution, durable promotion or portable signed attestation.
