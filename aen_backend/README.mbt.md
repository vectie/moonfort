# AEN execution backend

This package is a fail-closed MoonFort adapter for the AgentENV (AEN)
Firecracker control plane and its in-guest `envd` process service. It contains
no host-process or local-sandbox fallback.

## Trust and enforcement contract

The production facade first asks a trusted companion provisioner to publish
the current executor-registered workspace as a content-addressed OCI image.
It then creates a stock AEN cold-start VM from an immutable executor image,
attaches the workspace image as a read-only drive, reads AEN state back, and
returns `Enforced` only when all of the following agree:

- sandbox, immutable executor image, running state, vCPU allocation, memory,
  root disk size, egress policy, and kill-on-TTL lifecycle;
- egress allow/deny rules and TTL action `kill`;
- an HMAC-authenticated provisioner lease binding run, workspace ID, profile,
  exact workspace digest, byte/entry counts, and immutable OCI image digest;
- a fixed attester from the immutable executor image verifies the workspace
  drive is read-only, prepares a writable overlay at `guest_scratch`, proves
  its baseline is the provisioned workspace digest, hashes tool bindings, and
  confirms the fixed supervisor policy for CPU, process, and scratch limits.

MoonFort never treats sandbox metadata as enforcement attestation. The
provisioner receipt is authenticated independently, and guest facts come from
the fixed binary inside the digest-pinned executor image. A deployment without
the companion provisioner, immutable images, or guest helper therefore gets a
`Refused` receipt. The adapter records a
provider sandbox ID as soon as create returns it. Every later failure path,
including cancellation, attestation, watcher creation, execution streaming,
terminal diff collection, pause/resume, snapshot, and fork-child attestation,
runs deletion in a cancellation-protected region. Fork cleanup covers every
known child plus the parent.

`cleanup_verified=true` means AEN acknowledged deletion (`204`) or confirmed
the VM was already absent (`404`). A terminal `Enforced` receipt is returned
only with either verified deletion or, for a changed successful run, a
preserved snapshot artifact handed back before verified VM deletion. A live
lifecycle operation stays in `Running` status even after its guest process
exits (the exit code remains recorded) and carries an opaque `aen-vms:`
retention ID; a changed one-shot
receipt carries `aen-snapshot:`. If deletion cannot be verified, the receipt is
`Refused`, `cleanup_verified=false`, and includes the known VM IDs for explicit
operator cleanup. If create fails before returning an ID, cleanup is reported
unverified because the provider may have accepted the request without giving
MoonFort an addressable sandbox ID; provider TTL remains only a backstop.

The HTTP transport accepts an HTTPS origin, or canonical HTTP loopback for
local development. Every control response, error response, stream, and Connect
frame has a byte limit and a whole-request timeout. Redirect handling is not
implemented. envd output is retained only up to `profile.limits.output_bytes`.
On output overflow MoonFort closes the response, sends SIGKILL when it has a
PID, and always deletes the VM so descendants cannot survive. A timeout or
stream/protocol failure also requires verified VM termination and returns
`Refused` if cleanup cannot be confirmed.

Remote HTTP bodies, Connect error details, process status strings, transport
exception representations, and API keys are never copied into receipts. The
public AEN execution configuration intentionally implements no debug or JSON
serialization traits. Production code must populate it from executor-owned
trusted configuration rather than from an untrusted invocation.

`guest_workspace` is the read-only OCI drive containing the exact provisioned
workspace; it is not the canonical host path. The fixed guest helper prepares
`guest_scratch` as a writable overlay with that drive as its lower layer, and
process `cwd` is always that exact watched tree. Guest workspace and scratch must be
canonical, non-root, and neither may contain the other. Capabilities are
preserved through `PreparedSandboxCommand`: each allowed label must have an
absolute, trusted in-guest executable binding. The sorted binding map digest is
sent to the custom extension and must be independently attested on readback.

The provisioner API is deliberately narrow: `POST /v1/workspaces` accepts a
run ID, executor-owned workspace ID, profile digest, and maximum bytes—never a
caller path or archive. It returns a versioned lease for a digest-pinned OCI
image; `DELETE /v1/workspaces/{lease}` releases staging/registry lease state.
Production deployment must supply that service and the two fixed guest binaries
described below. These are deployment components, not optional fallbacks.
`Exec` passes an already-tokenized argument vector. The explicit `shell-compat`
capability uses its trusted shell binding with `-lc`; shell mode is never
inferred.

## Exact AEN endpoint mapping

