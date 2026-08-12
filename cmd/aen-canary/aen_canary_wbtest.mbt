///|
fn test_canary_config() -> CanaryConfig {
  {
    protocol_version: CanaryProtocolVersion,
    real_aen_acknowledgement: RealAenAcknowledgement,
    executor_config_path: "/etc/moonfort/executor.json",
    workspace_id: "aen-canary",
    backend_config_id: "production",
    expected_aen_origin: "https://aen.internal.example",
    expected_provisioner_origin: "https://provisioner.internal.example",
    expected_executor_image_ref: "registry.internal/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    expected_workspace_registry_repository: "registry.internal/workspaces",
    mutation_target_relative_path: "canary/sentinel.txt",
    secret_env_names: ["MOONFORT_CANARY_SECRET"],
    limits: {
      baseline_wall_clock_ms: 10_000,
      timeout_wall_clock_ms: 1_000,
      cpu_seconds: 2,
      memory_mib: 128,
      disk_mib: 8,
      processes: 8,
      output_bytes: 4_096,
      max_diff_entries: 64,
      max_path_bytes: 512,
      max_sentinel_bytes: 1_048_576,
    },
  }
}

///|
fn test_backend() -> @trusted_executor.TrustedAenConfig {
  {
    base_url: "https://aen.internal.example",
    api_key: "aen-api-key-that-must-never-leak",
    executor_image_ref: "registry.internal/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    expected_vcpu_count: 2,
    expected_root_disk_mib: 4_096,
    provisioner_url: "https://provisioner.internal.example",
    provisioner_api_key: "provisioner-api-key-that-must-never-leak",
    provisioner_receipt_key: "receipt-key-that-is-at-least-32-bytes-long",
    provisioner_key_id: "production-2026",
    workspace_registry_repository: "registry.internal/workspaces",
    max_workspace_bytes: 1_073_741_824L,
    guest_workspace: "/workspace",
    guest_scratch: "/scratch",
    guest_attester: "/opt/moonfort/bin/attester",
    guest_supervisor: "/opt/moonfort/bin/supervisor",
    executor_root_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    guest_attester_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    guest_supervisor_digest: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    tool_registry_digest: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    guest_tools: {
      "shell-compat": "/bin/sh",
      "moonfort-network-proof-v1": "/opt/moonfort/tools/network-proof",
      "moonfort-symlink-proof-v1": "/opt/moonfort/tools/symlink-proof",
    },
  }
}

///|
fn test_executor(
  backend : @trusted_executor.TrustedAenConfig,
) -> @trusted_executor.ExecutorConfig {
  let config = test_canary_config()
  {
    approval_root: "/var/lib/moonfort/approvals",
    scratch_root: "/var/lib/moonfort/scratch",
    retention_root: "/var/lib/moonfort/retention",
    workspaces: {
      "aen-canary": {
        root: "/srv/moonfort/canary",
        read_only_roots: ["/srv/moonfort/canary"],
        allowed_backends: [MicroVm],
        allowed_networks: [Deny, Unrestricted],
        allowed_egress: [],
        allowed_commands: [
          @sandbox.shell_compatibility_command_label(),
          NetworkProofCapability,
          SymlinkProofCapability,
        ],
        allow_degraded: false,
      },
    },
    local_tools: Map([]),
    aen_backends: { "production": backend },
    limits: {
      max_protocol_bytes: 65_536,
      max_wall_clock_ms: config.limits.baseline_wall_clock_ms,
      max_cpu_seconds: config.limits.cpu_seconds,
      max_memory_mib: config.limits.memory_mib,
      max_disk_mib: config.limits.disk_mib,
      max_processes: config.limits.processes,
      max_output_bytes: config.limits.output_bytes,
      max_command_args: 64,
      max_argument_bytes: 4_096,
      max_changed_paths: config.limits.max_diff_entries,
      retention_ms: 60_000L,
    },
  }
}

///|
test "deployment validation pins fixed canary guest paths" {
  let config = test_canary_config()
  let backend = test_backend()
  validate_deployment(config, test_executor(backend))
  try
    validate_deployment(
      config,
      test_executor({ ..backend, guest_scratch: "/different-scratch" }),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("substituted canary scratch path unexpectedly validated")
  }
  let substituted_tools = backend.guest_tools.copy()
  substituted_tools[NetworkProofCapability] = "/opt/moonfort/tools/substituted"
  try
    validate_deployment(
      config,
      test_executor({ ..backend, guest_tools: substituted_tools }),
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("substituted network probe path unexpectedly validated")
  }
}

///|
test "limit and symlink assertions require exact trusted outcomes" {
  let config = test_canary_config()
  let backend = test_backend()
  for pair in [(ProcessExplosion, "processes"), (AggregateDisk, "disk_mib")] {
    let (case, reason) = pair
    let exact = test_receipt(status=Killed, exit_code=None, limit_reason=reason)
    assert_true(
      assert_case_receipt(
        case,
        exact,
        exact.approval_digest,
        exact.approval_id,
        config,
        backend,
        true,
      ).passed,
    )
    let generic = test_receipt(exit_code=Some(1))
    assert_false(
      assert_case_receipt(
        case,
        generic,
        generic.approval_digest,
        generic.approval_id,
        config,
        backend,
        true,
      ).passed,
    )
  }
  let symlink = test_receipt(
    exit_code=Some(SymlinkDeniedExitCode),
    output=SymlinkDeniedMarker,
  )
  assert_true(
    assert_case_receipt(
      SymlinkTraversal,
      symlink,
      symlink.approval_digest,
      symlink.approval_id,
      config,
      backend,
      true,
    ).passed,
  )
}

