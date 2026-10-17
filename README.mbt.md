# MoonFort

MoonFort is the execution-sandbox boundary for MoonSuite. It is deliberately
separate from the MoonDesk virtual filesystem: the VFS describes and confines
workspace paths, while MoonFort controls what a process may read, write, run,
connect to, and consume.

This repository contains the backend-neutral contract, supervised local macOS
and Linux backends, and a fail-closed AEN/Firecracker adapter. The one-shot executor
accepts only an opaque approval ID, atomically consumes a trusted single-use
grant, and resolves every path, executable, credential, and deployment limit
from executor-owned configuration. Neither backend has an unsandboxed fallback.

## Current status

Operators can [download the actual records displayed in the SQLite workbench](docs/PORTABLE_SQLITE_WORKBENCH.md#download-the-records-you-are-inspecting)
as reusable CSV or exact typed JSON, including a table page, query result or
selected category/numeric-band members, without recreating a command-line query.

Operators can [cross two SQLite categories](docs/PORTABLE_SQLITE_CROSSTAB.md)
in a retained result, compare count matrices and inspect the original records
inside each intersection without changing or executing the artifact.

Operators can [author a bounded command REQUEST offline](docs/GRANT_REQUEST_AUTHORING.md)
using a generated local form: open a v3 template, edit individual arguments and
requested limits, preview exact scope, and download the ordinary request. This
does not approve, publish or execute a grant.

Operators can now [rehearse a grant before publishing it](docs/GRANT_REHEARSAL.md):
check the actual candidate against trusted policy, correct a field, review the
exact scope, and explicitly publish only the unchanged reviewed candidate.
Rehearsal never publishes or executes a grant.

To reconstruct interleaved events, [merge retained JSONL logs into a chronological timeline](docs/RETAINED_EVENT_TIMELINES.md)
with `browse-retention timeline --mapping timeline.json`. Select exact log paths,
a canonical UTC timestamp field, and scalar columns. Export all events with
original path/line drillback and digest-bound source/candidate context.

To locate diagnostics when the file is unknown, [search across retained run artifacts](docs/RETAINED_RUN_SEARCH.md)
with `browse-retention search-all --query error --ignore-case --prefix logs/`.
Resume path/line pages, inspect explicit binary/oversized omissions, and export
receipt-bound JSON results with exact matching-file fingerprints.

For reordered report revisions, [compare retained CSV records by key](docs/RETAINED_CSV_COMPARISON.md)
with `compare-retained-csv PATH --key-columns 1,2`. Inspect added, removed and
changed records with exact before/after cells, or export a reusable CSV review.

To inspect structured report data, [browse verified retained CSV tables](docs/RETAINED_CSV_TABLES.md)
with `browse-retention table PATH`: select columns, filter exact cell values,
continue logical-row pages and export a reusable CSV selection or provenance JSON.

To find the most frequent diagnostic groups, [summarize retained CSV rows](docs/RETAINED_CSV_SUMMARIES.md)
with `browse-retention summarize-csv checks.csv --group-by 2,3`. Export exact-key
counts with source-row drillback and candidate provenance; optional filtering
can isolate errors before grouping.

To add ownership, labels or other reference fields, [enrich retained CSV with a local lookup](docs/RETAINED_CSV_ENRICHMENT.md)
using `browse-retention enrich-csv PATH --lookup LOCAL-FILE --source-key N --lookup-key N`.
It exports a reusable left-joined CSV candidate with source, lookup and output
fingerprints, preserving every source row without changing retained evidence.

To combine partitioned reports, [consolidate retained CSV shards](docs/RETAINED_CSV_STACKS.md)
with an explicit fingerprint-bound manifest. Matching schemas produce one reusable
CSV with original file/row locators; duplicate observations remain intact. Original
artifacts stay unchanged and the candidate carries separate derivation context.

To correct a generated report before review, [edit retained CSV into a local candidate](docs/RETAINED_CSV_DRAFTS.md)
with `browse-retention edit-csv PATH --recipe local-edits.json`. Correct cells,
remove data rows or append a row using explicit sequential positions. The recipe
pins the inspected source fingerprint; original headers and retained bytes stay
unchanged, and the exported CSV carries separate recipe/candidate context.

To find diagnostic or review lines within one file, [search verified retained text](docs/RETAINED_TEXT_SEARCH.md)
with `browse-retention search PATH --query TEXT`, including line-numbered excerpts,
resumable pages, ASCII case-insensitive matching and JSON output.

For changed text, [export a verified unified diff between retained runs](docs/RETAINED_TEXT_DIFF.md)
with `cmd/diff-retention`. Inspect generated source, configuration or report
changes with context and original receipt identities.

For multi-file review, [export a selected ZIP package](docs/RETAINED_REVIEW_BUNDLE.md)
with `browse-retention bundle`, including exact artifact bytes and a receipt-bound
manifest. This is a review copy, not promotion.


For read-only iteration review, [compare two retained run inventories](docs/RETAINED_RUN_COMPARISON.md)
with `cmd/compare-retention`, then use the retained artifact browser to verify
and export selected bytes. Comparison does not execute or promote artifacts.

- `sandbox/` contains profiles, immutable digests, command preflight, receipts,
  lifecycle, private workspace materialization, scratch inventory/diff,
  promotion, and the local backend.
- Commands are pre-tokenized `Exec` values by default. Shell text is a separate
  compatibility capability and must be allow-listed explicitly.
- The local backend canonicalizes roots and executable bindings immediately
  before launch. macOS starts from `(deny default)` under `sandbox-exec`; Linux
  uses bubblewrap user/mount/PID/network namespaces, drops every capability,
  disables nested user namespaces, and mounts no host root. Both expose a
  private workspace copy, deny network access, and keep persistent writes under
  disjoint scratch.
- Availability is behaviorally probed rather than inferred from a binary:
  scratch must be writable, the canonical workspace must be unreadable and
  unwritable, and the Linux namespace must have no host network route.
- A native supervisor creates a new session/process group, applies per-process
  CPU/address-space/file-size/open-file limits, monitors the configured
  same-process-group count and aggregate scratch bytes, uses a monotonic
  deadline, caps merged output, and kills same-session descendants even after
  the direct child exits. A descendant that escapes with `setsid` cannot hang
  the monitor; the run becomes `Refused` with cleanup unverified. Local receipts
  explicitly list the aggregate CPU/memory, hard disk/process quota, inode
  quota guarantees that the shared-kernel backends cannot verify. macOS also
  names detached descendants and, when the native launcher is already above a
  requested virtual-memory ceiling, per-process address space as unverified.
  Linux counts the complete `/proc` descendant tree rather than only a process
  group, so a child calling `setsid` does not evade the sampled process ceiling.
- Scratch is inventoried without following links; changed paths are relative
  and explicit promotion revalidates fingerprints before atomic per-file
  rename. Canonical MoonBook files are never bulk-copied back.
- Missing enforcement always returns `Refused`; there is no host-process
  fallback. Local runs still report `Degraded` and require explicit opt-in
  because both `sandbox-exec` and bubblewrap share the host kernel and remain
  best-effort boundaries.
- `aen_backend/` implements bounded HTTP/Connect transport, authenticated
  content-addressed workspace provisioning, stock AEN cold-start with an
  immutable executor image and read-only workspace drive, fixed in-guest
  overlay/tool/limit attestation and supervision, structured scratch changes,
  verified lease/VM cleanup, and full lifecycle operations. Missing deployment
  components refuse rather than falling back or overclaiming enforcement.
- `executor/` owns bounded IPC, trusted workspace/tool/backend registries,
  single-use grants, complete approval/command digests, private scratch, and
  opaque TTL retention. Native ownership and permission checks reject unsafe
  configuration, registry, executable, grant-store, and parent paths before
  any backend work.
- Command output that reaches the approved hard ceiling or exceeds the
  configurable model budget is retained in a separate executor-private
  artifact spool. Small complete output stays inline and performs no artifact
  I/O. Spilled receipts contain a head/tail projection plus an opaque
  HMAC-bound reference with size, SHA-256, media type, and expiry. Reads
  revalidate the run and approval/command binding and never expose host paths.
- `cmd/executor` is the v3 approval-ID-only JSON boundary intended for
  MoonClaw. Caller-supplied profiles and backend configuration are rejected by
  construction. `cmd/grant-publisher` is the narrow validated publication
  boundary, so MoonClaw does not need direct approval-store write access.
  `cmd/promote-retention` is the digest-bound reviewed promotion boundary;
  `cmd/main` prints the contract surface for integration checks.
- `cmd/read-command-output` retrieves signed completed-output artifacts through
  bounded resumable JSON byte pages, or `--export` writes the verified complete
  file directly to stdout in one pass. It never reruns execution or promotes
  scratch. See `docs/COMMAND_OUTPUT_RETRIEVAL.md` for the operator workflow and
  the separate host-client integration boundary.
- `cmd/browse-retention` lists and filters generated files in an existing
  retained result, previews selected bytes, and exports exact verified files
  for inspection. See `docs/RETAINED_ARTIFACT_BROWSER.md` for the six-file demo,
  CLI workflow, byte limits, and the separate reviewed promotion step.
- `docs/IMPLEMENTATION_PLAN.md` is the implementation plan and security
  decision record.
- `docs/AEN_PROVISIONER_CONTRACT.md` specifies the exact trusted workspace OCI
  provisioner and immutable guest-helper deployment contract.
- `docs/COMPLETION_AUDIT.md` is the requirement-by-requirement release gate.
  A package test or fake transport does not close a row unless it proves the
  named adversarial behavior; real local-host and AEN deployment exercises are
  mandatory before a production-complete claim.
- `docs/PROMOTION_RECOVERY_INSPECTION.md` specifies the bounded, read-only
  operator evidence contract for locked promotion claims.
- `scripts/audit-moonclaw-execution-boundary.sh` is the CI enforcement gate
  that rejects raw process authority in every first-party MoonClaw production
  package. The integrated checkout currently passes; see
  `docs/EXECUTION_BOUNDARY_GUARD.md` for its narrow infrastructure allowlist
  and semantic-bypass categories.

The local backend is not a production-grade arbitrary-code sandbox. Use the
strict default for untrusted work: it selects the AEN microVM backend and
refuses execution unless the deployment independently attests every requested
limit and mount/network property.

## Inspect generated test results

[Turn retained JUnit XML into a testcase CSV](docs/RETAINED_JUNIT_REPORTS.md)
with `browse-retention junit-csv reports/tests.xml`. Review passed, failed, error,
and skipped checks with full diagnostics, exact duration strings, and original
XML source lines. Context binds the derived CSV to the original retained file.

[Inspect retained TAP test output](docs/RETAINED_TAP_REPORTS.md) with
`browse-retention tap-csv results.tap --failures`. Explore test statuses,
SKIP/TODO explanations and diagnostic text with original report-line drillback.
The accompanying context distinguishes skipped, unplanned and bailed-out runs.

## Inspect nested retained JSON

For line-oriented logs, [turn retained JSONL/NDJSON records into CSV](docs/RETAINED_JSONL_CSV.md)
with `browse-retention jsonl-csv diagnostics.jsonl --mapping columns.json`.
Choose nested scalar fields, retain exact numeric spellings, and use the generated
physical source-line column to drill back to the original record. Blank separators
require explicit `--skip-blank-lines`.


To reuse report records in a spreadsheet, [project retained JSON arrays into CSV](docs/RETAINED_JSON_CSV.md)
with `browse-retention json-csv PATH --mapping columns.json`. Choose ordered,
named columns from nested fields and retain the source/mapping/output context.

Use `browse-retention json` to navigate retained object keys and array entries,
then extract a typed subtree with its source context. See
[the retained JSON guide](docs/RETAINED_JSON_EXPLORER.md).

To correct fields, remove draft-only data, or append rows for reuse, apply a
[local JSON edit recipe](docs/RETAINED_JSON_DRAFTS.md) with
`browse-retention edit-json PATH --recipe local-edits.json`. It exports a new
candidate and source/recipe provenance while leaving the retained original
unchanged. Candidate creation is separate from review and promotion.

## Retained static-analysis findings

`browse-retention sarif-csv reports/findings.sarif < receipt-binding.json`
exports receipt-bound SARIF 2.1.0 findings across runs as CSV, resolving driver
rule and artifact indexes and retaining JSON Pointers for source drillback.
See [retained SARIF reports](docs/RETAINED_SARIF_REPORTS.md) for output, supported
inline subset and limits. This interprets existing reports; it does not execute
analysis, compute effective severity, or promote artifacts.

## Compare coverage evidence offline

[Review line-coverage changes across retained review ZIPs](docs/PORTABLE_COVERAGE_REVIEW.md)
with `python3 tools/coverage_review.py before.zip after.zip --report reports/coverage.info`.
Union repeated LCOV test observations, inspect changed coverage coordinates and
checksum conflicts, and export JSON or CSV with original receipt/report-line
provenance. This is local evidence review, not code-equivalent regression proof
or execution/promotion authority.

## Inspect retained database results

[Explore SQLite tables from a retained review ZIP](docs/PORTABLE_SQLITE_REVIEW.md)
with `python3 tools/sqlite_review.py review.zip --database results/review.sqlite schema`.
Select stored columns, exact typed filters and ordering in a local JSON recipe;
page records with source-row locators and export typed JSON/CSV with receipt,
database, selection and output fingerprints. This inspects a self-contained
database copy without modifying retained output or running the original workload.

[Find the largest groups and inspect their source rows](docs/PORTABLE_SQLITE_SUMMARIES.md)
with `summarize --selection owner-status.json`, then `group-rows` using the same
editable pinned recipe and a selected typed key. Compare exact numeric sums,
means and extrema, inspect missing/nonnumeric counts, and page through the
original records with receipt-bound locators. JSON and CSV remain local review copies.

[Follow a retained row to its referenced records](docs/PORTABLE_SQLITE_RELATIONS.md)
with the same tool's `related --selection reference.json` command. Discover
declared outgoing foreign keys in `schema`, pin the inspected database digest
and row locator, then inspect a failed sample's run or configuration. JSON/CSV
pages preserve parent locators, child reference values, and receipt context;
NULL and unmatched references remain explicit. This is read-only review.

[Inspect the records that reference a retained run or configuration](docs/PORTABLE_SQLITE_REFERENCING.md)
with `referencing --selection children.json`. Discover incoming declarations in
`schema`, select an exact parent row, filter and page its child records, and export
typed JSON/CSV with source and candidate fingerprints. Parent affinity and
collation are preserved; this is one-hop evidence inspection, not impact proof.

[Compare two retained SQLite result snapshots by typed business key](docs/PORTABLE_SQLITE_COMPARISON.md)
with `compare after.zip --selection comparison.json`. Pin both inspected database
digests, choose stable key columns, and export complete bounded added/removed/
changed records as JSON or CSV. Reordered rowids do not create changes; both
sides retain exact source locators and receipts for further inspection.