The mapping was derived from
`/Users/kq/Workspace/aen/src/api/openapi.yml`,
`/Users/kq/Workspace/aen/crates/aenv/src/grpc/mod.rs`, and
`/Users/kq/Workspace/aen/thirdparty/envd/proto/process.proto`.

| MoonFort operation | AEN operation | Expected result |
|---|---|---|
| provision workspace | companion `POST /v1/workspaces` | `201`, authenticated immutable OCI lease |
| create + start | `POST /sandboxes-cold` | digest-pinned executor image plus read-only attached workspace drive; `201`, then `GET /sandboxes/{id}` `200` and guest attestation |
| exec | `POST /process.Process/Start` | Connect server stream, `application/connect+proto` |
| kill process | `POST /process.Process/SendSignal` | unary protobuf, SIGKILL (`9`) |
| pause | `POST /sandboxes/{id}/pause` | `204` |
| resume | `POST /sandboxes/{id}/resume` | `201`, then detail attestation (AEN marks this endpoint deprecated) |
| stop | `DELETE /sandboxes/{id}` | `204` |
| reset | stop, then repeat cold start from immutable images | terminal stop plus newly attested VM |
| release workspace | companion `DELETE /v1/workspaces/{lease}` | `204` or idempotent `404` |
| snapshot | `POST /sandboxes/{id}/snapshots` | `201` `snapshotID` |
| fork | `POST /sandboxes/{id}/fork` | `201`, one successful child per requested fork |

envd requests carry `X-API-Key`, `x-agentenv-sandbox-id`,
`x-agentenv-target-port: 49983`, and `Connect-Protocol-Version: 1`. Start uses
`ProcessConfig` fields `cmd=1`, repeated `args=2`, `cwd=4`; `StartRequest`
contains the config in field 1 and explicitly sets `stdin=false` in field 4.
Connect frames are one flag byte, a four-byte big-endian payload length, then a
protobuf `StartResponse`. Flag `0` is data and flag `2` is end-stream.

## Current upstream gaps

Stock AEN supplies the VM, cold-start image/drive attachment, resource
allocation, network namespace policy, TTL, envd, and lifecycle APIs. The
production path additionally requires the trusted workspace provisioner and
fixed guest helper/supervisor because stock AEN does not implement these
policies:

- `cpuCount` is vCPU allocation, not `cpu_seconds`. The fixed guest supervisor
  must install and attest the CPU-time controller. The adapter never equates
  these fields.
- MoonFort uses the stock cold-start schema, where CPU, memory, root disk, and
  read-only attached drives are real fields. It does not send those fields to
  the warm-snapshot endpoint, where they are unsupported.
- `diskSizeMB` is virtual disk size, not a per-run writable-byte quota. The
  guest supervisor must enforce and attest the profile scratch limit.
- Stock AEN does not expose a per-sandbox process-count limit. The provisioner
  supervisor must enforce and attest `maxProcesses`; MoonFort does not infer it from vCPU
  or guest memory allocation.
- the provisioner publishes exact current workspace bytes as an immutable OCI
  drive; the fixed guest helper creates and attests the writable overlay.
- AEN's documented all-egress deny is `0.0.0.0/0`; IPv6 denial is not stated in
  the public contract. The provisioner attestation must cover the complete
  network namespace policy.
- AEN exposes no signed hardware attestation in this API. MoonFort trusts the
  authenticated AEN control plane, provisioner receipt key, and digest-pinned
  guest image. Environments
  requiring cryptographic host/VM attestation need an additional verifier.
- artifact IDs and snapshot IDs are returned, but AEN does not expose a
  canonical MoonBook diff/promotion API. Promotion remains a separate explicit
  review step.

For terminal execution receipts, the adapter establishes an envd
`filesystem.Filesystem/CreateWatcher` on `guest_scratch` before process start,
then calls `GetWatcherEvents` and `RemoveWatcher`. A fixed guest inventory also
returns bounded content-hashed structured entries for the writable overlay.
The protobuf response is
bounded to 1 MiB, 4096 events, and 4096 bytes per path; absolute paths must stay
under guest scratch and are normalized to safe scratch-relative receipt paths.
Relative paths may not contain traversal, backslashes, NUL, or an empty/root
entry. A successful
or output-killed run is refused if this changed-path manifest cannot be read.
The one-shot facade snapshots a successfully changed VM before deletion and
records the snapshot ID as an artifact; if preservation fails, the run is
refused. Output-killed VMs are deleted immediately and are not promotable.

These are refusal conditions, not reasons to execute unsandboxed.
