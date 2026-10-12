# Compare retained test outcomes offline

A reviewer can compare two already-exported `browse-retention bundle` ZIPs and
see which reported testcase outcomes changed before deciding which exact output
to inspect. This is distinct from retained file-inventory comparison, one-report
JUnit CSV export, and line-coverage comparison. It supports the inspection step
in MOONFORT-W04 without executing a workload or promoting artifacts.

From the repository root, with two genuine previously exported bundles:

```sh
python3 tools/junit_review.py before.zip after.zip --report reports/tests.xml > new-review.json 2> new-review.context.json
python3 tools/junit_review.py before.zip after.zip --report reports/tests.xml --changes-only --format csv > new-changes.csv 2> new-changes.context.json
```

Use fresh output names and check the exit status. `--after-report new/tests.xml`
selects a renamed report in the second bundle. Keep both original ZIPs and the
output plus context sidecar. The tool reads bundles without extracting files,
contacting executors or weakening retention rules. Historical exported copies
remain readable after source expiry, but do not establish present retrieval
rights. Output sidecars include the existing receipt bindings, bundle/manifest/
report fingerprints and exact candidate fingerprint/size. All included artifact
bytes are checked using the existing portable coverage-review bundle reader.

## Matching and review

Identity is the exact tuple `(nested suite name array, classname, testcase name)`.
Nested arrays avoid collisions between a literal `a / b` suite and nested `a`,`b`.
Names and source-location attributes are opaque strings; no path traversal,
rename inference, fuzzy matching or source-code identity is attempted.

- `changed-outcome`: one testcase on each side with different reported outcomes.
  Both outcomes are retained: `passed`, `failed`, `error`, or `skipped`.
- `changed-details`: same outcome, but time, file, line, status/result or complete
  failure/error/skipped diagnostics changed. Duration stays an exact string;
  changes in duration spelling are visible and no performance inference is made.
- `unchanged`: these reported fields agree. Physical XML line/test index may
  differ because report order changed. This is not proof of equivalent tests.
- `added` / `removed`: unmatched exact identities. Never called improvement,
  regression, success, or deletion of a real test.
- `ambiguous-identity`: more than one testcase has that identity on either side.
  All observations remain in before/after arrays; no arbitrary pairing occurs,
  even if the other side is absent. Inspect the original reports to resolve it.

`--changes-only` suppresses only unchanged rows. Status counts still summarize
the full union. JSON and CSV retain every observation for each emitted identity,
including one-based physical XML start-tag line and document testcase index.
Use those with the original report artifact for drillback. CSV uses JSON cells
for nested arrays; import all CSV cells as text, especially names beginning `=`.

## XML contract and bounds

Accepts UTF-8/XML-declared encoded JUnit XML with `testsuite` or `testsuites`
root, nested suites, testcase attributes, failure/error/skipped text (including
CDATA), properties, and system-out/system-err elements. Properties and captured
console output are not compared: retain the report for them. Declared suite
counters are not trusted; counts are computed from actual testcase elements.
Every testcase requires a name. Namespace-prefixed dialects, arbitrary markup
inside diagnostics and unknown elements refuse explicitly. No report is fetched.

`status` accepts absent/empty, `run`, `notrun`; `result` accepts absent/empty,
`completed`, `suppressed`, `skipped`. Not-run/skipped and failed/error combinations
refuse, as does notrun+completed. Error takes precedence over failure, with both
diagnostics retained. A case with no outcome or not-run marker reports passed;
this records what the supplied XML says, not proof that a test ran.

DTD/entity declarations are rejected. Limits: 1 MiB per selected report, 10,000
testcases, 64 nested XML elements, 16 MiB comparison output; existing review
bundle limits also apply (20 MiB ZIP, 200 artifacts, 16 MiB combined artifacts).
Failure emits no candidate bytes to stdout. It does not authenticate signatures,
rerun tests, certify a regression, approve execution, accept work or promote it.

## Verification

```sh
python3 scripts/test-junit-review.py
python3 scripts/test-coverage-review.py
```

The stdlib functional suite constructs real ZIPs in native producer manifest
format, invokes the CLI, reopens JSON/CSV, verifies fingerprints/source drillback,
and proves both inputs unchanged. Evidence stays in the printed directory;
`MOONFORT_JUNIT_EVIDENCE` and `MOONFORT_COVERAGE_EVIDENCE` can choose separate new
directories. This does not requalify the native producer, executor, backend,
browser, provider, hardware or full product. No Moon or dependency install needed.
