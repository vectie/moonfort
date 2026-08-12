# Real-AEN hostile canary

`cmd/aen-canary` is an operator-only production proof harness. It publishes a
fresh single-use grant through the trusted executor package and invokes the
same `MicroVm` execution path as production. It has no fake transport, local
fallback, guest-side echo server, or direct AEN shortcut.

The command intentionally runs hostile code. Never point it at an endpoint you
do not own and recognize. It refuses before grant publication unless its
configuration contains the exact acknowledgement, HTTPS AEN and provisioner
origins, immutable executor image digest, workspace registry repository,
executor backend ID, and dedicated workspace ID. The protected executor config
must independently validate and the selected workspace policy must authorize
only the required `MicroVm`, deny-network, and guest capability path.

## Dedicated deployment fixture

Create a canary-only workspace containing a small regular sentinel such as
`canary/sentinel.txt`. Do not use a developer checkout or a production data
workspace. Register it with the provisioner and executor under the same opaque
workspace ID. Publish its OCI manifest synchronously to the pinned repository
and verify the digest is available before running the canary.

The executor workspace policy needs `MicroVm`, both `Deny` and
`Unrestricted`, `shell-compat`, and the exact non-shell capability
`moonfort-network-proof-v1`, and `moonfort-symlink-proof-v1`. The immutable
guest image must bind those labels to fixed, digest-covered binaries through
the executor-owned tool registry. The harness supplies only fixed
argument `probe`; neither the capability, arguments, endpoint, nor evidence
markers are operator-configurable. The client therefore compiles in an
operator-owned literal-IP endpoint and a fixed expected ASCII response token.
Build both helpers with
`scripts/build-aen-canary-probes.sh LITERAL_IPV4 PORT EXPECTED_TOKEN OUTPUT_DIR`
and append its two digest-bearing rows to the executor-image tool lock. The
network helper must avoid
DNS, TLS trust discovery, redirects, and proxy environment variables.

The client contract is exact. A reachable endpoint prints only
`MOONFORT_NETWORK_REACHABLE_V1\n` and exits `0`. A confirmed AEN firewall
blocked connection prints only `MOONFORT_NETWORK_BLOCKED_V1\n` and exits `90`.
DNS, TLS, timeout, route, connection-refused, unexpected HTTP status/body, and
all other failures must use distinct codes and output. MoonFort first runs the
same capability in a fresh `Unrestricted` VM; only an exact positive result
allows the immediately following `Deny` VM to count as corroborating behavioral
evidence. An arbitrary nonzero exit is a failed canary. A blocked connection
alone does not prove firewall causality; the enforcement authority remains the
exact trusted AEN control-plane readback plus the digest-pinned IPv6 attester.

The symlink proof likewise receives only `probe` and the validated relative
sentinel path. It must create the link itself, attempt the write, and emit only
`MOONFORT_SYMLINK_POLICY_DENIED_V1\n` with exit `91` when traversal is denied.
A missing utility, malformed link, generic write error, or any other nonzero
exit is not evidence. Both fixed binaries and their literal paths and digests
must appear in `tool-registry.tsv`; canary deployment validation refuses when
either capability is absent.
The backend must also pin `guest_workspace` to `/workspace`, `guest_scratch` to
`/scratch`, and the two capability paths to
`/opt/moonfort/tools/network-proof` and
`/opt/moonfort/tools/symlink-proof`; deployment validation rejects any other
layout before publishing a grant.

Validate the config against
[`AEN_CANARY_CONFIG.schema.json`](AEN_CANARY_CONFIG.schema.json). Example:

```json
{
  "protocol_version": 2,
  "real_aen_acknowledgement": "I_UNDERSTAND_THIS_RUNS_HOSTILE_CODE_ON_REAL_AEN",
  "executor_config_path": "/etc/moonfort/executor.json",
  "workspace_id": "aen-canary",
  "backend_config_id": "production",
  "expected_aen_origin": "https://aen.internal.example",
  "expected_provisioner_origin": "https://moonfort-provisioner.internal.example",
  "expected_executor_image_ref": "registry.internal/moonfort/executor@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "expected_workspace_registry_repository": "registry.internal/moonfort/workspaces",
  "mutation_target_relative_path": "canary/sentinel.txt",
  "secret_env_names": ["MOONFORT_AEN_API_KEY", "MOONFORT_PROVISIONER_API_KEY"],
  "limits": {
    "baseline_wall_clock_ms": 10000,
    "timeout_wall_clock_ms": 1000,
    "cpu_seconds": 2,
    "memory_mib": 128,
    "disk_mib": 8,
    "processes": 8,
    "output_bytes": 4096,
    "max_diff_entries": 64,
    "max_path_bytes": 512,
    "max_sentinel_bytes": 1048576
  }
}
```

Set `MOONFORT_AEN_CANARY_CONFIG` to the canonical config path and run the native
release command. Schedule it only in a controlled deployment workflow, never
on a developer machine by default. A successful process exits zero and emits
one bounded JSON report. Any missing pin, registry/image mismatch, publication
failure, incomplete response, uncertain cleanup, or failed assertion exits
nonzero. The report never contains raw guest output, diff contents, host paths,
or credentials.

## Required proof cases

The harness uses a fresh VM and single-use grant for each case:

1. canonical workspace mutation must fail and the host sentinel must remain
   byte-for-byte unchanged;
2. the fixed network proof must return its exact reachable marker and exit `0`
   in an `Unrestricted` VM;
3. the identical proof must return its exact blocked-network marker and exit
   `90` in a `Deny` VM;
4. output flood must return `Killed`, `output_bytes`, and bounded output;
5. process explosion must return `Killed` with exact reason `processes`;
6. aggregate disk growth must return `Killed` with exact reason `disk_mib`;
7. a busy descendant must return `Killed` with `wall_clock_ms`;
8. an environment dump must contain none of the trusted AEN, provisioner, or
   configured secret values;
9. the fixed symlink traversal must return its exact denial marker and exit
   `91`.

For denied profiles, MoonFort also requires stock AEN detail readback to match
top-level `allowInternetAccess: false`, `network.allowPublicTraffic: false`,
and the exact IPv4 deny rules. Because current stock AEN enforcement is IPv4
iptables, the digest-pinned guest attester must independently confirm that
IPv6 is absent or disabled on every present interface before the receipt can
be `Enforced`. Provider versions that do not persist private-traffic readback,
or guests with IPv6 enabled, are refused and deleted.

Every case additionally requires a digest-bound receipt with backend
`MicroVm`, enforcement `Enforced`, no `unverified_limits`, bounded safe
structured-diff paths, and `cleanup_verified: true`. After cleanup uncertainty
or canonical workspace mutation, remaining cases are skipped and reported as
failures; the harness does not create more VMs.

Local unit tests cover parsing, plan generation, and receipt assertions only.
They are not evidence of AEN enforcement. Archive the bounded report together
with deployment revision, executor image digest, provisioner revision, and the
registry's independent manifest check for the production proof record.
