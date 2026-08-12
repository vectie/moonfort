# Executor-owned configuration

`cmd/executor` requires `MOONFORT_EXECUTOR_CONFIG` to name a canonical regular
file owned by the executor user (or root), not writable by group/other, beneath
a trusted canonical parent chain. The approval, scratch, and retention roots
must be executor-private directories (no group/other permissions) and already
exist as pairwise-disjoint canonical directories. `approval_root/pending` and
`approval_root/consumed` must also exist with the same private permissions.
Registered workspace/read roots and executables must be owned by the executor
user (or root), must not be group/world writable, and must have trusted parent
chains. These paths are deployment-controlled, not writable by MoonDesk,
agents, plugins, or sandboxed children.

`cmd/grant-publisher` uses the same protected configuration. Deploy it as a
narrow local broker reachable only by MoonClaw's approval controller; do not
grant MoonClaw, MoonDesk, or agent tools direct filesystem write access to the
approval root.

```json
{
  "approval_root": "/var/lib/moonfort/approvals",
  "scratch_root": "/var/lib/moonfort/scratch",
  "retention_root": "/var/lib/moonfort/retention",
  "workspaces": {
    "moonbook-main": {
      "root": "/srv/moonbooks/main",
      "read_only_roots": ["/srv/moonbooks/main"],
      "allowed_backends": ["MicroVm"],
      "allowed_networks": ["Deny"],
      "allowed_egress": [],
      "allowed_commands": ["moon"],
      "allow_degraded": false
    }
  },
  "local_tools": {
    "moon": "/opt/moon/bin/moon"
  },
  "aen_backends": {
    "production": {
      "base_url": "https://aen.internal.example",
      "api_key": "injected-secret",
      "executor_image_ref": "registry.internal/moonfort/executor@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "expected_vcpu_count": 2,
      "expected_root_disk_mib": 4096,
      "provisioner_url": "https://moonfort-provisioner.internal.example",
      "provisioner_api_key": "injected-provisioner-secret",
      "provisioner_receipt_key": "injected-at-least-32-byte-hmac-key",
      "provisioner_key_id": "production-2026-08",
      "workspace_registry_repository": "registry.internal/moonfort/workspaces",
      "max_workspace_bytes": "2147483648",
      "guest_workspace": "/workspace",
      "guest_scratch": "/scratch",
      "guest_attester": "/opt/moonfort/bin/attester",
      "guest_supervisor": "/opt/moonfort/bin/supervisor",
      "executor_root_digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "guest_attester_digest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "guest_supervisor_digest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "tool_registry_digest": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      "guest_tools": {"moon":"/opt/moon/bin/moon"}
    }
  },
  "limits": {
    "max_protocol_bytes": 1048576,
    "max_wall_clock_ms": 600000,
    "max_cpu_seconds": 300,
    "max_memory_mib": 4096,
    "max_disk_mib": 8192,
    "max_processes": 256,
    "max_output_bytes": 10485760,
    "max_command_args": 256,
    "max_argument_bytes": 65536,
    "max_changed_paths": 10000,
    "retention_ms": "86400000"
  }
}
```

Generate the actual file from typed configuration and validate it during
deployment. AEN and provisioner secrets should normally come from a protected secret
materialization at service start, with the resulting config file mode
0600 and never included in logs, crash reports, grants, or receipts. Executor
and provisioned workspace images must use immutable `@sha256:` references;
mutable tags are rejected.

`workspace_registry_repository` is the exact repository name without a tag or
digest. A lease is accepted only when its image is precisely this repository
plus `@sha256:<digest>`. The four guest runtime fields are exact lowercase
SHA-256 values emitted by the rootfs packager and are included in the trusted
backend/command binding digest.

MoonBit's JSON encoding represents `Int64` fields such as `retention_ms` and a
grant's `expires_at_ms` and `max_workspace_bytes` as decimal strings; other integer fields above are
ordinary JSON numbers.

The executor applies independent hard maxima even to trusted configuration.
Local runs accept only deny-network profiles and always report `Degraded`.
Production untrusted work should authorize only `MicroVm` and
`RequireEnforced`.

For a successful changed microVM run, `scratch_root/<opaque-id>` is also the
host-side export destination. The fixed guest attester sends one bounded (at
most 8 MiB) value per file under one profile-derived post-run deadline
only for added/modified regular files named by the verified structured diff.
MoonFort rehashes the complete export and writes a `0600` retention record
whose reviewable manifest is bound to the workspace, profile, approval, and
command digests. Promotion can select only entries in that manifest and still
uses fd-relative source/destination revalidation. Symlinks, directories,
special files, and removals are never materialized or promotable.

Each promotion request currently accepts exactly one file and requires every
destination parent directory to already exist. This keeps the canonical write
to one atomic rename/exchange. A proven pre-mutation refusal restores the
retention; a native I/O outcome that may be post-mutation returns
`promotion-recovery-required` and leaves the `.promoting` record plus its
exact, synced `.claim` sidecar locked for
operator inspection. Its response has `destination_outcome` set to
`recovery-required` and names the exact reviewed path in `uncertain_paths`;
an empty `promoted_paths` therefore never falsely claims that no write may
have occurred. Expiration sweeping never deletes locked claims.

The promotion request/response wire protocol is version `4`; execution grants
and executor invocations remain version `3`. Promotion consumers must require
version `4` so an older consumer cannot silently miss the three-state
destination outcome. Pre-rename claim setup failures remove their sidecar only
after proving the original `.json` record still exists and `.promoting` does
not. Post-rename or otherwise uncertain claims remain locked. Exact operator
reconciliation of native crash residue remains required and is not automated.