///|
fn test_receipt(
  status? : @sandbox.SandboxRunStatus = Exited,
  exit_code? : Int? = Some(0),
  output? : String = "",
  output_truncated? : Bool = false,
  limit_reason? : String,
) -> @sandbox.SandboxReceipt {
  {
    run_id: "run-aen-canary-test",
    approval_id: "approval-test",
    approval_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    command_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    backend: MicroVm,
    enforcement: Enforced,
    status,
    profile_digest: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    exit_code,
    output,
    output_truncated,
    limit_reason,
    unverified_limits: [],
    changed_paths: [],
    changes: [],
    artifacts: [],
    denial_reason: None,
    cleanup_verified: true,
    retention_id: None,
  }
}

///|
test "canary parser requires explicit real-AEN pins and bounds" {
  let input =
    #|{
    #|  "protocol_version": 2,
    #|  "real_aen_acknowledgement": "I_UNDERSTAND_THIS_RUNS_HOSTILE_CODE_ON_REAL_AEN",
    #|  "executor_config_path": "/etc/moonfort/executor.json",
    #|  "workspace_id": "aen-canary",
    #|  "backend_config_id": "production",
    #|  "expected_aen_origin": "https://aen.internal.example",
    #|  "expected_provisioner_origin": "https://provisioner.internal.example",
    #|  "expected_executor_image_ref": "registry.internal/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    #|  "expected_workspace_registry_repository": "registry.internal/workspaces",
    #|  "mutation_target_relative_path": "canary/sentinel.txt",
    #|  "secret_env_names": [],
    #|  "limits": {
    #|    "baseline_wall_clock_ms": 10000,
    #|    "timeout_wall_clock_ms": 1000,
    #|    "cpu_seconds": 2,
    #|    "memory_mib": 128,
    #|    "disk_mib": 8,
    #|    "processes": 8,
    #|    "output_bytes": 4096,
    #|    "max_diff_entries": 64,
    #|    "max_path_bytes": 512,
    #|    "max_sentinel_bytes": 1048576
    #|  }
    #|}
  let config = decode_canary_config(input)
  validate_static_config(config)
  assert_eq(config.backend_config_id, "production")
  assert_eq(config.limits.timeout_wall_clock_ms, 1_000)
}

///|
test "canary builds fixed positive and denied network proofs" {
  let config = test_canary_config()
  let plans = build_plans(config, test_backend())
  assert_eq(plans.length(), 9)
  for plan in plans {
    let grant = make_grant(plan, config, "approval-test", "request-test")
    assert_true(grant.backend is MicroVm)
    assert_true(grant.enforcement_requirement is RequireEnforced)
    if plan.case is NetworkPositiveControl {
      assert_true(grant.network is Unrestricted)
    } else {
      assert_true(grant.network is Deny)
    }
    assert_true(grant.allowed_egress.is_empty())
  }
  let positive = plans[1]
  let denied = plans[2]
  assert_eq(
    positive.command,
    Exec(tool=NetworkProofCapability, args=[NetworkProofArgument]),
  )
  assert_eq(denied.command, positive.command)
}

///|
test "network assertions reject generic failures and require exact proof markers" {
  let config = test_canary_config()
  let backend = test_backend()
  let positive = test_receipt(output=NetworkReachableMarker)
  assert_true(
    assert_case_receipt(
      NetworkPositiveControl,
      positive,
      positive.approval_digest,
      positive.approval_id,
      config,
      backend,
      true,
    ).passed,
  )
  let denied = test_receipt(
    exit_code=Some(NetworkBlockedExitCode),
    output=NetworkBlockedMarker,
  )
  assert_true(
    assert_case_receipt(
      NetworkEgress,
      denied,
      denied.approval_digest,
      denied.approval_id,
      config,
      backend,
      true,
    ).passed,
  )
  let dns_failure = test_receipt(exit_code=Some(6), output="dns failure\n")
  let rejected = assert_case_receipt(
    NetworkEgress,
    dns_failure,
    dns_failure.approval_digest,
    dns_failure.approval_id,
    config,
    backend,
    true,
  )
  assert_false(rejected.passed)
  assert_true(
    rejected.failures.contains(
      "deny-network probe did not return exact blocked-network evidence",
    ),
  )
}

///|
test "receipt assertions reject secret leakage and accept timeout kill evidence" {
  let config = test_canary_config()
  let backend = test_backend()
  let timeout = test_receipt(
    status=Killed,
    exit_code=None,
    limit_reason="wall_clock_ms",
  )
  let timeout_result = assert_case_receipt(
    TimeoutDescendants,
    timeout,
    timeout.approval_digest,
    timeout.approval_id,
    config,
    backend,
    true,
  )
  assert_true(timeout_result.passed)
  let leaked = test_receipt(output=backend.api_key)
  let leaked_result = assert_case_receipt(
    SecretEnvRead,
    leaked,
    leaked.approval_digest,
    leaked.approval_id,
    config,
    backend,
    true,
  )
  assert_false(leaked_result.passed)
  assert_true(
    leaked_result.failures.contains(
      "a trusted secret value appeared in guest output",
    ),
  )
}
