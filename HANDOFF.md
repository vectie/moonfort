# MoonFort handoff notes

## Retention footprint 2026-11-07

- Only reviewable_files are exposed/read/promoted, but retain_scratch kept the
  entire copied workspace. Actual MoonCode disk exhaustion followed repeated
  snapshots whose sole declared change was .git/index. Retention now keeps only
  verified manifest files plus their ancestor directories, before publishing the
  same record. No API, TTL, grant, retry or state change; original workspace and
  separate output artifacts are untouched. No old-record cleanup migration.
- Existing retention/TTL test red -> green: two retained files/16 bytes survive;
  an unlisted 1 MiB cache and unused sibling disappear. No extra inventory/hash
  pass; recursive cleanup reuses existing no-follow discard for unused trees.
- First required-E2E suite failed 23 missing compiled CLI environment paths
  (276/299); release build plus existing browse/compare/diff/output reader CLI
  paths resolves setup: final required-E2E Native 299/299, real sandbox-exec and
  artifact/promotion/TTL checks. Info/fmt passes, public interfaces unchanged.
  Do not count this as model/provider usage or hide the failed setup.
- Sibling report: moondesk/docs/
  MOONCODE_RESOURCE_AND_FRAMEWORK_COMPARISON_2026-11-07.md. Peer tests cover
  actual retention primitives, not complete live Agent deliveries. Shared model
  configuration is still required for the requested four-framework live run.

## Hashing cost and I/O cause 2026-11-07

- The live adapter pointed at debug executables. Original Shell replay took
  12039/11716/11484 ms; samples show SHA-256/SIMD. Release old implementation
  took 4897/3405/3350 ms, after removing retention's third whole inventory
  3219/2608/2720 ms. Same grant/limits; original single timeout not reproduced
  under identical CPU load. Do not claim every historical millisecond proven.
- retain_scratch now rechecks only declared files via the existing confined
  inspect_sandbox_destination, keeping sizes/digests. Execution still inventories
  before/after; existing retention test covers wrong digest then valid content.
- Snapshot refusals erased the underlying StorageIo message. It now survives;
  actual permission-denied regression red -> green, final Native 299/299 with
  real local E2E. No added API/FFI/state/permission or timeout changes.
- Experimental copies contributed to host disk exhaustion. Freed 10 diagnostic
  and 24 completed .git/index-only private snapshots after saving manifests and
  declared files; output artifacts/journals/costs preserved. This was operator
  maintenance, not a new runtime retention policy. Preflight free space before
  another live test, and include whole-snapshot/build storage costs.
- Full provider cost 935131 input/6169 output across two attempts plus recovery;
  not a lower-cost or fully unattended success. Sibling report:
  ../moondesk/docs/MOONCODE_SHELL_ROOT_CAUSE_AUDIT_2026-11-07.md.
  User workbench edits and unrelated formatter migrations remain untouched.

## SDK and snapshot fidelity follow-up 2026-11-06

- Default Exec moon ide outline failed under private HOME; the same sandbox
  command succeeded with explicit SDK home/PATH. Existing macOS invocation
  now derives MOON_HOME from a resolved SDK/bin/moon binding, while HOME stays
  private. No inherited host environment, added config API or expanded roots.
  Native compiler/SDK selection still uses the documented explicit Shell.
- Snapshot files now retain execute bits from the open source fd, in addition
  to private read/write permissions. Existing E2E gained a copied executable:
  red with Permission denied, green after fix. Actual Git snapshot no longer
  reports unchanged scripts as mode edits. One private fstat C helper only.
- Native 298/298, including required real local E2E and one SDK environment
  regression. Public interfaces unchanged. Unrelated formatter migrations and
  pre-existing SQLite workbench files are outside this task's commit.
- A single live Git invocation timed out (20s grant, 25s transport); exact
  independent replay succeeded, root cause undetermined. No blanket timeout
  increase, new retry/recovery mechanism or isolation guarantee.
- Full comparison: ../moondesk/docs/MOONCODE_TOKEN_AUDIT_FOLLOWUP_2026-11-06.md.

## Timeout diagnostics 2026-11-06

