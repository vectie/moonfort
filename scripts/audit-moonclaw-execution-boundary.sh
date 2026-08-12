#!/usr/bin/env bash
# Fail closed when MoonClaw production paths can reach host process primitives
# without crossing the TrustedHostProcess / ExecutionSandbox boundary.

set -u

usage() {
  printf 'usage: %s MOONCLAW_ROOT\n' "$0" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 64
fi

moonclaw_root=$1
if [ ! -d "$moonclaw_root" ]; then
  printf 'execution-boundary audit: not a directory: %s\n' "$moonclaw_root" >&2
  exit 66
fi

moonclaw_root=$(cd "$moonclaw_root" 2>/dev/null && pwd -P) || {
  printf 'execution-boundary audit: cannot resolve root: %s\n' "$1" >&2
  exit 66
}

if [ ! -f "$moonclaw_root/moon.mod" ]; then
  printf 'execution-boundary audit: %s is not a MoonClaw source root (moon.mod missing)\n' "$moonclaw_root" >&2
  exit 66
fi

audit_tmp=$(mktemp -d "${TMPDIR:-/tmp}/moonfort-boundary-audit.XXXXXX") || exit 70
trap 'rm -rf "$audit_tmp"' EXIT HUP INT TERM
violations="$audit_tmp/violations.tsv"
: >"$violations"

# This is intentionally the only production allowlist. The adapter owns fixed,
# reviewed host utilities; agent/tool packages must call it or ExecutionSandbox.
is_trusted_host_process_path() {
  case "$1" in
    internal/trusted_host_process/*) return 0 ;;
    *) return 1 ;;
  esac
}

# File-exact exception for the v3 adapter. It may start only the
# operator-configured MoonFort grant publisher and executor.
is_execution_sandbox_adapter_path() {
  case "$1" in
    internal/execution_sandbox_adapter/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_first_party_production_source() {
  case "$1" in
    third_party/*|vendor/*|_build/*|.git/*|.mooncakes/*|tests/*|test/*|*/tests/*|*/test/*) return 1 ;;
    internal/mock/*|cmd/test-*) return 1 ;;
    *_test.mbt|*_wbtest.mbt|*/test_*.mbt) return 1 ;;
    *.mbt|*/moon.pkg|moon.pkg) return 0 ;;
    *) return 1 ;;
  esac
}

category_for_path() {
  case "$1" in
    cmd/daemon/mooncode_process_tools.mbt) printf '%s' 'mooncode-process-tools' ;;
    cmd/daemon/mooncode_tools.mbt) printf '%s' 'mooncode-patch-verification' ;;
    tools/execute_command/*) printf '%s' 'legacy-execute-command' ;;
    tools/unlimited_ocr/*|internal/pdf_ocr/*|internal/pdf_ocr_markdown/*) printf '%s' 'native-ocr-command' ;;
    tools/search_files/*) printf '%s' 'moon-search-helper' ;;
    packtool/*) printf '%s' 'installed-pack-executable' ;;
    job/manager.mbt) printf '%s' 'background-job-manager' ;;
    job/provider_task_command.mbt) printf '%s' 'provider-task-command' ;;
    job/run_workspace.mbt) printf '%s' 'job-workspace-process' ;;
    gateway/server/acp_methods.mbt|gateway/server/new.mbt|gateway/server/gateway.mbt|gateway/server/moon.pkg) printf '%s' 'gateway-acp-process' ;;
    gateway/server/robot_e1.mbt) printf '%s' 'robot-command' ;;
    acp/*) printf '%s' 'acp-process' ;;
    browser/process_host/*) printf '%s' 'browser-host-process' ;;
    internal/git/*) printf '%s' 'trusted-git-bypass' ;;
    cmd/daemon/*) printf '%s' 'daemon-host-process' ;;
    job/*) printf '%s' 'job-host-process' ;;
    tools/*) printf '%s' 'tool-host-process' ;;
    *) printf '%s' 'unclassified-host-process' ;;
  esac
}

record() {
  category=$1
  relative=$2
  line=$3
  detail=$4
  # Tabs/newlines in source details are flattened so output remains parseable.
  detail=$(printf '%s' "$detail" | tr '\t\r\n' '   ')
  printf '%s\t%s\t%s\t%s\n' "$category" "$relative" "$line" "$detail" >>"$violations"
}

scan_raw_file() {
  relative=$1
  absolute=$moonclaw_root/$relative
  category=$(category_for_path "$relative")
  # Imports and call sites are both checked. This catches all three current raw
  # process layers: async/process, moonlib/spawn, and internal/spawn.
  awk '
    /"moonbitlang\/async\/process"/ ||
    /"vectie\/moonlib\/spawn"/ ||
    /"vectie\/moonclaw\/internal\/spawn"/ ||
    /@spawn[.]spawn[[:space:]]*[(]/ ||
    /@process[.](run|spawn)[[:space:]]*[(]/ ||
    /[.]process[.]spawn[[:space:]]*[(]/ ||
    /acp_process_manager[.]spawn[[:space:]]*[(]/ ||
    /@async[.]Process/ ||
    /@process[.]Process/ {
      text=$0
      gsub(/^[[:space:]]+/, "", text)
      print NR "\t" text
    }
  ' "$absolute" | while IFS=$'\t' read -r line detail; do
    record "$category" "$relative" "$line" "raw process API: $detail"
  done
}

# MoonBit package imports can be scoped to test builds. Buffer import blocks so
# a `for "test"` / `for "wbtest"` suffix exempts only that complete block.
scan_package_file() {
  relative=$1
  absolute=$moonclaw_root/$relative
  category=$(category_for_path "$relative")
  awk '
    function raw(line) {
      return line ~ /"moonbitlang\/async\/process"/ ||
        line ~ /"vectie\/moonlib\/spawn"/ ||
        line ~ /"vectie\/moonclaw\/internal\/spawn"/
    }
    function flush(    i) {
      for (i = 1; i <= count; i++) print lines[i] "\t" texts[i]
      delete lines
      delete texts
      count = 0
    }
    /^[[:space:]]*import[[:space:]]*\{/ {
      in_import = 1
      count = 0
    }
    in_import && raw($0) {
      count++
      lines[count] = NR
      text = $0
      gsub(/^[[:space:]]+/, "", text)
      texts[count] = text
    }
    in_import && /}[[:space:]]*for[[:space:]]*"(test|wbtest)"/ {
      delete lines
      delete texts
      count = 0
      in_import = 0
      next
    }
    in_import && /}/ {
      flush()
      in_import = 0
    }
    END { if (in_import) flush() }
  ' "$absolute" | while IFS=$'\t' read -r line detail; do
    record "$category" "$relative" "$line" "raw process API: $detail"
  done
}

while IFS= read -r -d '' absolute; do
  relative=${absolute#"$moonclaw_root"/}
  is_first_party_production_source "$relative" || continue
  is_trusted_host_process_path "$relative" && continue
  is_execution_sandbox_adapter_path "$relative" && continue
  case "$relative" in
    */moon.pkg|moon.pkg) scan_package_file "$relative" ;;
    *) scan_raw_file "$relative" ;;
  esac
