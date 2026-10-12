# Inspect retained TAP test output

`browse-retention tap-csv results.tap --failures < binding.json > failed-tests.csv 2> failed-tests.context.json`

Use the existing `MOONFORT_EXECUTOR_CONFIG` and original retention binding.
Omit `--failures` to inspect every test point. Check exit status and retain both
files at fresh paths. Import all cells as text when using a spreadsheet: test
descriptions and diagnostics can contain formulas or other untrusted text.

This view reads an existing retained test report. It does not run the tests,
evaluate diagnostic YAML, change the artifact or its receipt, or promote the
derived CSV. Source and candidate SHA-256 fingerprints and byte sizes appear
in the context sidecar together with the original binding.

## Read the results

Rows follow top-level test order. `test_number` is one-based, inferred when
omitted; `report_line` is the one-based physical test line in the source report.
The remaining columns are `status`, `description`, `directive`, `reason`, and
`diagnostics`. An optional description separator `- ` is removed. The directive
is normalized to SKIP or TODO, while its explanation preserves the text.

Statuses are `passed`, `failed`, `skipped`, `todo` (a failing TODO), and
`unexpected-pass` (a passing TODO). `--failures` selects only `failed`; use the
unfiltered view to examine unexpected TODO successes. Sidecar `status_counts`
and `test_count` always describe all observations, before filtering.

Following comment lines and indented YAML diagnostic blocks are preserved as
opaque text with LF separators, including their indentation and markers.
Comments before the first test or after the plan/bailout are omitted. YAML is
not parsed or validated. Physical line references point to the test, not to a
diagnostic line; original report export remains available for exact bytes.

Keep the sidecar when sharing the CSV. A bailout exports the observations
available before the stop and records its reason and physical line in `bailout`
and `bailout_line`. Missing plans are allowed but have `plan_count: null`.
`plan_satisfied` is true only when an explicit plan matches the observation
count and no bailout occurred. Neither successful export nor a header-only
failure view proves the test run passed or completed. A skipped whole run has
plan zero, no rows, and its explanation in `skip_reason`.

## Supported flat-report subset

Based on [TAP 13](https://testanything.org/tap-version-13-specification.html).
UTF-8 with LF or CRLF; optional `TAP version 13` must be the first physical line.
Test lines use lowercase `ok` or `not ok`, optional sequential decimal number,
description, then optional case-insensitive SKIP/TODO directive after `#`.
The legacy `Skipped:` spelling is also recognized. An optional `1..N` plan may
precede the tests or follow them, once only. A plan skip directive requires zero
tests. Unnumbered test points increment the sequence; an explicit number must
match the next expected number. Both zero-test plans and bailouts are readable.

Input and CSV each cap at 1 MiB; there are at most 10,000 test points. Plan
counts also cap at 10,000. Counts are validated against all observations;
without a bailout, a mismatch refuses. After a bailout only blank/comment
lines are accepted, and observed count cannot exceed the declared plan.

Diagnostic blocks begin with an indented `---` following a test and end at
`...` with the same indentation. Intervening nonblank lines must retain that
indentation. Missing terminators refuse. Nested subtests, unknown directives,
unexpected non-diagnostic lines, duplicate/nonsequential numbers, additional
versions/plans, and tests after a trailing plan refuse rather than becoming
apparently complete flat results. This is a bounded report viewer, not a full
TAP or YAML implementation; exporters using nested TAP should supply a flat
report or use original artifact export.

The complete selected report is parsed before output. A malformed late line,
expired/mismatched binding, changed source, or size limit emits no partial CSV.
Context must fit the configured protocol budget. The original execution's
enforcement status is unchanged by this read-only inspection.