- Actual MoonCode task repeated 18 refused calls because MoonClaw replaced
  publisher errors with generic text. Claw now preserves code/message; the
  existing validate_limits message includes requested milliseconds and the
  deployment ceiling. No policy/ceiling/retry changes or new abstraction.
- Existing Native suite 297/297 passed, including required real local E2E.
  Info/fmt completed; unrelated formatter migrations were restored. Existing
  SQLite workbench changes remain outside this task's commit.
- Snapshot creation currently copies executable files as 0600. A real Git
  snapshot therefore reports mode changes for unchanged executable scripts;
  canonical main was unchanged. Recorded as an unresolved fidelity issue,
  without extending filesystem implementation during this token audit.
- Full three-run audit and real peer-task comparison:
  ../moondesk/docs/MOONCODE_TOKEN_AUDIT_2026-11-06.md.

## Full-repository Native execution 2026-11-06

- Existing Shell works with explicit MOON_HOME / CLT compiler, ar, SDKROOT,
  DEVELOPER_DIR and PATH; command documented in docs/EXECUTOR_CONFIG.md. No new
  environment API or launcher. A new scratch target directory proved cold
  Native compilation of actual MoonLib main, not reuse of cached binaries.
- Reused the metadata ancestor loop for trusted read/tool roots as well as
  scratch; clang otherwise cannot resolve itself. Diagnostic broad /Library
  access was removed. The existing policy test was extended (red then green).
- Actual full tests repeatedly hit monitor_unverified / aggregate_disk when
  temporary entries vanished during a sample. Ignore only vanished/replaced
  entries until the next sample, never follow their links. Preserve errno from
  fstatat so a missing child is distinguishable from an actual access failure.
  One churn regression reproduces failure in original C and passes after fix.
- Final Native 297/297 includes required real local E2E and the new regression.
  Final real-model full-repository Native 108/108; independent acceptance passed.
  LocalOs remains Degraded. This is not a hard filesystem-quota or MicroVM claim.
- Test fixtures that use the tested async/fs tmpdir still target host /tmp;
  use existing MoonLib os.tmpdir/fsx helpers instead of opening /tmp. Report and
  all three model attempts: ../moondesk/docs/MOONCODE_LIVE_NATIVE_REPOSITORY_2026-11-06.md.

## Real MoonCode deployment 2026-11-06

- Read docs/MOONCLAW_INTEGRATION.md and docs/EXECUTOR_CONFIG.md before runtime
  changes. This task used existing LocalOs/AllowDegraded, with real sandbox-exec
  receipts, never a host fallback or an Enforced production-isolation claim.
- Actual moon commands exposed missing ancestor metadata access for getcwd,
  system-only PATH hiding sibling moon-ide, and denied /dev/null redirection.
  Local macOS invocation now prefixes the trusted executable directory; policy
  allows scratch-ancestor metadata and null-device write-data. No inherited
  environment, new backend, configuration field or approval workflow.
- Existing publisher/local E2E checks helper PATH, /bin/pwd -P redirected to
  /dev/null, scratch mutation and canonical-write refusal. Live IDE probe exit 0;
  model's Wasm GC core test passed. Native MoonBit compilation still needs a
  valid Xcode-selection deployment; do not claim that path passed in sandbox.
- Full tests require existing compiled CLI environment variables:
  MOONFORT_ARTIFACT_READER_CLI (browse-retention), MOONFORT_COMPARISON_CLI
  (compare-retention), MOONFORT_TEXT_DIFF_CLI (diff-retention), and
  MOONFORT_CSV_COMPARE_CLI (compare-retained-csv). Set
  MOONFORT_REQUIRE_LOCAL_E2E=1 to require the real local execution path.
- Final Native regression: 296/296, including the required real local E2E;
  info/fmt and public interface/whitespace checks completed.
- Current formatter also migrates old Int/optional-argument spellings across
  untouched files. Keep bug diffs scoped; do not mix these automatic migrations
  or pre-existing SQLite workbench changes into this commit.
- Evaluation evidence/report is in sibling MoonDesk:
  docs/MOONCODE_LIVE_EXECUTOR_BUGFIX_2026-11-06.md. Private run configuration and
  signing keys are outside Git at /Users/kq/mooncode-live2-20261106.
