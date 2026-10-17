# Correct a retained CSV report into a reusable candidate

Use `browse-retention edit-csv` after inspecting a generated table when a few
cells need correcting, a draft row should be removed, or a new local row should
be added before review. It reads the existing retained artifact, applies your
local recipe in memory, and exports an ordinary CSV candidate. Retained bytes,
their receipt, grants and durable workspaces remain unchanged.

## Inspect, edit, reopen

1. Inspect the table and keep its `file.fingerprint` and logical row numbers:

   ```sh
   browse-retention table checks.csv --json < receipt-binding.json > inspected-table.json
   ```

   Use the existing `MOONFORT_EXECUTOR_CONFIG`. Page with `--after-row` if needed.
   The reported row numbers refer to the complete table, including rows omitted
   by filtering. They are data-record numbers, not physical text lines.

2. Write a UTF-8 local recipe. Replace the fingerprint below with the exact
   lowercase SHA-256 from your inspected file. This example corrects the first
   data row, removes the second, then appends a row of the same width:

   ```json
   {
     "version": 1,
     "source_fingerprint": "REPLACE_WITH_INSPECTED_FILE_FINGERPRINT",
     "operations": [
       {"op": "set-cell", "row": 1, "column": 2, "value": "ready"},
       {"op": "remove-row", "row": 2},
       {"op": "append-row", "cells": ["04", "new", "added locally"]}
     ]
   }
   ```

3. Run the compiled CLI and check its exit status. Use new output paths:

   ```sh
   browse-retention edit-csv checks.csv --recipe local-edits.json \
     < receipt-binding.json > new-candidate.csv 2> new-candidate.context.json
   ```

4. Open the candidate in a CSV reader and review the corrections against the
   original table. Keep the exact recipe and context with it. The candidate is
   ordinary UTF-8 comma-separated data and uses the same cell/quoting contract
   as the existing table export and retained CSV comparison engine.

The candidate is a local file, not a newly retained run. Existing `table` and
`compare-retained-csv` commands require valid retained bindings; pointing the old
binding at a candidate does not import it. Do not overwrite scratch or fabricate
a retention record to reopen it. Later acceptance needs the destination owner's
separate supported review workflow. No promotion is performed here, and the old
source fingerprint cannot authorize promotion of these changed bytes.

## Exact version-1 recipe semantics

- The root contains exactly `version`, `source_fingerprint` and `operations`.
  Version is literal integer `1`; fingerprint is exactly 64 lowercase hexadecimal
  characters. A different inspected source refuses before deriving output.
- There are 1–100 operations, applied in array order. Each operation sees the
  table produced by preceding operations. Removing row 2 makes the old row 3
  become the new row 2. An appended row is addressable by later operations.
- `set-cell` has exactly `op`, `row`, `column` and a string `value`. Row and column
  are positive one-based JSON integers. Strings, negatives, zero, fractions and
  exponent spellings are rejected as coordinates. The addressed cell must exist.
- `remove-row` has exactly `op` and `row`, and requires an existing data row.
- `append-row` has exactly `op` and `cells`, an array of strings matching the
  existing header width. It appends after the last data row.
- The header is never a data row and cannot be edited or removed. Blank and
  duplicate header names remain intact; numeric columns stay unambiguous.
  Removing every data row and appending to a header-only table are supported.
- Cells are exact strings, with no trimming, numeric conversion, date inference
  or formula evaluation. Empty cells, Unicode, quotes, embedded CR/LF, leading
  zeroes and large integer strings are retained. Formula-looking cells are not
  neutralized; use appropriate care when opening any supplied data in a spreadsheet.
- Unknown fields/operations, duplicate decoded JSON keys, malformed UTF-8/JSON,
  missing positions, invalid widths and all bounds failures reject the derivation.
  A valid first operation followed by a bad operation emits no partial candidate.

## Output and limits

Success stdout contains only CSV, with every field quoted, embedded quotes doubled
and CRLF record endings. The original BOM and CSV formatting are normalized; use
`export` for original bytes. Header cell values are preserved exactly.

Success stderr is one JSON context line containing the original binding and file
fingerprint, `derived_candidate: true`, derivation `moonfort-csv-edits-v1`, exact
recipe-byte digest/size, exact candidate-byte digest/size, operation count, source
and candidate data-row counts, and sequential addressing semantics. It excludes
candidate cells and local recipe paths. Context records a local transformation;
it is not an executor attestation of the edits, a new receipt or reviewer approval.

Source and final candidate are each at most 1 MiB. The recipe is a regular local
file of at most 64 KiB, with the existing retained-JSON parser's 64-container depth
and 20,000-value limits. Tables have at most 20,000 data rows and 64 columns; each
cell is at most 16,384 UTF-16 units and contains no NUL. Every intermediate table
must fit the row limit. Final byte size includes all quoting and CRLF endings.
Context including LF must fit the configured protocol budget.

Validation finishes before stdout output. Refusals return nonzero and write a
diagnostic to stderr rather than context. I/O failure can still leave partial
redirected files, and shell redirection creates/truncates files before the CLI
starts. Use only successful output and never redirect over inputs or valuable files.
Expired, unavailable, changed or mismatched retained evidence uses the existing
artifact-reader refusal behavior; editing does not extend retention.

## Native API and verification

`draft_retained_csv(binding, path, config, recipe_bytes)` returns a
`RetentionCsvDraft`. Its `csv` is the full candidate and `context()` returns
metadata without the candidate contents. The API writes no files.

Build `cmd/browse-retention`, set `MOONFORT_ARTIFACT_READER_CLI` to the compiled
executable, and run `executor/retention_csv_draft_wbtest.mbt` plus
`executor/retention_csv_draft_test.mbt`. The compiled journey begins at the actual
table inspection command, edits with a local recipe, writes/reopens the output,
compares it using the existing CSV comparison engine, checks repeatability, and
checks failure output and original/receipt/workspace immutability. Set
`MOONFORT_CSV_DRAFT_EVIDENCE` to an existing private directory to retain its
synthetic source, exact recipe, inspection, candidate, context and comparison.
These are local filesystem/API/CLI tests, not process-containment, promotion,
browser, signed company, MoonBook acceptance or production qualification.
