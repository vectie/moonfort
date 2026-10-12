# Inspect retained SARIF findings as CSV

`browse-retention sarif-csv PATH` opens a receipt-bound, retained SARIF 2.1.0
report and produces a CSV for reviewing static-analysis findings across runs.
It resolves each run's driver rule indexes and artifact indexes. No mapping file
or analyzer installation is needed. This is a static projection of existing
evidence, not an analysis run or an assertion that a report is SARIF-conformant.

```sh
browse-retention sarif-csv reports/findings.sarif \
  < receipt-binding.json > new-findings.csv 2> new-findings.context.json
```

Use the existing trusted `MOONFORT_EXECUTOR_CONFIG` and original receipt binding.
Check the exit status before using either output. Use new output paths: shell
redirection/output failures can still leave empty or partial files.

## Reading the output

The fixed columns are:

- `__result_pointer`, `__location_pointer`: JSON Pointers into the original report
- `tool`, `rule_id`, `rule_name`: the run's driver and resolved driver rule
- `level_declared`, `rule_default_level`, `kind_declared`, `baseline_state`
- `message_text`, `message_markdown`: literal inline message strings
- `suppressions_json`: the original suppression array, serialized as JSON
- `uri`, `uri_base_id`, `start_line`, `start_column`, `end_line`, `end_column`

Each primary location becomes a row. A result with two locations produces two
rows; a result with absent or empty locations produces one row with blank
location columns. Original run/result/location order is preserved. Findings are
not deduplicated, filtered by suppression, or dropped because they lack a file.
Use `result_count` for findings and `row_count` for exported rows; counting rows
alone can overcount findings.

For example, a report's `ruleIndex: 0` is looked up in that same run's
`tool.driver.rules[0]`, and `artifactLocation.index: 0` in its `artifacts[0].location`.
A `ruleId` without an index is matched to a unique driver rule when one exists.
Unknown explicit rule IDs remain available, with blank descriptor columns.
Conflicting explicit IDs or URI/base IDs and indexes refuse rather than silently
choosing one. Index `-1` means absent. A nonnegative index must resolve.

Reopen a finding or one of its locations with the existing JSON browser:

```sh
browse-retention json reports/findings.sarif \
  --pointer /runs/1/results/0 --value < receipt-binding.json
```

The sidecar context binds the source file, receipt and exact CSV bytes by SHA-256,
and reports run, result and row counts. Keep it with the CSV. Original artifact
bytes and receipt remain unchanged. Both calls verify the retained file rather
than fetching or opening the file named inside a SARIF finding.

## Deliberate interpretation limits

This is a bounded inline-results viewer, not a complete SARIF implementation.

- Requires version `2.1.0`, a `runs` array, and inline `results` arrays plus a
  nonempty `tool.driver.name` for each run. An empty runs/results array is valid;
  absent/null results refuse rather than being presented as a clean scan.
- Driver `ruleId`/`ruleIndex` and inline/indexed artifact locations are supported.
  `result.rule` descriptor references, extension-component rules, and run-level
  `externalPropertyFileReferences` refuse. No external files are fetched.
- Every result needs inline `message.text` or `message.markdown`. ID-only message
  lookup refuses. Strings remain literal; message argument substitution,
  Markdown rendering and embedded-link interpretation are not performed.
- Severity columns retain the result's declared level and the driver's rule
  default separately. Blank means absent. Effective severity is not computed:
  invocation overrides, kind defaults, and other SARIF semantics can change it.
- URI and `uriBaseId` remain exact strings, including relative references.
  `originalUriBaseIds` are not expanded; no URI is fetched or treated as an
  authorized filesystem path. Positions are optional positive 32-bit integers;
  numeric spelling is retained. Character-offset/address-only locations have
  blank line columns. Logical-only locations also remain as rows with pointers.
- Suppressions remain structured JSON in a CSV cell; no filtering or acceptance
  decision is inferred. Other metadata (including fixes, code flows, related or
  logical location details, properties and invocation status) stays in the
  original report and is accessible through source pointers.
- No judgment about scan completion, accuracy, absence of vulnerabilities,
  enforcement, approval, promotion or production safety follows from this CSV.

The supported relationships and distinctions are based on the
[OASIS SARIF 2.1.0 standard](https://docs.oasis-open.org/sarif/sarif/v2.1.0/os/sarif-v2.1.0-os.html),
especially artifact locations, runs, results, and reporting descriptors. This
workflow intentionally publishes declared severity instead of attempting the
standard's complete effective-level calculation.

## Limits and API

Input and output are each at most 1 MiB, with at most 10,000 findings and 10,000
rows. Existing retained JSON validation bounds nesting to 64 and values to
20,000 and refuses duplicate keys. CSV cells are at most 16,384 UTF-16 units
and cannot contain NUL. UTF-8, quotes, commas, Unicode and newlines are preserved
using the existing quoted CRLF CSV serializer. Formula-looking text is retained;
import untrusted CSV cells as text in spreadsheets. Malformed later results,
unresolved indexes or output overflow refuse before CSV output is emitted.

The executor API is `tabulate_retained_sarif(binding, path, config)` returning
`RetentionSarifTable`. Its `context()` omits CSV bytes. The original retention
and fingerprint checks apply. No grants are consumed and no original or
workspace destination is modified.
