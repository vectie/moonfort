# Review coverage changes across retained ZIP copies

Compare LCOV line observations from two existing MoonFort review bundles without
reopening the executor or rerunning the original commands. An operator can find
lines that were reported covered before and unhit afterward, lines now covered,
and coordinates added or removed from the supplied reports. Repeated test-name
records are combined for line coverage while every original observation remains
available for drillback.

This extends the retained artifact review in PRD MOONFORT-W04/W06/B09. The
existing `lcov-csv` exports separate observations; this workflow performs a union
and before/after comparison on portable `browse-retention bundle` outputs. It
does not modify the execution boundary, acceptance or promotion process.

## Workflow

Use Python 3.9+ and its standard library. Start with two existing ZIPs produced
by the [retained review bundle](RETAINED_REVIEW_BUNDLE.md) workflow. If retrieving
copies in a separately configured native environment, use the existing command:

```sh
browse-retention bundle --prefix reports/ < before-binding.json > before.zip
browse-retention bundle --prefix reports/ < after-binding.json > after.zip
```

The Python tool itself does not run these commands or need their configuration.
The exact LCOV path must be among the files selected into each ZIP:

```sh
python3 tools/coverage_review.py before.zip after.zip --report reports/coverage.info > coverage-review.json 2> coverage-review.context.json
python3 tools/coverage_review.py before.zip after.zip --report reports/coverage.info --changes-only --format csv > coverage-changes.csv 2> coverage-changes.context.json
```

Use `--after-report renamed/coverage.info` if the second report has a different
artifact path. Source-code paths inside LCOV are still compared literally; they
are not renamed, normalized, opened or fetched. Keep the ZIPs and both output
files. JSON is directly readable; CSV is for a spreadsheet's text-import dialog.
Import all text columns as text with formula interpretation disabled. The CSV
preserves formula-looking source paths and does not claim spreadsheet safety.

## What the comparison means

A coordinate is the exact opaque `SF` path plus integer `DA` source line. Within
each report, the coordinate is covered when any of its test-record observations
has a positive hit count. Repeated observations are preserved, including repeated
test names. `reported_hits_sum` is a sum of the supplied observations, not a
claim about distinct executions or merged test-run counts. There is no percentage
or repository-wide coverage denominator.

Statuses:

- `covered-to-uncovered`: before has a positive observation; after has none
- `uncovered-to-covered`: the reverse
- `still-covered`, `still-uncovered`: same union result on both sides
- `added-covered`, `added-uncovered`: coordinate exists only after
- `removed-covered`, `removed-uncovered`: coordinate exists only before
- `source-changed`: both sides report checksums, but they differ
- `checksum-conflict`: one side reports multiple different checksums at a coordinate

Checksum conflict/change takes precedence over coverage-change labels. A missing
coordinate is never treated as zero hits. Added/removed observations need review;
they are not automatically regressions, fixes or deleted code. An empty source
record contributes to record counts but has no line observations to compare.

`comparison_basis` is `coordinate-only` whenever either side or any contributing
observation lacks a checksum. Only a complete, single matching reported checksum
on both sides yields `same-reported-checksum`. LCOV checksums are opaque report
values: the tool does not validate them against code. Paths and line numbers can
shift or be reused between source revisions. Even a matching reported checksum
is not independent proof of unchanged source or code-equivalent regression.
The output's meaning statement makes this limit explicit.

Every before/after row retains reported hits, checksums, missing-checksum counts
and all contributing `record`, physical `report_line`, `test_name`, `hits` and
`checksum` observations. Reopen `artifacts/<report path>` inside the saved ZIP and
read the stated one-based physical line. Blank lines are unsupported. The tool
never follows an LCOV source path, extracts ZIP members, executes tests or writes
an artifact back to scratch.

`--changes-only` omits only the two `still-*` categories. Status counts always
cover the entire coordinate union, before filtering. A no-change CSV contains
its header; a no-change JSON has an empty `rows` list. All source validation and
bounds apply before filtering.

## Verification and provenance

The reader accepts the product's version-1 unencrypted stored ZIP layout,
`manifest.json` plus `artifacts/<relative path>`, and checks the complete selected
inventory's sizes and SHA-256 digests, including files other than LCOV. It rejects
missing, duplicate, unexpected or unsafe members and nonregular inventory items.
No extraction occurs. The manifest's native Int64 decimal-string sizes/expiry
and integer values are supported. Both original receipt bindings, source expiry,
selected report metadata, archive SHA-256 and exact manifest SHA-256 are copied
into context. The complete candidate SHA-256 and byte size are added to the
stderr sidecar. JSON includes context and rows; CSV puts each side's observation
object in `before_json`/`after_json`, using JSON `null` when the side is missing.

These checks prove consistency of a supplied copy, not authenticity, current
executor state, receipt signature or complete coverage of all artifacts. A ZIP
contains only its export selection. The copied source expiry is historical:
already downloaded review copies remain readable after that time. The tool does
not contact the executor, bypass live retrieval expiry or validate that the
original receipt remains available. It reads each whole ZIP into memory, so its
fingerprint describes exactly the bytes consumed; reading two copies is not a
simultaneous snapshot of an actively changing executor.

## Supported LCOV and bounds

The LCOV subset matches the existing [line report viewer](RETAINED_LCOV_LINES.md):
UTF-8 LF or CRLF, optional TN followed by nonempty SF, DA line/hits/optional
checksum and `end_of_record`. DA line is positive and hits nonnegative, each at
most 2,147,483,647. Padding is permitted but duplicate numeric source lines within
one record refuse. LF/LH, when present, must exactly match observed counts.
FN/FNDA/FNF/FNH and BRDA/BRF/BRH are ignored opaque function/branch metadata,
not function/branch coverage validation. Newer tags refuse. Unterminated records,
blank interior lines, lone CR, NUL, invalid UTF-8 and inconsistent counters refuse.

Bounds per input: ZIP at most 20 MiB, manifest/report at most 1 MiB, 1–200
artifacts and 16 MiB total uncompressed artifact bytes, 1,000 LCOV records,
10,000 DA observations and 16,384 characters per LCOV physical line. Completed
JSON/CSV is at most 16 MiB. This is bounded in-memory review, not live streaming.
Other compressed/general-purpose ZIPs are unsupported; use original product
bundle copies. No dependencies are installed or replaced.

Success exits 0, writes a complete comparison to stdout and JSON context to
stderr. Validation/read failures exit 1 with a stderr diagnostic and no partial
comparison; argparse errors exit 2. Prepare new output paths and check exit
status. Shell redirection can truncate existing files before the program starts,
and output I/O failure can still leave partial files. Both ZIPs remain unchanged.
Retained evidence can be private; nothing redacts it or authorizes sharing.

## Focused qualification

`python3 scripts/test-coverage-review.py` exercises real ZIP files in the native
producer's format, CRLF and LF LCOV, union by coordinate across test records,
changed/missing/conflicting checksums, added/removed observations, renamed report
paths, relocation/reopen, JSON/CSV readback, source-line drillback and bounded
failure behavior. All synthetic inputs and subprocess outputs remain in the
printed evidence directory; set `MOONFORT_COVERAGE_EVIDENCE` to a new directory
when desired. The native bundle producer, browser, original tests, live executor,
local/AEN containment and full product suite are not rerun or qualified here.
R50 remains the last fully verified cumulative checkpoint; R51–55 are separate.
