#!/usr/bin/env bash

set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
guard=$repo_root/scripts/audit-moonclaw-execution-boundary.sh
fixture=$(mktemp -d "${TMPDIR:-/tmp}/moonfort-boundary-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

mkdir -p \
  "$fixture/cmd/daemon" \
  "$fixture/tools/execute_command" \
  "$fixture/packtool" \
  "$fixture/job" \
  "$fixture/gateway/server" \
  "$fixture/browser/process_host" \
  "$fixture/feature/new_runtime" \
  "$fixture/internal/git" \
  "$fixture/internal/spawn" \
  "$fixture/internal/pdf_ocr" \
  "$fixture/internal/execution_sandbox_adapter" \
  "$fixture/internal/rogue_process_user" \
  "$fixture/internal/test_import_fixture" \
  "$fixture/internal/trusted_host_process" \
  "$fixture/mooncode/core"

printf '{"name":"test/moonclaw"}\n' >"$fixture/moon.mod"
printf 'import { "vectie/moonclaw/internal/spawn" }\nlet p = @spawn.spawn("sh", [])\nasync fn Daemon::mooncode_tool_execute() {\n  mooncode_execute_tool_call_in_runtime(None, id, root, body, now)\n}\n"shell" =>\n  run()\n' \
  >"$fixture/cmd/daemon/mooncode_tools.mbt"
printf 'import { "vectie/moonlib/spawn" }\n@spawn.spawn("sh", [])\n' \
  >"$fixture/tools/execute_command/tool.mbt"
printf '@spawn.spawn(command, args)\n' >"$fixture/packtool/command_executor.mbt"
printf '@execute_command.new(cwd)\n' >"$fixture/job/analysis_contracts.mbt"
printf '@spawn.spawn(config.executor_path, config.executor_args)\n' \
  >"$fixture/internal/execution_sandbox_adapter/adapter.mbt"
printf 'return ExecutionIsolationResolution::new(cwd=fallback_cwd)\n' \
  >"$fixture/job/execution_isolation.mbt"
printf '@spawn.spawn(command, args)\n' >"$fixture/job/provider_task_command.mbt"
printf 'acp_process_manager.spawn(command, args)\n' \
  >"$fixture/gateway/server/acp_methods.mbt"
printf 'import { "moonbitlang/async/process" }\n@process.run(command, args)\n' \
  >"$fixture/internal/spawn/manager.mbt"
printf 'import { "vectie/moonclaw/internal/spawn" }\n' \
  >"$fixture/internal/rogue_process_user/moon.pkg"
printf 'import { "vectie/moonlib/spawn" }\n@spawn.spawn(executable, arguments)\n' \
  >"$fixture/browser/process_host/adapter.mbt"
printf 'import { "vectie/moonlib/spawn" }\n@spawn.spawn("git", ["ls-files"])\n' \
  >"$fixture/internal/git/list_files.mbt"
printf 'import { "moonbitlang/async/process" }\n@process.run(executable, arguments)\n' \
  >"$fixture/feature/new_runtime/runner.mbt"
printf '@spawn.spawn(python, args)\n' >"$fixture/internal/pdf_ocr/ocr.mbt"
printf 'pub fn runtime_tool_requires_authorization_snapshot(tool_name : String) -> Bool {\n  tool_name == runtime_tool_shell()\n}\n' \
  >"$fixture/mooncode/core/runtime_tools.mbt"

# Raw process use in the sole infrastructure allowlist must not be reported.
printf 'import { "moonbitlang/async/process" }\n@process.run(command, args)\n' \
  >"$fixture/internal/trusted_host_process/adapter.mbt"
# Test-only process calls are excluded from the production gate.
printf '@spawn.spawn("sh", [])\n' >"$fixture/job/ignored_wbtest.mbt"
printf 'import {\n  "vectie/moonlib/spawn",\n} for "test"\n' \
  >"$fixture/internal/test_import_fixture/moon.pkg"

output=$fixture/output.txt
if bash "$guard" "$fixture" >"$output" 2>&1; then
  printf 'expected guard to reject the unsafe fixture\n' >&2
  exit 1
fi

for category in \
  direct-tool-exec-approval-bypass \
  mooncode-command-dispatch \
  legacy-execute-command \
  installed-pack-executable \
  worktree-isolation-fallback \
  provider-task-command \
  gateway-acp-process \
  browser-host-process \
  trusted-git-bypass \
  unclassified-host-process \
  native-ocr-command \
  authorization-snapshot-gap
do
  grep -q "\[$category\]" "$output" || {
    printf 'missing category: %s\n' "$category" >&2
    sed -n '1,240p' "$output" >&2
    exit 1
  }
done

for expected_path in \
  browser/process_host/adapter.mbt \
  internal/git/list_files.mbt \
  feature/new_runtime/runner.mbt
do
  grep -q "$expected_path" "$output" || {
    printf 'guard did not scan first-party source: %s\n' "$expected_path" >&2
    sed -n '1,240p' "$output" >&2
    exit 1
  }
done

if grep -q 'trusted_host_process/adapter.mbt' "$output"; then
  printf 'trusted host adapter was not allowlisted\n' >&2
  exit 1
fi
if grep -q 'execution_sandbox_adapter/adapter.mbt' "$output"; then
  printf 'ExecutionSandbox adapter was not narrowly allowlisted\n' >&2
  exit 1
fi
if grep -q 'ignored_wbtest.mbt' "$output"; then
  printf 'test source was treated as production\n' >&2
  exit 1
fi
if grep -q 'test_import_fixture/moon.pkg' "$output"; then
  printf 'test-only package import was treated as production\n' >&2
  exit 1
fi

# A minimal repository with the approved adapter only must pass.
clean=$fixture/clean
mkdir -p "$clean/internal/trusted_host_process"
printf '{"name":"test/moonclaw-clean"}\n' >"$clean/moon.mod"
printf 'import { "moonbitlang/async/process" }\n@process.run(command, args)\n' \
  >"$clean/internal/trusted_host_process/adapter.mbt"
bash "$guard" "$clean" >/dev/null

# A typed moon_check dispatch is accepted only when its implementation crosses
# the common ExecutionSandbox boundary.
mkdir -p "$clean/cmd/daemon"
printf '"moon_check" => mooncode_tool_moon_check(book_root, arguments)\n' \
  >"$clean/cmd/daemon/mooncode_tools.mbt"
printf '@execution_sandbox.run_moon_check(config, root, cwd, target, timeout)\n' \
  >"$clean/cmd/daemon/mooncode_process_tools.mbt"
bash "$guard" "$clean" >/dev/null

printf 'mooncode_tool_moon_check_without_sandbox()\n' \
  >"$clean/cmd/daemon/mooncode_process_tools.mbt"
if bash "$guard" "$clean" >/dev/null 2>&1; then
  printf 'expected guard to reject an unbound moon_check dispatch\n' >&2
  exit 1
fi

# Positive shell/moon dispatch requires both the closed broker calls and the
# durable approval round-trip. Raw process scanning is still active for every
# one of these files.
printf '"shell" => mooncode_tool_shell_in_runtime(runtime, root, arguments)\n"moon_ide" => mooncode_tool_moon_ide(root, arguments)\n"moon_cmd" => mooncode_tool_moon_cmd(root, arguments)\n' \
  >"$clean/cmd/daemon/mooncode_tools.mbt"
printf '@execution_sandbox.run_approved_shell(config, root, cwd, cmd, plan)\n@execution_sandbox.run_exec(config, root, cwd, "moon", args, timeout)\n@execution_sandbox.run_approved_exec(config, root, cwd, "moon", args, plan)\n' \
  >"$clean/cmd/daemon/mooncode_process_tools.mbt"
printf 'mooncode_prepare_shell_approval_plan(root, arguments)\nmooncode_prepare_moon_cmd_approval_plan(root, arguments)\n' \
  >"$clean/cmd/daemon/mooncode_execution_sandbox_gate.mbt"
printf 'mooncode_runtime_bind_sandbox_approval_plan(root, tool_call)\nmooncode_runtime_authorized_tool_call(tool_call, approval)\n' \
  >"$clean/cmd/daemon/mooncode_runtime_turn.mbt"
bash "$guard" "$clean" >/dev/null

printf '@execution_sandbox.run_exec(config, root, cwd, "moon", args, timeout)\n@execution_sandbox.run_approved_exec(config, root, cwd, "moon", args, plan)\n' \
  >"$clean/cmd/daemon/mooncode_process_tools.mbt"
if bash "$guard" "$clean" >/dev/null 2>&1; then
  printf 'expected guard to reject shell dispatch without exact approved route\n' >&2
  exit 1
fi

printf 'execution-boundary guard tests: PASS\n'
