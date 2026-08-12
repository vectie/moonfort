#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
workflow="$repo_root/.github/workflows/real-aen-canary.yml"
runner="$repo_root/scripts/run-real-aen-canary.sh"

fail() {
  printf 'real-AEN workflow contract failed: %s\n' "$1" >&2
  exit 1
}

[[ -f $workflow && ! -L $workflow ]] || fail 'workflow is missing or linked'
[[ -x $runner && ! -L $runner ]] || fail 'runner is missing, linked, or non-executable'
! grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$workflow" ||
  fail 'production canary must be workflow_dispatch only'
grep -Eq '^  workflow_dispatch:$' "$workflow" || fail 'dispatch trigger is absent'
grep -Fq 'runs-on: [self-hosted, linux, x64, moonfort-aen-canary-ephemeral]' "$workflow" ||
  fail 'dedicated self-hosted runner labels are absent'
grep -Fq 'environment: moonfort-real-aen-canary' "$workflow" ||
  fail 'protected environment binding is absent'
grep -Fq "if: github.ref == 'refs/heads/main'" "$workflow" ||
  fail 'production canary is not restricted to the main branch'
grep -Fq "if: always() && env.MOONFORT_CANARY_EVIDENCE_DIR != ''" "$workflow" ||
  fail 'artifact upload does not refuse an unset evidence directory'
grep -Fq 'REAL_AEN_CANARY_CONFIG_JSON: ${{ secrets.REAL_AEN_CANARY_CONFIG_JSON }}' "$workflow" ||
  fail 'canary config is not sourced from an environment secret'
grep -Fq 'REAL_AEN_EXECUTOR_CONFIG_JSON: ${{ secrets.REAL_AEN_EXECUTOR_CONFIG_JSON }}' "$workflow" ||
  fail 'executor config is not sourced from an environment secret'
if grep -E '^[[:space:]]*uses:' "$workflow" |
  grep -Ev '^[[:space:]]*uses: [^@[:space:]]+@[0-9a-f]{40}([[:space:]]+#.*)?$'; then
  fail 'every action must be pinned to an immutable commit SHA'
fi
[[ $(grep -Ec '^            \$\{\{ env\.MOONFORT_CANARY_EVIDENCE_DIR \}\}/[^/]+\.json$' "$workflow") -eq 2 ]] ||
  fail 'artifact upload must name exactly two JSON evidence files'

test_root=$(mktemp -d "${TMPDIR:-/tmp}/moonfort-real-aen-workflow-test.XXXXXXXX")
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM
chmod 700 "$test_root"
mkdir -m 700 "$test_root/moonfort-real-aen-config.failure"
mkdir -m 700 "$test_root/moonfort-real-aen-evidence.test"

fake_canary="$test_root/fake-canary"
cat >"$fake_canary" <<'FAKE_CANARY'
#!/usr/bin/env bash
set -euo pipefail
[[ -f ${MOONFORT_AEN_CANARY_CONFIG:?} ]]
mode=$(stat -c '%a' "$MOONFORT_AEN_CANARY_CONFIG" 2>/dev/null || \
  stat -f '%Lp' "$MOONFORT_AEN_CANARY_CONFIG")
[[ $mode == 600 ]]
executor_path=$(jq -er '.executor_config_path' "$MOONFORT_AEN_CANARY_CONFIG")
[[ $executor_path == /* && -f $executor_path ]]
mode=$(stat -c '%a' "$executor_path" 2>/dev/null || stat -f '%Lp' "$executor_path")
[[ $mode == 600 ]]
printf 'fake-sensitive-stderr-must-not-reach-job-log\n' >&2
jq -n '{
  protocol_version: 2,
  workspace_id: "aen-canary",
  backend_config_id: "production",
  passed: true,
  cases: [range(0; 9) | {
    name: ("case-" + tostring), passed: true, status: "Exited",
    enforcement: "Enforced", output_bytes: 0, output_truncated: false,
    limit_reason: null, changed_path_count: 0, change_count: 0,
    artifact_count: 0, cleanup_verified: true, failures: []
  }],
  error: null
}'
FAKE_CANARY
chmod 700 "$fake_canary"

canary_template='{"protocol_version":2,"real_aen_acknowledgement":"I_UNDERSTAND_THIS_RUNS_HOSTILE_CODE_ON_REAL_AEN","executor_config_path":"__INJECTED_BY_REAL_AEN_CANARY_WORKFLOW__","expected_executor_image_ref":"registry.invalid/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
common_env=(
  RUNNER_TEMP="$test_root"
  GITHUB_SHA=1111111111111111111111111111111111111111
  GITHUB_RUN_ID=123
  GITHUB_RUN_ATTEMPT=1
  REAL_AEN_HOSTILE_RUN_ACKNOWLEDGEMENT=I_UNDERSTAND_THIS_RUNS_HOSTILE_CODE_ON_REAL_AEN
  REAL_AEN_DEPLOYMENT_REVISION=2222222222222222222222222222222222222222
  REAL_AEN_PROVISIONER_REVISION=3333333333333333333333333333333333333333
  REAL_AEN_REGISTRY_MANIFEST_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
)

if env "${common_env[@]}" "$runner" "$fake_canary" \
  "$test_root/moonfort-real-aen-config.failure" \
  "$test_root/moonfort-real-aen-evidence.test" \
  >/dev/null 2>&1; then
  fail 'missing protected secrets did not refuse'
fi
[[ ! -e $test_root/moonfort-real-aen-config.failure ]] ||
  fail 'failed run left a private config directory behind'

mkdir -m 700 "$test_root/moonfort-real-aen-config.success"
workflow_output=$(env "${common_env[@]}" \
  REAL_AEN_CANARY_CONFIG_JSON="$canary_template" \
  REAL_AEN_EXECUTOR_CONFIG_JSON='{}' \
  "$runner" "$fake_canary" "$test_root/moonfort-real-aen-config.success" \
  "$test_root/moonfort-real-aen-evidence.test" 2>&1)
[[ $workflow_output != *fake-sensitive-stderr-must-not-reach-job-log* ]] ||
  fail 'canary stderr reached the workflow log channel'

jq -e '.passed == true and (.cases | length == 9)' \
  "$test_root/moonfort-real-aen-evidence.test/canary-report.json" >/dev/null
jq -e '.protocol_version == 1 and
  .executor_image_digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .registry_manifest_digest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$test_root/moonfort-real-aen-evidence.test/revision-evidence.json" >/dev/null
[[ ! -e $test_root/moonfort-real-aen-config.success ]] ||
  fail 'successful run left a private config directory behind'

printf 'real-AEN workflow contract passed\n'
