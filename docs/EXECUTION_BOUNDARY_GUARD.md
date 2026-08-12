# MoonClaw execution-boundary guard

MoonFort ships a fail-closed source audit for MoonClaw production execution
paths. Run it from the MoonFort checkout:

```sh
bash scripts/audit-moonclaw-execution-boundary.sh /absolute/path/to/moonclaw
```

The audit exits nonzero if an untrusted agent or tool path imports or calls a
raw process API. The infrastructure allowlist is
`internal/trusted_host_process/`, reserved for fixed, reviewed host commands.
`internal/execution_sandbox_adapter/` is separately recognized as the MoonFort
v3 adapter: it may start only operator-configured publisher and executor
binaries with fixed arguments. Agent-selected commands belong behind that
adapter, not in the infrastructure allowlist.

The guard scans every first-party `moon.pkg` and permits runtime process imports
only inside the two reviewed adapters. It is not an application-level allowlist
or a valid dependency for tools, jobs, gateways, providers, or daemon dispatch.

The scanner recognizes all three process layers currently present in
MoonClaw—`moonbitlang/async/process`, `vectie/moonlib/spawn`, and MoonClaw's
`internal/spawn`—and scans both imports and call sites. It also reports the
semantic bypasses found by the initial boundary audit:

- the direct `/tool-exec` path that enters the dispatcher without the runtime
  approval context;
- native `shell`, `moon_ide`, `moon_cmd`, and `moon_check` dispatch;
- patch-verification commands in the daemon;
- the legacy `execute_command` host implementation;
- installed pack executables and background job processes;
- provider-task, ACP, gateway ACP, robot, and native OCR processes;
- worktree creation failures that silently select the shared workspace; and
- authorization snapshots that omit `moon_cmd`.

Every finding is printed; the audit never stops at the first bypass. New raw
call sites receive a path-based category and therefore also fail CI even when
they are not one of the original findings.

## CI contract

Run the self-test first, then audit the checked-out MoonClaw tree:

```sh
bash tests/execution-boundary-guard-test.sh
bash scripts/audit-moonclaw-execution-boundary.sh "$MOONCLAW_ROOT"
```

The integrated MoonClaw checkout passes after routing approved execution
through `ExecutionSandbox`, moving genuinely trusted fixed commands behind the
narrowly reviewed `TrustedHostProcess` adapter, and making unsupported legacy
execution paths fail closed. Do not weaken the patterns or add application-path
exceptions to keep CI green; remove any new bypass.
