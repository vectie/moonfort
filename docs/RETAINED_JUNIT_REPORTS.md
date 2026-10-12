# Inspect retained JUnit test reports

`browse-retention junit-csv PATH` turns one verified retained JUnit XML report
into an ordinary CSV containing each testcase, its observed outcome, timing and
source-location strings, and failure/error/skipped diagnostics. It lets an
operator filter failed checks or share a review copy without manually unpacking
XML or rerunning a workload. The original receipt and artifact remain unchanged.

```sh
browse-retention junit-csv reports/tests.xml \
  < receipt-binding.json > new-test-results.csv 2> new-test-results.context.json
```

Use the existing trusted `MOONFORT_EXECUTOR_CONFIG` and the original full
`RetentionArtifactBinding`. The API is
`tabulate_retained_junit(binding, path, config) -> RetentionJunitTable`.
The result has CSV, testcase counts, source metadata and candidate fingerprint;
`context()` emits that provenance without the CSV payload.

## Read the output

Rows remain in document order. Duplicate test names are preserved. Columns are:

- `__source_line`: one-based physical line containing the testcase start tag
- `suite`: nested suite names joined by ` / ` for display
- `classname`, `name`: decoded testcase attributes
- `outcome`: `passed`, `failed`, `error`, or `skipped`
- `time`, `file`, `line`: original decoded attribute strings; missing is blank
- `message`: outcome message attributes joined with LF in source order
- `details`: outcome kind/type labels and full decoded diagnostic text
- `failure_count`, `error_count`, `skipped_count`: numbers of those child elements

Error takes precedence over failure when both appear. A skipped and failing
combination refuses as contradictory. With no outcome children, a case is
classified passed unless its supported status/result attributes indicate it did
not run. `status` accepts absent/empty, `run`, or `notrun`; `result` accepts
absent/empty, `completed`, `suppressed`, or `skipped`. `notrun` with `completed`
refuses. Unknown values refuse rather than being called a pass. A not-run case
can be skipped with a zero `skipped_count` because no skipped element exists.

Counts in context are computed from actual testcase rows. Declared suite totals
are deliberately not used; a report declaring 99 tests but containing six cases
exports six rows. Empty suites produce a header-only CSV. These are reported test
outcomes, not evidence that MoonFort executed tests or qualified containment.

Durations and source code line attributes remain strings, including decimal
precision or leading zeros. There is no unit conversion, duration arithmetic,
path interpretation, formula evaluation, deduplication or result repair. Suite
paths are human-readable labels, not unique keys. Import untrusted CSV cells as
text in spreadsheet software, including names that begin with `=`.

## Reopen the original evidence

Keep the CSV and context together. Context binds the receipt, original file
SHA-256/size/path and exact candidate SHA-256/size. Use `__source_line` to reopen
the original testcase using the existing retained text search/preview/export:

```sh
browse-retention search reports/tests.xml --query 'name="checkout"' \
  --after-line 40 --limit 1 --json < receipt-binding.json
```

Check the returned line and fingerprint against context. A testcase's start tag
can span multiple lines; searching its later attribute text can return a later
line. Multiple cases can also begin on one line. Export or preview the original
XML when the full element is needed. Derived source-line labels do not authorize
artifact promotion or preserve retention past its original expiry.

## Supported XML/report subset

The input is UTF-8 XML 1.0 with LF or CRLF lines, optionally beginning with a BOM
and an XML declaration. `testsuite` or `testsuites` is the root. Suites may nest
and contain testcases. Testcases support `failure`, `error`, and `skipped` text;
multiple failures/errors are kept. XML comments, predefined named entities,
valid decimal/hexadecimal character references, quoted attributes and CDATA are
supported. XML literal line endings and attribute whitespace normalize according
to XML conventions; numeric character references preserve the referenced value.

`properties`/`property`, `system-out`, and `system-err` validate but are omitted
from the table at suite and testcase level. Their full bytes remain available
in the original artifact. Unknown attributes are allowed as metadata; unknown
child elements refuse so an unsupported outcome is never silently discarded.

This is a bounded JUnit intake format, not a general XML processor. Namespaces,
DTDs/entities beyond XML's predefined references, non-UTF-8 declarations, other
processing instructions, nested markup inside outcome/system text, lone CR line
endings, and non-ASCII XML element/attribute names are unsupported and refuse.
Nothing resolves external entities, accesses a network, or follows paths named
inside the report. Unsupported producer extensions such as `flakyFailure`
require conversion upstream before this command can summarize them.

Limits: 1 MiB original UTF-8 bytes, 32 XML levels, 20,000 elements, 64 attributes
per element, 10,000 testcase rows, 16,384 UTF-16 units per output cell, 1 MiB CSV,
and the existing executor protocol budget for context. The entire document and
candidate validate before the CLI writes CSV; a bad later element emits no
partial CSV. It still matters to check exit status and use new output paths:
shell redirection and output I/O failures can leave files empty or truncated.

## Focused verification boundary

Parser tests cover nested/single/empty suites, duplicate cases, observed counts,
multiple and contradictory outcomes, Google-style not-run attributes, CDATA,
Unicode/entities, CRLF, whitespace, XML refusals and bounds. API/compiled CLI
tests exercise retained source verification, exact candidate/source digests,
changed/expired bindings, oversized input/output, deterministic exports,
original-line drillback, no partial CSV, and unchanged receipts/originals.
An independent Python XML/CSV reader rebuilds every example CSV byte and digest.
No test executes an approved payload, consumes a grant, promotes an artifact or
qualifies a local/AEN containment backend.

For an offline comparison of two already-exported retained review ZIPs, see
[Portable JUnit review](PORTABLE_JUNIT_REVIEW.md). It compares exact testcase
identities, preserves duplicate ambiguity and all outcome distinctions, and
reuses the verified portable review-bundle intake. It is not execution or promotion.
