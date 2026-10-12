# Review retained CSV tables

`browse-retention table` opens a verified CSV artifact as logical records, rather
than cutting through quoted cells with a byte preview. Inspect headers, select
columns, isolate exact cell values and continue row pages. Export the selected
page as JSON for a host UI or CSV for another data tool.

Use the existing executor configuration and receipt binding described in
[the artifact browser guide](RETAINED_ARTIFACT_BROWSER.md). The command does not
execute a process, consume a grant, change scratch, promote files or accept data.

## Commands

```text
browse-retention table reports/checks.csv < receipt-binding.json
browse-retention table reports/checks.csv --columns 1,4 --where-column 3 --equals follow-up --limit 1 < receipt-binding.json
browse-retention table reports/checks.csv --columns 1,4 --where-column 3 --equals follow-up --after-row 2 --json < receipt-binding.json
browse-retention table reports/checks.csv --columns 1,4 --where-column 3 --equals follow-up --csv < receipt-binding.json > selected-page.csv
```

- First record is the header. Column numbers are one-based and retain the
  requested order. Omit `--columns` to keep all columns. Duplicate/blank header
  names are preserved and can be distinguished by column number.
- `--where-column` and `--equals` must occur together. Matching is exact,
  case-sensitive string equality before column projection. Empty values can be
  selected with `--equals ''`. No numeric coercion or formula evaluation occurs.
- `--after-row` is an exclusive logical data-row number. Header is not row 1;
  embedded newlines do not increment row numbers. Reuse the same columns/filter
  with the returned cursor. Text and JSON include original source row numbers.
- Default page is 20 matching records; `--limit` accepts 1–100. Pages can shrink
  to fit the configured JSON protocol limit, without splitting or losing rows.
  A row too large for one response refuses; select fewer columns or use raw export.
- JSON includes receipt binding, source SHA-256, selected column numbers,
  headers, filter, total and matching row counts, row values and continuation.
- `--csv` writes only the current page, with a header and CRLF record endings.
  It reports page counts and continuation on stderr. It is not an automatic
  whole-file download. Repeated pages have repeated headers; keep one header
  when joining them with a CSV-aware tool. Use JSON to retain provenance.

All CSV output cells are quoted and embedded quotes doubled. Leading zeros,
Unicode, empty strings and embedded newlines survive round-trip parsing.
Output is a derived selection; use `export` for original byte-exact contents.
Spreadsheet formula-like cells are preserved. Import untrusted CSV as text in
spreadsheet software; quoting alone does not neutralize formulas.

## Accepted dialect and limits

UTF-8 (optional initial BOM), comma delimiter, double-quoted fields, doubled
quote escapes, and LF, CRLF or CR record endings. Embedded CR/LF inside quotes
are retained. Spaces are data, including around quotes; quotes may only start
a field, and no text may follow a closing quote before a delimiter/end.
The table must have a header and the same number of fields in every record.
An empty file, unterminated quote, NUL, invalid UTF-8 or ragged record refuses.
A blank logical record is one empty field, not a skipped row.

At most 1 MiB of source bytes, 64 columns, 20,000 data rows and 16,384 UTF-16
units per field. Filter values are limited to 16,384 UTF-8 bytes. Existing
retention lifetime, disk, path, fingerprint and protocol limits also apply.
The whole artifact is verified and parsed on every request, including requests
for later pages. There is no delimiter detection, headerless mode, type inference,
sorting, editing, aggregation, XLSX support or multi-file query.

The workflow is read-only inspection of execution evidence. Neither table
output nor a successful CLI exit establishes sandbox containment or promotion
approval. Source identity remains the original file fingerprint.

## Reproduce the synthetic journey

`executor/retention_csv_wbtest.mbt` creates a retained four-row release-check CSV
without running a payload. The compiled CLI isolates two documentation follow-ups,
pages through rows 2 and 4, and exports a projected CSV that reopens to the same
cell values. Set `MOONFORT_ARTIFACT_READER_CLI` to the built native command and
`MOONFORT_CSV_EVIDENCE` to an existing private directory to save actual outputs.
Run the focused CSV tests with the repository's pinned/frozen native toolchain.
The synthetic binding file is example input, not a live grant or lasting record.
