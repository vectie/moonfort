# Measure retained CSV results

Use `browse-retention aggregate-csv` to turn retained duration, quantity, or
resource measurements into ranked group totals and statistics. Frequency
summaries count repeated labels; this command measures a numeric column. It can
also produce one whole-report total. Both outputs remain derived candidates.

## From a report to a bottleneck

With the existing trusted `MOONFORT_EXECUTOR_CONFIG` and actual receipt binding:

```sh
browse-retention aggregate-csv checks.csv --value-column 3 --group-by 2 \
  < receipt-binding.json > new-rollup.csv 2> new-rollup.context.json
```

If columns 2 and 3 are `area` and `seconds`, the CSV contains area, row count,
numeric count, blank count, sum, minimum, maximum, mean, and first source row.
Groups rank by descending sum. To reopen the first example of a group whose
`first_source_row` is 2:

```sh
browse-retention table checks.csv --after-row 1 --limit 1 --json \
  < receipt-binding.json
```

Use the same original binding and path. Logical data-row numbers exclude the
header; embedded newlines do not change positions. Drillback opens an example,
not necessarily the maximum or minimum measurement. For a whole-report total:

```sh
browse-retention aggregate-csv checks.csv --value-column 3 \
  < receipt-binding.json > new-total.csv 2> new-total.context.json
```

## Numeric contract

- `--value-column` is a required one-based column number.
- `--group-by` optionally selects 1–56 distinct one-based columns, in output
  order. Omit it for one overall group. Group keys retain exact strings,
  including whitespace, Unicode, multiline values, and blank/repeated headers.
- Values are plain decimals: optional minus, one or more ASCII integer digits,
  and optional decimal point with 1–6 fractional digits. Leading zeros are
  allowed. No whitespace trimming, plus signs, separators, exponent notation,
  currency symbols, units, NaN, or infinity are accepted. Convert units upstream;
  the command never infers that two different units should be combined.
- Empty cells count as missing and do not enter numeric statistics. A group
  containing only blanks has blank sum/min/max/mean, rather than invented zeros.
  Any other invalid number refuses the entire export, naming its source data
  row and selected column. Numeric zero is a measurement and contributes.
- Values and each intermediate group sum must lie between -9,000,000,000,000 and
  +9,000,000,000,000 inclusive. Exceeding this bound refuses, even if a later row
  would cancel it. Arithmetic uses scaled 64-bit integers, never binary floating
  point. Sum/minimum/maximum are exact; mean rounds to six decimal places, with
  halfway cases away from zero. Outputs always use six fractional digits;
  negative zero normalizes to zero.
- Sort by descending sum and then first source row for ties. All-missing groups
  sort last, in source order. No top-N cutoff or silent group truncation occurs.
- A header-only source produces a header-only result with zero groups, even
  without grouping. Duplicate generated/source header names are preserved;
  the last eight columns always have the generated meanings above.

## Provenance and limits

Success writes complete quoted CRLF CSV to stdout and one context JSON record
to stderr. Context includes original binding/source fingerprint, group columns,
value column, source/group counts, decimal/mean/missing/order semantics, and
exact candidate byte size/SHA-256. Preserve context alongside the CSV. It is
local derivation metadata, not a signature, new execution receipt, acceptance,
or promotion authority. Original artifact bytes and retained receipt are not
changed; the command runs no workload and consumes no grant.

The source and candidate are each at most 1 MiB; existing strict UTF-8 CSV
parsing permits at most 20,000 data rows, 64 source columns, and 16,384 UTF-16
units per field. Context must fit the executor protocol budget. Existing binding,
path, expiry, saved-record and fingerprint checks apply. Reading/rechecking is
not an atomic filesystem snapshot. The full result validates before output
begins; output I/O failures may still leave partial files. Check exit status and
use new output paths because shell redirection truncates before execution.
Import formula-looking or precision-sensitive cells as text in spreadsheet tools.

Native API: `aggregate_retained_csv(binding, path, config, value_column~,
group_by?=[]) -> RetentionCsvAggregate`; `context()` omits candidate content and
host-local paths. This one-table workflow is neither a general spreadsheet nor
arbitrary formulas, cross-run comparison, weighted averages, or unit conversion.

Focused native tests cover exact arithmetic, rounding, negative/zero/blank data,
compound keys, complete-result bounds, row drillback, saved evidence bindings,
unchanged source/receipt, CLI options, repeat output, and a compiled full journey.
These tests do not qualify production containment or payload execution.