done < <(
  find "$moonclaw_root" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -print0
)

# Semantic bypasses do not necessarily contain the low-level call at the same
# site. Keep these checks explicit so a refactor cannot make a known category
# disappear from the report while leaving the bypass intact.
record_matches() {
  category=$1
  relative=$2
  pattern=$3
  description=$4
  absolute=$moonclaw_root/$relative
  [ -f "$absolute" ] || return 0
  grep -nE "$pattern" "$absolute" 2>/dev/null | while IFS=: read -r line detail; do
    record "$category" "$relative" "$line" "$description: $detail"
  done
}

tool_exec_file=cmd/daemon/mooncode_tools.mbt
if [ -f "$moonclaw_root/$tool_exec_file" ]; then
  awk '
    /async fn Daemon::mooncode_tool_execute[(]/ { active=1 }
    active && /mooncode_execute_tool_call(_in_runtime)?[(]/ {
      text=$0
      gsub(/^[[:space:]]+/, "", text)
      print NR "\t" text
    }
    active && /^}/ { exit }
  ' "$moonclaw_root/$tool_exec_file" | while IFS=$'\t' read -r line detail; do
    record 'direct-tool-exec-approval-bypass' "$tool_exec_file" "$line" \
      "direct /tool-exec path enters dispatcher without an approved sandbox grant: $detail"
  done
fi

process_tools=cmd/daemon/mooncode_process_tools.mbt
runtime_turn=cmd/daemon/mooncode_runtime_turn.mbt
sandbox_gate=cmd/daemon/mooncode_execution_sandbox_gate.mbt

# Positive command routes are permitted only when the dispatcher selects the
# reviewed wrapper and that wrapper names the closed ExecutionSandbox API. The
# all-first-party scan above remains authoritative for raw process primitives;
# these checks add semantic dispatch/approval requirements without exempting a
# single source file from raw-process detection.
if grep -q '"shell"[[:space:]]*=>' "$moonclaw_root/$tool_exec_file" 2>/dev/null; then
  if ! grep -q 'mooncode_tool_shell_in_runtime' "$moonclaw_root/$tool_exec_file" 2>/dev/null || \
    ! grep -q '@execution_sandbox[.]run_approved_shell[(]' "$moonclaw_root/$process_tools" 2>/dev/null || \
    ! grep -q 'mooncode_runtime_bind_sandbox_approval_plan[(]' "$moonclaw_root/$runtime_turn" 2>/dev/null || \
    ! grep -q 'mooncode_runtime_authorized_tool_call[(]' "$moonclaw_root/$runtime_turn" 2>/dev/null || \
    ! grep -q 'mooncode_prepare_shell_approval_plan[(]' "$moonclaw_root/$sandbox_gate" 2>/dev/null; then
    record 'mooncode-command-dispatch' "$process_tools" 1 \
      'shell dispatch is not bound to an exact approved ExecutionSandbox grant'
  fi
fi

if grep -q '"moon_ide"[[:space:]]*=>[[:space:]]*mooncode_tool_moon_ide' \
    "$moonclaw_root/$tool_exec_file" 2>/dev/null && \
  ! grep -q '@execution_sandbox[.]run_exec[(]' \
    "$moonclaw_root/$process_tools" 2>/dev/null; then
  record 'mooncode-command-dispatch' "$process_tools" 1 \
    'moon_ide dispatch is not bound to the typed ExecutionSandbox route'
fi

if grep -q '"moon_cmd"[[:space:]]*=>[[:space:]]*mooncode_tool_moon_cmd' \
    "$moonclaw_root/$tool_exec_file" 2>/dev/null; then
  if ! grep -q '@execution_sandbox[.]run_exec[(]' "$moonclaw_root/$process_tools" 2>/dev/null || \
    ! grep -q '@execution_sandbox[.]run_approved_exec[(]' "$moonclaw_root/$process_tools" 2>/dev/null || \
    ! grep -q 'mooncode_prepare_moon_cmd_approval_plan[(]' "$moonclaw_root/$sandbox_gate" 2>/dev/null || \
    ! grep -q 'mooncode_runtime_bind_sandbox_approval_plan[(]' "$moonclaw_root/$runtime_turn" 2>/dev/null || \
    ! grep -q 'mooncode_runtime_authorized_tool_call[(]' "$moonclaw_root/$runtime_turn" 2>/dev/null; then
    record 'mooncode-command-dispatch' "$process_tools" 1 \
      'moon_cmd dispatch is not bound to typed and exact-approved ExecutionSandbox routes'
  fi
fi

# `moon_check` is the first positive typed route. It is allowed only while its
# implementation calls the closed v3 ExecutionSandbox operation; raw process
# use remains covered by the all-first-party scan above.
moon_check_file=cmd/daemon/mooncode_process_tools.mbt
if grep -q '"moon_check"[[:space:]]*=>[[:space:]]*mooncode_tool_moon_check' \
    "$moonclaw_root/cmd/daemon/mooncode_tools.mbt" 2>/dev/null && \
  ! grep -q '@execution_sandbox[.]run_moon_check[(]' \
    "$moonclaw_root/$moon_check_file" 2>/dev/null; then
  record 'mooncode-command-dispatch' "$moon_check_file" 1 \
    'moon_check dispatch is not bound to the typed ExecutionSandbox route'
fi

record_matches 'worktree-isolation-fallback' \
  'job/execution_isolation.mbt' \
  'return ExecutionIsolationResolution::new\(cwd=fallback_cwd\)' \
  'worktree setup error silently falls back to the canonical/shared workspace'

# Authorization snapshots must bind moon_cmd. Its omission allows approval and
# the eventual process invocation to describe different authority.
runtime_tools=mooncode/core/runtime_tools.mbt
if [ -f "$moonclaw_root/$runtime_tools" ]; then
  snapshot_block=$(awk '
    /pub fn runtime_tool_requires_authorization_snapshot/ { active=1 }
    active { print }
    active && /^}/ { exit }
  ' "$moonclaw_root/$runtime_tools")
  if [ -n "$snapshot_block" ] && ! printf '%s\n' "$snapshot_block" | grep -q 'runtime_tool_moon_cmd()'; then
    snapshot_line=$(grep -n 'pub fn runtime_tool_requires_authorization_snapshot' "$moonclaw_root/$runtime_tools" | awk -F: 'NR == 1 { print $1 }')
    record 'authorization-snapshot-gap' "$runtime_tools" "${snapshot_line:-1}" \
      'runtime_tool_requires_authorization_snapshot omits moon_cmd'
  fi
fi

if [ ! -s "$violations" ]; then
  printf 'MoonFort execution-boundary audit: PASS\n'
  printf 'No raw process or known semantic bypass was found outside TrustedHostProcess.\n'
  exit 0
fi

printf 'MoonFort execution-boundary audit: FAIL\n'
printf 'MoonClaw root: %s\n' "$moonclaw_root"
printf 'Raw process authority is permitted only under internal/trusted_host_process/.\n'
printf '\nViolations by category:\n'
cut -f1 "$violations" | sort | uniq -c | awk '{ printf "  %-36s %s\n", $2, $1 }'
printf '\nAll violations:\n'
sort -t $'\t' -k1,1 -k2,2 -k3,3n "$violations" | \
  awk -F '\t' '{ printf "  [%s] %s:%s\n      %s\n", $1, $2, $3, $4 }'
printf '\nRequired boundary: route untrusted execution through ExecutionSandbox; use\n'
printf 'TrustedHostProcess only for fixed, reviewed host infrastructure commands.\n'
exit 1
