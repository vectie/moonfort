# MoonFort

MoonFort is the execution-sandbox boundary for MoonSuite. It is deliberately
separate from the MoonDesk virtual filesystem: the VFS describes and confines
workspace paths, while MoonFort controls what a process may read, write, run,
connect to, and consume.

This repository contains the backend-neutral contract, supervised local macOS
and Linux backends, and a fail-closed AEN/Firecracker adapter. The one-shot executor
accepts only an opaque approval ID, atomically consumes a trusted single-use
grant, and resolves every path, executable, credential, and deployment limit
from executor-owned configuration. Neither backend has an unsandboxed fallback.

## Current status

- `sandbox/` contains profiles, immutable digests, command preflight, receipts,
  lifecycle, private workspace materialization, scratch inventory/diff,
  promotion, and the local backend.
- Commands are pre-tokenized `Exec` values by default. Shell text is a separate
  compatibility capability and must be allow-listed explicitly.
- The local backend canonicalizes roots and executable bindings immediately
  before launch. macOS starts from `(deny default)` under `sandbox-exec`; Linux
  uses bubblewrap user/mount/PID/network namespaces, drops every capability,
  disables nested user namespaces, and mounts no host root. Both expose a
  private workspace copy, deny network access, and keep persistent writes under
  disjoint scratch.
- Availability is behaviorally probed rather than inferred from a binary:
  scratch must be writable, the canonical workspace must be unreadable and
  unwritable, and the Linux namespace must have no host network route.
- A native supervisor creates a new session/process group, applies per-process
  CPU/address-space/file-size/open-file limits, monitors the configured
  same-process-group count and aggregate scratch bytes, uses a monotonic
  deadline, caps merged output, and kills same-session descendants even after
  the direct child exits. A descendant that escapes with `setsid` cannot hang
  the monitor; the run becomes `Refused` with cleanup unverified. Local receipts
  explicitly list the aggregate CPU/memory, hard disk/process quota, inode
  quota guarantees that the shared-kernel backends cannot verify. macOS also
  names detached descendants and, when the native launcher is already above a
  requested virtual-memory ceiling, per-process address space as unverified.
  Linux counts the complete `/proc` descendant tree rather than only a process
  group, so a child calling `setsid` does not evade the sampled process ceiling.
- Scratch is inventoried without following links; changed paths are relative
  and explicit promotion revalidates fingerprints before atomic per-file
  rename. Canonical MoonBook files are never bulk-copied back.
- Missing enforcement always returns `Refused`; there is no host-process
  fallback. Local runs still report `Degraded` and require explicit opt-in
  because both `sandbox-exec` and bubblewrap share the host kernel and remain
  best-effort boundaries.
- `aen_backend/` implements bounded HTTP/Connect transport, authenticated
  content-addressed workspace provisioning, stock AEN cold-start with an
  immutable executor image and read-only workspace drive, fixed in-guest
  overlay/tool/limit attestation and supervision, structured scratch changes,
  verified lease/VM cleanup, and full lifecycle operations. Missing deployment
  components refuse rather than falling back or overclaiming enforcement.
- `executor/` owns bounded IPC, trusted workspace/tool/backend registries,
  single-use grants, complete approval/command digests, private scratch, and
  opaque TTL retention. Native ownership and permission checks reject unsafe
  configuration, registry, executable, grant-store, and parent paths before
  any backend work.
- `cmd/executor` is the v3 approval-ID-only JSON boundary intended for
  MoonClaw. Caller-supplied profiles and backend configuration are rejected by
  construction. `cmd/grant-publisher` is the narrow validated publication
  boundary, so MoonClaw does not need direct approval-store write access.
  `cmd/promote-retention` is the digest-bound reviewed promotion boundary;
  `cmd/main` prints the contract surface for integration checks.
- `docs/IMPLEMENTATION_PLAN.md` is the implementation plan and security
  decision record.
- `docs/AEN_PROVISIONER_CONTRACT.md` specifies the exact trusted workspace OCI
  provisioner and immutable guest-helper deployment contract.
- `docs/COMPLETION_AUDIT.md` is the requirement-by-requirement release gate.
  A package test or fake transport does not close a row unless it proves the
  named adversarial behavior; real local-host and AEN deployment exercises are
  mandatory before a production-complete claim.
- `scripts/audit-moonclaw-execution-boundary.sh` is the CI enforcement gate
  that rejects raw process authority in every first-party MoonClaw production
  package. The integrated checkout currently passes; see
  `docs/EXECUTION_BOUNDARY_GUARD.md` for its narrow infrastructure allowlist
  and semantic-bypass categories.

The local backend is not a production-grade arbitrary-code sandbox. Use the
strict default for untrusted work: it selects the AEN microVM backend and
refuses execution unless the deployment independently attests every requested
limit and mount/network property.
