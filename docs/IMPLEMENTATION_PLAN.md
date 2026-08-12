# MoonFort implementation plan

Status: implemented contract, supervised degraded macOS/Linux backends, and
attested AEN adapter, 2026-08-12

## Decision

MoonFort is a separate execution boundary from MoonDesk's virtual filesystem.
MoonBook remains the durable canonical source. A sandbox receives a read-only
workspace snapshot plus an isolated writable scratch area. Changes return as a
receipt and diff; promotion into MoonBook is an explicit review operation.

The sandbox must never be represented as merely a path prefix. Path checks are
useful defense in depth, but the enforcement boundary must be the child-process
or microVM runtime.

## MoonDesk baseline

MoonDesk currently provides three different, intentionally narrower controls:

- [`internal/fsx/confined_io.mbt`](../../moondesk/internal/fsx/confined_io.mbt)
  protects workspace API reads and writes from traversal and symlink escapes.
- [`internal/preview/response_policy.mbt`](../../moondesk/internal/preview/response_policy.mbt)
  isolates generated browser previews with an opaque iframe sandbox and CSP.
- [`internal/moonwiki/process_helpers.mbt`](../../moondesk/internal/moonwiki/process_helpers.mbt)
  starts native host processes with a selected `cwd` and bounded response text,
  but does not provide an OS or VM execution boundary.

MoonFort fills the third gap. MoonDesk should remain the UI/control surface;
MoonClaw should remain the sole tool executor, using MoonFort to obtain and
prove an enforced run before launching a command.

## What the neighboring projects teach us

### OpenSeek: local defense in depth

OpenSeek's `SandboxedCommand` prepares a command under macOS `sandbox-exec`,
realpaths its protected roots, probes whether enforcement is active, and keeps
the command arguments paired with the profile that produced its output. Its
static command preflight catches obvious escapes and its worker profile denies
shared repository writes while re-allowing one private worktree.

MoonFort should adopt this as the first local backend, with two changes:

1. `None`/unavailable enforcement must produce `Degraded` or `Refused`, never a
   silent unsandboxed success for untrusted work.
2. The static parser is only a floor. It must not be treated as the security
   boundary; the kernel policy is the authority.

Reference: `../openseek/agent_tool/internal/sandbox/README.mbt.md`.

### AEN: strong isolation

AEN's sandbox is a Firecracker microVM with its own kernel, root filesystem,
network namespace, and an `envd` process/filesystem API. It also supplies
pause/resume, snapshots, fork, TTL eviction, resource configuration, and
egress policy.

MoonFort should not duplicate Firecracker orchestration inside MoonDesk. It
should expose a backend adapter so MoonClaw can use AEN locally or remotely
when the threat model requires a VM boundary.

Reference: `../aen/docs/src/concepts/sandboxes.md` and
`../aen/src/sandbox/backend.rs`.

## Target architecture

```text
MoonBook canonical root
       │ read-only snapshot / overlay
       ▼
MoonFort profile + backend
  ├─ local OS sandbox (first backend)
  └─ AEN Firecracker microVM (strong backend)
       │ bounded exec + artifacts + diff
       ▼
MoonFort receipt → MoonClaw runtime → MoonDesk review
       │
       └─ explicit promotion into MoonBook
```

## Contract

`SandboxProfile` is the immutable run policy:

- run identity and canonical workspace root;
- isolated scratch root;
- backend and enforcement mode;
- read-only workspace mount;
- default-deny network policy with optional allow-list;
- command/tool allow-list;
- wall-clock, CPU, memory, disk, process-count, and output limits.

`SandboxReceipt` is the durable proof boundary. It must include the run ID,
backend, enforcement status, profile digest, terminal status, exit code,
changed paths, artifacts, and denial reason when applicable.

## Phases

### Phase 0 — contract and threat model (complete)

- Keep the profile and receipt types backend-neutral.
- Define `Enforced`, `Degraded`, and `Refused` explicitly.
- Add contract tests for default-deny, read-only workspace, scratch containment,
  and refusal semantics.

Exit gate: no execution API can claim success without an enforcement state.

Implemented: immutable profile digest; distinct `Exec`/explicit `Shell`
commands; exact capability allow-list; structured preparation refusals; strict
versus operator-opted-in degraded enforcement; receipt output and limit fields.

### Phase 1 — local macOS backend (complete)

- Add `SandboxedCommand` preparation around pre-tokenized `Exec` and explicit
  `Shell` compatibility commands.
- Realpath roots immediately before launch.
- Behavioral probe: allowed no-op plus denied write.
- Deny writes to canonical source and manifest paths; allow only scratch/build
  paths.
- Add process-group cancellation, wall-clock timeout, output hard cap, and
  spill-to-file output handling.
- Emit receipts for both allowed and denied writes.

Implemented: canonical roots and trusted executable bindings; private workspace
materialization; a default-deny SBPL profile with no canonical-workspace read,
deny-network policy, scratch-only writes, and a behavioral enforcement probe;
plus a native `posix_spawn` supervisor with a fresh session/process group,
monotonic wall deadline, per-process CPU/address-space/file-size/open-file
limits, configured same-group process-count monitoring, sampled aggregate
scratch-byte and entry-count monitoring, bounded merged output, and whole-group
cleanup. Post-run bounded inventory and diff do not follow symlinks. The backend
deliberately remains `Degraded` because it shares the host kernel and
`sandbox-exec` is best effort; receipts name aggregate CPU/memory, hard disk and
process quotas, inode quotas, and detached descendants as unverified local
guarantees.

Exit gate: an adversarial test cannot write outside scratch, create a source
file through an alias, escape through `cd`/symlink, exceed output/time/disk or
same-group process limits, or continue after cancellation.

