#!/usr/bin/env bash
set -euo pipefail

readonly acknowledgement='I_UNDERSTAND_THIS_RUNS_HOSTILE_CODE_ON_REAL_AEN'
readonly max_report_bytes=262144

fail() {
  printf 'real-AEN canary workflow refused: %s\n' "$1" >&2
  exit 1
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

if [[ $# -ne 3 ]]; then
  fail 'expected CANARY_BINARY, PRIVATE_CONFIG_DIRECTORY, and EVIDENCE_DIRECTORY'
fi

readonly canary_binary=$1
readonly config_directory=$2
readonly evidence_directory=$3
readonly runner_temp=${RUNNER_TEMP:-}
readonly report_path="${evidence_directory}/canary-report.json"
readonly revision_path="${evidence_directory}/revision-evidence.json"

[[ -x $canary_binary && ! -L $canary_binary ]] ||
  fail 'native canary executable is unavailable or unsafe'
[[ $runner_temp == /* && -d $runner_temp && ! -L $runner_temp ]] ||
  fail 'RUNNER_TEMP is not a trusted absolute directory'
[[ $config_directory == "${runner_temp%/}/moonfort-real-aen-config."* &&
  -d $config_directory && ! -L $config_directory ]] ||
  fail 'private config directory is not a trusted RUNNER_TEMP child'
[[ $evidence_directory == "${runner_temp%/}/moonfort-real-aen-evidence."* &&
  -d $evidence_directory && ! -L $evidence_directory ]] ||
  fail 'evidence directory is not a trusted RUNNER_TEMP child'
[[ $(file_mode "$config_directory") == 700 ]] ||
  fail 'private config directory permissions are not 0700'
[[ $(file_mode "$evidence_directory") == 700 ]] ||
  fail 'evidence directory permissions are not 0700'

cleanup() {
  unset REAL_AEN_CANARY_CONFIG_JSON REAL_AEN_EXECUTOR_CONFIG_JSON
  if [[ -n ${config_directory:-} && -d $config_directory &&
    ! -L $config_directory ]]; then
    rm -f -- \
      "$config_directory/canary-template.json" \
      "$config_directory/canary.json" \
      "$config_directory/executor.json" \
      "$config_directory/raw-report.json" \
      "$config_directory/canary-stderr.log"
    rmdir -- "$config_directory" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

[[ -n ${REAL_AEN_HOSTILE_RUN_ACKNOWLEDGEMENT:-} ]] ||
  fail 'hostile-run acknowledgement input is absent'
[[ ${REAL_AEN_HOSTILE_RUN_ACKNOWLEDGEMENT} == "$acknowledgement" ]] ||
  fail 'hostile-run acknowledgement input is not exact'
[[ -n ${REAL_AEN_CANARY_CONFIG_JSON:-} ]] ||
  fail 'protected canary configuration secret is absent'
[[ -n ${REAL_AEN_EXECUTOR_CONFIG_JSON:-} ]] ||
  fail 'protected executor configuration secret is absent'

for value in \
  "${GITHUB_SHA:-}" \
  "${REAL_AEN_DEPLOYMENT_REVISION:-}" \
  "${REAL_AEN_PROVISIONER_REVISION:-}"; do
  [[ $value =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] ||
    fail 'revision evidence is absent or not a lowercase 40/64-hex digest'
done
[[ ${REAL_AEN_REGISTRY_MANIFEST_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail 'registry manifest evidence is absent or invalid'
[[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] ||
  fail 'GitHub run identity is unavailable'
[[ ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]] ||
  fail 'GitHub run attempt is unavailable'

umask 077
readonly canary_template_path="${config_directory}/canary-template.json"
readonly canary_config_path="${config_directory}/canary.json"
readonly executor_config_path="${config_directory}/executor.json"
readonly raw_report_path="${config_directory}/raw-report.json"
readonly canary_stderr_path="${config_directory}/canary-stderr.log"

printf '%s' "$REAL_AEN_CANARY_CONFIG_JSON" >"$canary_template_path"
printf '%s' "$REAL_AEN_EXECUTOR_CONFIG_JSON" >"$executor_config_path"
unset REAL_AEN_CANARY_CONFIG_JSON REAL_AEN_EXECUTOR_CONFIG_JSON
chmod 600 "$canary_template_path" "$executor_config_path"

[[ $(wc -c <"$canary_template_path") -le 262144 ]] ||
  fail 'canary configuration secret exceeds its byte bound'
[[ $(wc -c <"$executor_config_path") -le 1048576 ]] ||
  fail 'executor configuration secret exceeds its byte bound'

jq -e --arg executor_path "$executor_config_path" \
  --arg acknowledgement "$acknowledgement" '
    if type != "object" then error("canary template must be an object")
    elif .real_aen_acknowledgement != $acknowledgement then
      error("canary template acknowledgement is not exact")
    elif .executor_config_path != "__INJECTED_BY_REAL_AEN_CANARY_WORKFLOW__" then
      error("canary template executor path placeholder is not exact")
    else .executor_config_path = $executor_path end
  ' "$canary_template_path" >"$canary_config_path"
chmod 600 "$canary_config_path"

executor_image_digest=$(jq -er \
  '.expected_executor_image_ref |
   capture("@sha256:(?<digest>[0-9a-f]{64})$").digest' \
  "$canary_config_path")
[[ $executor_image_digest =~ ^[0-9a-f]{64}$ ]] ||
  fail 'executor image digest pin is unavailable'

jq -n \
  --arg moonfort_revision "$GITHUB_SHA" \
  --arg deployment_revision "$REAL_AEN_DEPLOYMENT_REVISION" \
  --arg provisioner_revision "$REAL_AEN_PROVISIONER_REVISION" \
  --arg registry_manifest_digest "$REAL_AEN_REGISTRY_MANIFEST_DIGEST" \
  --arg executor_image_digest "sha256:${executor_image_digest}" \
  --argjson github_run_id "$GITHUB_RUN_ID" \
  --argjson github_run_attempt "$GITHUB_RUN_ATTEMPT" '
    {
      protocol_version: 1,
      moonfort_revision: $moonfort_revision,
      deployment_revision: $deployment_revision,
      provisioner_revision: $provisioner_revision,
      registry_manifest_digest: $registry_manifest_digest,
      executor_image_digest: $executor_image_digest,
      github_run_id: $github_run_id,
      github_run_attempt: $github_run_attempt
    }
  ' >"$revision_path"
chmod 600 "$revision_path"

ulimit -f 512 2>/dev/null || fail 'report file-size limit is unavailable'
set +e
MOONFORT_AEN_CANARY_CONFIG="$canary_config_path" \
  "$canary_binary" >"$raw_report_path" 2>"$canary_stderr_path"
canary_status=$?
set -e
chmod 600 "$canary_stderr_path"

valid_report=true
if [[ ! -f $raw_report_path || -L $raw_report_path ]] ||
  [[ $(wc -c <"$raw_report_path") -gt $max_report_bytes ]]; then
  valid_report=false
fi

if $valid_report && jq -e '
    type == "object" and
    .protocol_version == 2 and
    (.workspace_id | type == "string" and length <= 128 and
      test("^[A-Za-z0-9_-]*$")) and
    (.backend_config_id | type == "string" and length <= 128 and
      test("^[A-Za-z0-9_-]*$")) and
    (.passed | type == "boolean") and
    (.error == null or
      (.error | type == "string" and length <= 512)) and
    (.cases | type == "array" and length <= 9) and
    all(.cases[];
      type == "object" and
      (.name | type == "string" and length <= 64 and
        test("^[a-z0-9-]+$")) and
      (.passed | type == "boolean") and
      (.status == null or
        (.status | IN("Pending", "Running", "Exited", "Killed", "Stopped", "Refused"))) and
      (.enforcement == null or
        (.enforcement | IN("Enforced", "Degraded", "Refused"))) and
      (.output_bytes | type == "number" and floor == . and . >= 0 and . <= 65536) and
      (.output_truncated | type == "boolean") and
      (.limit_reason == null or
        (.limit_reason | type == "string" and length <= 64 and
          test("^[a-z0-9_-]+$"))) and
      (.changed_path_count | type == "number" and floor == . and . >= 0 and . <= 4096) and
      (.change_count | type == "number" and floor == . and . >= 0 and . <= 4096) and
      (.artifact_count | type == "number" and floor == . and . >= 0 and . <= 4096) and
      (.cleanup_verified | type == "boolean") and
      (.failures | type == "array" and length <= 32 and
        all(.[]; type == "string" and length <= 512)))
  ' "$raw_report_path" >/dev/null; then
  jq '{
    protocol_version,
    workspace_id,
    backend_config_id,
    passed,
    cases: [.cases[] | {
      name,
      passed,
      status,
      enforcement,
      output_bytes,
      output_truncated,
      limit_reason,
      changed_path_count,
      change_count,
      artifact_count,
      cleanup_verified,
      failures
    }],
    error
  }' "$raw_report_path" >"$report_path"
else
  valid_report=false
  jq -n '{
    protocol_version: 2,
    workspace_id: "",
    backend_config_id: "",
    passed: false,
    cases: [],
    error: "canary process did not produce one valid bounded report"
  }' >"$report_path"
fi
chmod 600 "$report_path"

[[ $valid_report == true ]] || fail 'canary report validation failed closed'
[[ $canary_status -eq 0 ]] || fail 'real-AEN hostile canary failed'
jq -e '.passed == true and .error == null and (.cases | length == 9) and
  all(.cases[]; .passed == true and .cleanup_verified == true)' \
  "$report_path" >/dev/null || fail 'canary report does not prove all cases'

printf 'real-AEN hostile canary passed; sanitized evidence is ready for archival\n'
