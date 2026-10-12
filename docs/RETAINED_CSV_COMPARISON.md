# Compare retained CSV records by key

A new run can reorder a report while changing only one check. Use
`compare-retained-csv` to match logical records by explicit key columns and
inspect just added, removed and edited records. This complements inventory
comparison and line-oriented text diff. Both original artifacts are read and
verified against their retained fingerprints before a report is returned.

## Use an existing pair of retained runs

Use the operator-owned `MOONFORT_EXECUTOR_CONFIG`. Save `comparison.json` with
`baseline` and `candidate`, each containing the original five-field receipt
binding from [the retained artifact browser](RETAINED_ARTIFACT_BROWSER.md).
This is the same input shape as `compare-retention` and `diff-retention`.
Both runs must retain the selected relative path.

```sh
compare-retained-csv reports/checks.csv --key-columns 1,2 \
  < comparison.json > new-changes.json
compare-retained-csv reports/checks.csv --key-columns 1,2 --csv \
  < comparison.json > new-changes.csv 2> new-changes.context.json
```

Column numbers are one-based. `--key-columns 1` matches an ID; `1,2` matches an
ID/platform pair. Choose the columns that actually identify a record. There
is no automatic key inference, first/last duplicate selection or fuzzy match.
Every key component must be nonempty, and each complete tuple must be unique
within each side. A refusal names the affected side and logical data-row
numbers (and the column for an empty key), so you can inspect the source with
`browse-retention table`. The command does not guess correspondences.

The first record is the header. Both ordered header arrays must match exactly.
Blank and duplicate header names remain usable through column numbers.
Reordered, added or renamed columns refuse; inspect schema changes with the
existing text diff or exact export before preparing compatible reports.

## What the report means

- Keys and cells are exact, case-sensitive strings, without trimming, numeric
  conversion, Unicode normalization or formula evaluation. `01` and `1` differ.
- Row order, CSV quoting differences, BOM and record-ending style do not create
  changes. Embedded CR/LF within a cell remains data and does create a change.
- A key change is a removed record plus an added record. An existing key with
  different cells is one changed record. All identical rows count as unchanged
  and are omitted from the entries.
- Entries sort lexically by the component strings in the selected key order.
  Original row numbers on each side count logical data records, excluding the
  header and ignoring physical newlines inside quoted cells.
- Default JSON (or `--json`) includes both original bindings, exact file metadata
  and fingerprints, selected keys, headers, full row counts and each changed
  row's complete before/after values. Missing-side fields are omitted, distinct from a
  present row with empty cells. `changed_columns` is one-based; added/removed
  rows list every column.
- `--csv` produces a complete long-form table with one record per differing
  cell, or every cell in an added/removed row. Columns are `change`, `key`,
  `before_row`, `after_row`, `column`, `header`, `before`, `after`. `key` is one
  JSON-array string inside a quoted CSV cell, so compound values stay distinct.
  `change` and the absent row number distinguish missing sides from empty cells.
  Successful stderr supplies source bindings, fingerprints, keys and row counts.
- A comparison with no changes succeeds with empty JSON entries or a header-only
  CSV. Added/removed/changed counts describe records, not CSV output cell rows.

Keep CSV and its context together. Use fresh output filenames: shell redirection
creates or truncates files before the command starts. Check the exit status
before reading stderr as context. Failure stderr is a diagnostic; I/O failures
can leave partial files. All fields are quoted, but spreadsheet formulas are
preserved. Import untrusted output as text using your normal spreadsheet care.

## Bounds and ownership

Each source permits at most 1 MiB, 64 columns, 20,000 data rows and 16,384 UTF-16
units per field, using the existing strict UTF-8 CSV parser and dialect. Both
retained files must exist and pass the existing binding, expiry and fingerprint
checks. Absence or an unavailable source is an error, never a fabricated empty
table. Header-only tables represent genuine empty datasets.

The complete JSON report and complete CSV export are each capped at 4 MiB. They
are direct exports, not truncated model/protocol pages. The source-context JSON
and input bindings still obey the configured protocol limit. Repetition of long
keys in the CSV can exceed its limit even when the JSON fits. No partial report
is emitted on a parsing, matching or size refusal. For reports beyond these
bounds, use verified file export and an external data tool. There is no paging,
column remapping, tolerance, numeric comparison, join, or in-place edit.

This compares the verified bytes read from two runs, not an atomic snapshot or
an assertion that those runs are related. Source bindings are identification,
not signed transferable authority. Nothing runs a workload, consumes a grant,
changes retained bytes, extends retention, promotes an artifact or upgrades any
backend's enforcement claim. A downloaded report outlives source expiry.

## Native API and focused example

`compare_retained_csv(baseline, candidate, path, config, key_columns=[1, 2])`
returns `RetentionCsvComparison`. Use `result.to_json()`, `result.to_csv()` and
`result.context()` for the same outputs. CSV conversion can raise on its size
limit. The API validates source context against the configured protocol budget.

`executor/retention_csv_compare_wbtest.mbt` creates fresh synthetic retained runs,
invokes the real compiled command, reopens both formats, exercises compound keys
and duplicate diagnostics, and checks unchanged receipts/files/authority state.
Set `MOONFORT_CSV_COMPARE_CLI` to the newly built native executable. Set
`MOONFORT_CSV_COMPARE_EVIDENCE` to an existing directory to save actual source
examples, bindings, JSON, CSV, context and a duplicate-key diagnostic. The
included illustrative bindings alone cannot recreate an expired retained run.
No payload or deployment is exercised by these focused tests.
