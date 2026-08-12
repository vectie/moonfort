# AEN workspace provisioner and guest-image contract

MoonFort's strong backend uses stock AEN APIs, but stock `envd` has no file
content upload/download RPC. Exact current workspace bytes therefore enter AEN
through a narrow, trusted OCI-drive provisioner. This document is the deployment
contract implemented by `aen_backend/provisioner.mbt` and verified by the AEN
adapter.

## Provisioner API

The provisioner authenticates MoonFort with `X-API-Key`. It owns the mapping
from `workspaceID` to canonical host root; requests never contain a host path,
archive, registry credentials, executable, or shell text.

`POST /v1/workspaces` accepts:

```json
{
  "protocolVersion": 2,
  "runID": "run-123",
  "workspaceID": "moonbook-main",
  "profileDigest": "...",
  "maxBytes": "2147483648",
  "rejectSymlinks": true,
  "requireImmutableImageDigest": true
}
```

The service must resolve the ID from its protected registry, pin the canonical
root by file descriptor, reject symlinks and special files, copy through
fd-relative operations into a private staging directory, hash every regular
file while copying, enforce the byte and entry ceilings, build a read-only OCI
drive, publish it by manifest digest, then delete staging before responding.
The workspace digest is the SHA-256 of a canonical sorted manifest containing
relative UTF-8 path, entry kind, byte size, and regular-file SHA-256. Registry
tags are not accepted as output identity.

The `201` response is `AenWorkspaceLease`. Its `receipt_mac` is lowercase hex
HMAC-SHA256 over these newline-separated values in exact order:

1. protocol version
2. lease ID
3. run ID
4. workspace ID
5. profile digest
6. workspace digest
7. OCI image reference
8. entry count
9. total bytes
10. `staging_cleanup_verified`
11. receipt key ID

The response includes `receipt_key_id`; callers compare it with the
executor-owned key ID before checking the MAC. MoonFort rejects a bad MAC,
mutable image reference, mismatched identity or key ID,
oversized lease, or unverified staging cleanup before contacting AEN.

`DELETE /v1/workspaces/{leaseID}` releases per-run registry/lease state. `204`
and already-absent `404` are success. The immutable content-addressed blob may
be shared and garbage-collected only when no lease references it. Failure to
verify both this release and AEN VM deletion makes the final receipt refused.

## Stock AEN mapping

MoonFort calls `POST /sandboxes-cold` with:

- an executor root image pinned by `@sha256:`;
- exact CPU, memory, root disk, egress, and kill-on-TTL settings;
- one attached drive, ID `moonfort-workspace`, pinned to the provisioned image,
  `readOnly=true`, mounted at `guest_workspace`.

It verifies `GET /sandboxes/{id}` resource, image, state, egress, and lifecycle
readback. No caller-supplied metadata is accepted as enforcement evidence.

## Immutable guest helpers

The executor image contains two distinct fixed binaries:

- `guest_attester prepare-and-attest` verifies the workspace drive is
  read-only and matches the provisioner manifest, prepares `guest_scratch` as
  an overlay whose lower layer is that drive, verifies its baseline digest and
  byte/entry counts, and reports tool/supervisor identity and installed limits.
- `guest_supervisor run` owns the target process tree, enforces CPU seconds,
  descendant process count, and a tmpfs-backed writable-overlay quota covering
  allocated blocks, inodes, and deleted-open files. It makes the target root
  recursively read-only except scratch, drops to nobody with
  no-new-privileges, closes stdin, bounds descriptors, kills all cgroup
  descendants, and returns the target exit status through envd. Missing kernel
  enforcement refuses launch.

Both are addressed only by paths from executor-owned configuration inside the
digest-pinned root image. The adapter checks a versioned JSON attestation before
starting an approved command. It later runs `guest_attester inventory`, bounded
to 4096 entries per view and a 4 MiB response, to hash the immutable lower
workspace and merged overlay view. Diffing those observable views represents
copy-up as `Modified`, new files as `Added`, and whiteout or opaque-directory
effects as `Removed` without trusting overlay implementation nodes.
An envd watcher independently supplies the changed-path event set. Failure of
either source refuses the run.

AEN control-plane readback, not the guest, binds the registry manifest used to
boot the VM. Embedding that manifest digest in the same image would be circular.
The protected executor configuration therefore supplies a non-circular root
manifest digest and exact attester, supervisor, and tool-registry digests. The
attester recomputes all four inside the VM. The supervisor then rechecks its own
binary, the persisted profile/limit policy, the registry, and the selected tool
file before launch. Any mismatch refuses execution.

## External deployment requirements

MoonFort contains the client, the loopback provisioner service, fd-relative
snapshot and deterministic OCI staging implementation, validation, request
mapping, receipt verification, cleanup protocol, and adversarial tests. A
production installation must run that service under a dedicated account,
synchronously expose its OCI spool through the configured immutable repository,
operate the AEN cluster, and publish the locally built immutable executor image.
This repository contains the fixed helpers, digest-locking packager, and
digest-only image definition. An exact AEN-compatible base image and registry
publication remain deployment inputs. Until they are configured, the backend
intentionally refuses; it never executes on the host as a fallback. See
`AEN_PROVISIONER_DEPLOYMENT.md`.
