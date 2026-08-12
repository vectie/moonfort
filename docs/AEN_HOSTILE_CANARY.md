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

The executor workspace policy needs `MicroVm`, `Deny`, `shell-compat`, and one
non-shell network probe capability. The guest image must bind
`shell-compat` to its fixed shell and the network probe label to a fixed client
binary. The probe arguments should target an operator-owned endpoint that is
known to answer when reached; the approved AEN profile itself remains `Deny`
with an empty egress list. Do not put credentials in probe arguments.

Validate the config against
[`AEN_CANARY_CONFIG.schema.json`](AEN_CANARY_CONFIG.schema.json). Example:

```json
{
  "protocol_version": 1,
  "real_aen_acknowledgement": "I_UNDERSTAND_THIS_RUNS_HOSTILE_CODE_ON_REAL_AEN",
  "executor_config_path": "/etc/moonfort/executor.json",
  "workspace_id": "aen-canary",
  "backend_config_id": "production",
  "expected_aen_origin": "https://aen.internal.example",
  "expected_provisioner_origin": "https://moonfort-provisioner.internal.example",
  "expected_executor_image_ref": "registry.internal/moonfort/executor@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "expected_workspace_registry_repository": "registry.internal/moonfort/workspaces",
  "mutation_target_relative_path": "canary/sentinel.txt",
  "network_probe_tool": "curl-canary",
  "network_probe_args": ["--fail", "--max-time", "2", "https://aen-egress-canary.internal.example/deny-proof"],
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
2. deny-network egress must fail;
3. output flood must return `Killed`, `output_bytes`, and bounded output;
4. process explosion must hit an enforced non-success outcome;
5. aggregate disk growth beyond the approved MiB must not succeed;
6. a busy descendant must return `Killed` with `wall_clock_ms`;
7. an environment dump must contain none of the trusted AEN, provisioner, or
   configured secret values;
8. symlink traversal from scratch into the workspace must fail.

Every case additionally requires a digest-bound receipt with backend
`MicroVm`, enforcement `Enforced`, no `unverified_limits`, bounded safe
structured-diff paths, and `cleanup_verified: true`. After cleanup uncertainty
or canonical workspace mutation, remaining cases are skipped and reported as
failures; the harness does not create more VMs.

Local unit tests cover parsing, plan generation, and receipt assertions only.
They are not evidence of AEN enforcement. Archive the bounded report together
with deployment revision, executor image digest, provisioner revision, and the
registry's independent manifest check for the production proof record.