### Phase 1b — local Linux backend (complete)

- Select the backend from the compiled host platform, never caller input.
- Require a behavioral bubblewrap probe; binary presence alone is insufficient.
- Create new user, mount, PID, IPC, UTS, cgroup, and network namespaces; drop
  all capabilities and disable nested user namespaces.
- Construct an empty namespace rather than read-binding `/`; expose narrow
  runtime roots, explicitly configured read-only roots, `/proc`, minimal
  `/dev`, and the private scratch snapshot at `/workspace`.
- Remount the namespace root read-only, keep network default-deny, and refuse
  reserved mount collisions, workspace/scratch executables, or any setup error.
- Reuse the native deadline/output/rlimit/disk supervisor and count the full
  Linux `/proc` descendant tree so `setsid` does not evade sampled process
  ceilings.

Implemented: `/usr/bin/bwrap` or `/bin/bwrap` is accepted only after a real
scratch-write, host-workspace-invisibility, and empty-route probe. Adversarial
tests cover argument preservation, missing canonical mounts, read-only mount
selection, reserved mount collisions, mutable tool refusal, canonical/secret
isolation, and fail-closed unavailability. The backend deliberately remains
`Degraded`: namespaces isolate filesystem/network/process views but do not
provide a separate kernel or universally delegated cgroup quotas.

Exit gate: on a Linux runner with supported user namespaces, the real E2E must
exit inside bubblewrap and prove host paths and network routes are absent. It
may skip only when the behavioral enforcement probe itself fails.

### Phase 2 — MoonClaw integration (v3 protocol foundation; migration active)

- Make MoonClaw the sole executor of `shell`, `moon_cmd`, and `moon_check`.
- Pass only an opaque single-use approval ID over the process boundary.
- Refuse execution when the selected backend is unavailable unless an explicit
  operator policy allows degraded mode.
- Store run scratch and receipts under a MoonSuite-owned temporary root.
- Return changed paths and artifacts to MoonDesk without exposing host paths.

Exit gate: MoonDesk remains a presentation/control surface; it cannot bypass
the executor or invent a successful receipt.

Implemented here: `cmd/executor` consumes exactly one v3 approval-ID-only
invocation on bounded stdin. It atomically consumes a trusted grant, resolves
workspace roots, executables, backend credentials, and deployment ceilings
from executor-owned configuration, then writes exactly one structured response
to stdout. Receipts bind the single-use approval, exact command, canonical
profile, and trusted backend/tool manifest. MoonClaw's legacy
`tools/execute_command` path has been migrated fail-closed, including a bound
workspace-relative working directory. The repository-wide raw-process audit
passes for the integrated MoonClaw checkout; capabilities that do not yet have
a typed ExecutionSandbox route refuse instead of retaining host execution. See
`MOONCLAW_INTEGRATION.md` and `EXECUTION_BOUNDARY_GUARD.md`.

### Phase 3 — AEN strong-backend protocol complete; deployment artifacts required

- Implement the backend adapter against AEN's sandbox lifecycle.
- Map MoonFort limits to CPU, memory, disk, TTL, and network policy.
- Use envd for process start, streaming output, stdin, signals, and filesystem
  operations.
- Support pause/resume and snapshot/fork for long-running or parallel work.

Exit gate: untrusted code runs with a separate kernel/filesystem/network stack,
and backend state survives process/service restart according to the receipt.

Implemented: bounded async HTTP and Connect/protobuf; a trusted provisioner
lease protocol that binds the exact current executor-registered workspace to a
content-addressed OCI image; stock AEN cold-start mapping with an immutable
executor image and read-only attached workspace drive; independent AEN state
readback; fixed in-guest overlay/tool/profile attestation; fixed supervised
command execution; bounded watcher plus content-hashed structured diff; and
verified VM and workspace-lease cleanup. Missing provisioner/guest binaries or
mutable image references refuse the run. Deployment still has to build and
publish the digest-pinned executor image, operate the provisioner endpoint, and
install its receipt key; the repository does not claim those external services
are running merely because their fail-closed protocol is implemented.

### Phase 4 — promotion complete; operator UX pending

- Show `Sandboxed`, `Degraded`, or `Refused` in MoonDesk before execution.
- Show network policy, resource limits, scratch location label, and profile
  digest in advanced details.
- Review the diff before promotion; never copy the entire scratch tree blindly.
- Add reset, stop, retry, and discard controls tied to the canonical run ID.

Exit gate: users can tell exactly where code ran, what it changed, and why a
run was refused or degraded.

Implemented here: explicit artifact declarations, reviewable per-file
promotion plans, source fingerprint and destination-chain revalidation,
temporary sibling writes, and atomic rename. MoonDesk presentation remains an
external UI task.

## Security invariants

1. Canonical MoonBook files are never writable from an unpromoted run.
2. Network is deny-by-default.
3. Missing enforcement never silently becomes an accepted sandboxed run.
4. Every child process is bounded by timeout, output, and process cleanup.
5. Grants are short-lived, single-use, and immutable; policy changes require a
   new approval.
6. Receipts bind output and denials to approval, command, profile, and trusted
   backend/tool configuration digests.
7. Host paths, secrets, sockets, and unrelated workspaces are not mounted.
8. UI approval is not enforcement; the executor must atomically consume a
   trusted grant and re-check policy at launch.

## Non-goals

- Replacing MoonDesk's VFS or MoonBook's durable storage.
- Building a Firecracker orchestrator inside MoonDesk.
- Treating lexical command parsing as a complete sandbox.
- Allowing arbitrary host shell commands as the default tool interface.
