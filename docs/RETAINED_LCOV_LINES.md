# Inspect retained LCOV line coverage

`browse-retention lcov-csv coverage.info --uncovered < binding.json > uncovered.csv 2> uncovered.context.json`

Omit `--uncovered` for every line observation. Use the existing trusted
MOONFORT_EXECUTOR_CONFIG and the original retention binding. Check exit status,
use fresh output paths, and keep the context sidecar with the CSV. Spreadsheet
imports must treat untrusted test names, paths and checksums as text.

The read-only command verifies the retained artifact through the existing
receipt-bound exporter, parses the complete report, then emits CSV. The sidecar
binds the original file digest and receipt plus exact output digest and size.
No coverage command runs, no source path is opened, and neither original
artifact nor receipt changes. Output is a derived candidate, not a promotion.

## Interpretation

Each DA line becomes one CSV row in original order: one-based record number,
one-based physical report line, TN test name, raw SF path, source line, hits,
and optional checksum. A positive hit count is covered. `--uncovered` retains
only zero-hit observations. Sidecar line and covered counts describe the whole
report before filtering; row_count describes output. Use report_line to reopen
the exact DA observation in the original exported report. SF paths (including
Windows drive letters, commas and Unicode) are opaque, not resolved.

Repeated TN/SF records are deliberately separate. A line missed in one test
and covered in another remains two observations; filtering may show that first
observation. Counts are observations across records, not merged project coverage.
No union, percentage, source comparison or checksum validation is inferred.
An empty source record counts as a record but produces no line row. TN applies
only to the immediately following SF record; omission means an empty test name.

## Supported subset and limits

UTF-8, LF or CRLF text. Records begin with optional TN then nonempty SF and end
with end_of_record. DA accepts positive 32-bit source line, nonnegative 32-bit
hit count, optional opaque checksum. Within one record, duplicate source line
numbers refuse, including differently padded numbers. Optional LF/LH counters
must each appear at most once and exactly match observed DA totals at record
end. Blank interior lines, unknown tags, misplaced fields, overflow, negative
counts, missing terminators and empty reports refuse.

FN/FNDA/FNF/FNH and BRDA/BRF/BRH are accepted as opaque metadata inside a record,
omitted from the view, and not validated. This is not function/branch coverage
or a general LCOV validator. Newer extensions (for example FNL/FNA or MC/DC
records) refuse as unsupported instead of being silently interpreted.

Input and output each cap at 1 MiB, with at most 1,000 records and 10,000 DA
observations. Limits apply before filtering; malformed later records refuse
without emitting a partial CSV. Context must fit the configured protocol limit.
The existing retention lifetime, file digest and binding checks still apply.
