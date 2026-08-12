# Deploying the AEN workspace provisioner

`cmd/aen-provisioner` is the trusted bridge between the executor-owned
workspace registry and AEN's immutable workspace drive. Run it under a
dedicated OS account. MoonDesk, MoonClaw, agents, and sandboxed processes must
not share that account or have read access to its configuration, lease, staging,
or artifact directories.

## Storage and registry arrangement

Create three canonical, mode-0700 directories on the same filesystem:

- `staging_root` holds an unpredictable per-request directory only while a
  snapshot is assembled. The service refuses success unless it removes that
  directory and verifies the removal.
- `artifact_root` is a deterministic OCI content spool. Blobs are placed at
  `blobs/sha256/<digest>` using create-once hard links. Existing content is
  accepted only when its regular-file size matches the verified source blob.
- `lease_root` contains one mode-0600 signed lease record per active run.

The configured `registry_repository` is the immutable repository namespace
represented by the spool. A registry-side adapter must expose the three OCI
blobs from this spool under that exact repository before AEN is allowed to
consume a returned manifest digest. A deployment may instead mount the spool
directly into a registry implementation whose trusted import transaction is
synchronous with the provisioner. Never translate the returned digest into a
mutable tag. Blob garbage collection may run only after it proves that no JSON
record in `lease_root` references the manifest.

This separation deliberately keeps registry credentials and arbitrary registry
URLs out of the request protocol. The provisioner accepts only a workspace ID;
it never accepts a path, archive, executable, command, image name, or credential.

## Configuration

Validate configuration against
[`AEN_PROVISIONER_CONFIG.schema.json`](AEN_PROVISIONER_CONFIG.schema.json), then
write it as a canonical regular file owned by the service account, mode 0600.
MoonBit represents `Int64` values as decimal JSON strings.

```json
{
  "bind_address": "127.0.0.1:8787",
  "api_key": "replace-with-at-least-32-secret-bytes",
  "receipt_key_id": "production-2026-08",
  "receipt_key": "replace-with-a-distinct-hmac-key-of-at-least-32-bytes",
  "staging_root": "/var/lib/moonfort-provisioner/staging",
  "artifact_root": "/var/lib/moonfort-provisioner/oci",
  "lease_root": "/var/lib/moonfort-provisioner/leases",
  "registry_repository": "registry.internal/moonfort/workspaces",
  "workspaces": {
    "moonbook-main": {
      "root": "/srv/moonbooks/main",
      "max_bytes": "2147483648",
      "max_entries": 100000,
      "max_file_bytes": "268435456"
    }
  },
  "limits": {
    "max_request_bytes": 16384,
    "max_response_bytes": 16384,
    "request_timeout_ms": 5000,
    "snapshot_timeout_ms": 300000,
    "max_connections": 4
  }
}
```

Inject `MOONFORT_AEN_PROVISIONER_CONFIG` with the protected absolute path and
run the release binary. The server intentionally accepts only an IPv4 loopback
bind. Put an authenticated, bounded reverse proxy in front when the executor is
on another host; terminate TLS there and preserve `X-API-Key`. Restrict the
proxy route to `POST /v1/workspaces` and `DELETE /v1/workspaces/<leaseID>` and
apply a request body ceiling no larger than `max_request_bytes`.

## Security behavior

The native snapshotter opens every path component with `O_NOFOLLOW`, pins
directories by descriptor, sorts UTF-8 entry names, rejects symlinks and every
non-regular/non-directory file, and verifies device, inode, mode, size, and
nanosecond modification/change times before and after copying. It closes stdin
by construction because it does not start workspace code. It enforces aggregate
bytes, per-file bytes, entry count, path length, and monotonic wall time.

The generated uncompressed tar layer is deterministic: normalized read-only
modes, uid/gid zero, epoch timestamps, sorted paths, and zero padding. OCI
config, layer, and image manifest are all addressed by SHA-256. The signed lease
binds the run, workspace, profile, canonical workspace digest, immutable image
reference, counts, cleanup result, and receipt key ID.

Rotate `api_key` independently from `receipt_key`. During receipt-key rotation,
deploy the new key ID and secret to both provisioner and MoonFort executor as one
configuration transaction. Keep old keys only for validating already-issued
leases; do not let callers choose a key ID.

## Startup and health gates

Before routing production traffic:

1. Run `moon test aen_provisioner_service --target native`.
2. Verify the three storage roots are empty/private and on one device.
3. Provision a canary workspace and independently hash the OCI manifest blob.
4. Confirm the registry returns that exact `sha256:` manifest and AEN can attach
   it read-only.
5. Delete the canary lease and confirm a second delete returns 404.
6. Exercise symlink, FIFO/socket/device, oversize, request-timeout, bad-MAC, and
   unavailable-registry refusal probes.

There is no unsandboxed fallback. A missing registry publication, unverified
cleanup, invalid MAC, key-ID mismatch, or unavailable service must cause the AEN
execution request to be refused.
