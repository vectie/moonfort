# MoonFort handoff notes

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
