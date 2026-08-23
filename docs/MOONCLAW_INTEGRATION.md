# MoonClaw executor integration

MoonFort's production boundary is `cmd/executor`. Its stdout is exactly one
JSON `ExecutorResponse`; child stdout and stderr occur only inside its receipt.
It never accepts an executable profile from an IPC caller.

## Trust split

MoonClaw's approval controller sends a short-lived `ExecutionGrant` to
`cmd/grant-publisher`. The publisher validates it against executor-owned
registries and ceilings, then atomically creates the 0600 record under
`approval_root/pending`; MoonClaw never receives general write access to that
directory. The executor atomically moves the file to `consumed` before parsing
or validating it, making approvals single-use even when malformed or expired.
An untrusted executor caller may submit only:

```json
{"protocol_version":3,"approval_id":"opaque-single-use-id"}
```

The executor loads `MOONFORT_EXECUTOR_CONFIG` from a canonical regular file.
That trusted configuration owns:

- canonical MoonBook workspace IDs and read roots;
- local capability-to-executable bindings;
- AEN origins, credentials, snapshots, and guest tool bindings;
- approval, scratch, and retention roots; and
- deployment maxima for protocol, command, CPU, memory, disk, output, and TTL.

Never put a profile, host path, executable path, AEN URL, API key, or resource
ceiling into a request reachable from MoonDesk or an agent.

## Approval manifest

`ExecutionGrant` binds the request ID, workspace ID, workspace-relative working
directory, backend/config ID,
enforcement and network policy, capability set, exact tokenized command or
explicit shell script, limits, expiry, and approval ID. MoonFort canonicalizes
set-like arrays before SHA-256 hashing. The terminal receipt carries the
approval digest and a command digest that additionally binds the canonical
profile and trusted executable/deployment selection.

MoonClaw must publish the grant only after its existing approval decision. It
must use a cryptographically random approval ID, a unique request ID, a short
expiry, and an exact canonical digest persisted with the approval context. The
MoonFort publisher owns `CreateNew`/0600 staging and atomic rename into
`pending`. The executor consumes each ID once; retries require a new approval.

## Required MoonClaw migration

MoonClaw currently has several independent host execution paths. All
agent-controlled paths must depend on one injected `ExecutionSandbox` adapter
that performs the grant/invocation protocol. No refusal, invalid response,
timeout, or unavailable backend may retry through a host shell.

Migrate at least these paths before enabling production sandbox claims:

1. `/tool-exec` and runtime tool dispatch for shell, `moon_cmd`, `moon_check`,
   and `moon_ide`.
2. Foreground and background process tools, including hidden patch-verification
   subprocesses.
3. Legacy `tools/execute_command`, installed pack executors, local analysis
   agents, ACP/gateway/robot/provider runners, and any job isolation fallback.
4. Worktree/snapshot setup must fail closed; it may not silently use the shared
   canonical workspace.

Raw process APIs should be forbidden by CI in production agent/tool packages.
Necessary controller processes belong behind a separate fixed
`TrustedHostProcess` interface whose executable and arguments are not agent
controlled.

## Result and retention

Require `Enforced` for untrusted code. `AllowDegraded` is an explicit operator
choice for the local macOS/Linux backend, never an automatic fallback. Persist the
returned receipt and verify its approval ID, approval digest, command digest,
profile digest, terminal status, and cleanup state.

For `Exited` and `Killed` results, require a non-null `output_artifact` whenever
`output_truncated` is true. Otherwise a null reference means the small complete
output stayed inline without artifact I/O; a present reference means the inline
`output` is only the executor-configured model projection. Required spill
failure changes the executor result to `Failed`, so a terminal success never
silently drops oversized output.

`output_truncated` means the approved hard command-output ceiling was reached,
not that the model projection was shortened. MoonClaw must treat the artifact
ID as opaque and ask the trusted executor artifact reader to verify the signed
run/approval/command binding, expiry, size, media type, regular-file identity,
and SHA-256. It must never construct or expose a host path from that ID.

Changed local scratch is retained under an opaque ID only after a 0600 TTL
record is durably created in the executor-owned retention root. Expired records
are safely swept without following links. AEN changed regular files are
exported through the fixed digest-bound guest helper into the same private
retention model before verified VM deletion and workspace-lease release.
MoonDesk receives only relative changed paths and
declared artifacts; promotion uses MoonFort's reviewed per-file promotion API.
The production `cmd/promote-retention` controller accepts a bounded request
using promotion protocol version `4` and containing exactly one explicit file
mapping, the opaque retention ID,
workspace registry ID, the exact
approval/command digests from the receipt, and explicit per-file mappings.
Destination roots and scratch paths remain executor-owned, and source hashes
and destination chains are revalidated before atomic replacement.
Execution grants and invocations remain protocol version `3`.

Promotion recovery is an operator-only path. MoonClaw may display the bounded
result from `cmd/inspect-promotion-recovery`, but it must not infer, retry,
unlock, restore, clean up, or promote from that result. The inspector accepts
only protocol version `4` plus the opaque retention ID, proves the locked claim
and historical workspace-root binding, and returns no canonical host path.
Legacy claims or changed registry mappings are `manual-recovery`, never an
automatic fallback. See `PROMOTION_RECOVERY_INSPECTION.md`.

## Release gates

- Unknown, expired, malformed, and replayed approvals fail before filesystem
  snapshotting or network access.
- Substituting one profile, command argument, script, local executable, AEN
  origin/snapshot, or guest tool is refused or changes the bound digest.
- Arbitrary host roots, symlink swaps, oversized input/arrays/limits, and
  duplicate capabilities are refused.
- AEN failure/cancellation after create proves VM deletion, or reports
  unverified cleanup and never claims terminal enforcement.
- A real command write appears in the diff; noisy child output still produces
  exactly one parseable protocol JSON object.
- A repository-wide guard proves no agent-controlled raw process path remains.

MoonDesk remains a UI/control surface. It must not mint grants or invoke the
executor independently of MoonClaw's approval controller.
