///|
fn test_canary_config() -> CanaryConfig {
  {
    protocol_version: 1,
    real_aen_acknowledgement: RealAenAcknowledgement,
    executor_config_path: "/etc/moonfort/executor.json",
    workspace_id: "aen-canary",
    backend_config_id: "production",
    expected_aen_origin: "https://aen.internal.example",
    expected_provisioner_origin: "https://provisioner.internal.example",
    expected_executor_image_ref: "registry.internal/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    expected_workspace_registry_repository: "registry.internal/workspaces",
    mutation_target_relative_path: "canary/sentinel.txt",
    network_probe_tool: "curl",
    network_probe_args: ["--fail", "https://canary.invalid/"],
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
    max_workspace_bytes: 1_073_741_824L,
    guest_workspace: "/workspace",
    guest_scratch: "/scratch",
    guest_attester: "/opt/moonfort/bin/attester",
    guest_supervisor: "/opt/moonfort/bin/supervisor",
    executor_root_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    guest_attester_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    guest_supervisor_digest: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    tool_registry_digest: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    guest_tools: { "shell-compat": "/bin/sh", "curl": "/usr/bin/curl" },
  }
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
    #|  "protocol_version": 1,
    #|  "real_aen_acknowledgement": "I_UNDERSTAND_THIS_RUNS_HOSTILE_CODE_ON_REAL_AEN",
    #|  "executor_config_path": "/etc/moonfort/executor.json",
    #|  "workspace_id": "aen-canary",
    #|  "backend_config_id": "production",
    #|  "expected_aen_origin": "https://aen.internal.example",
    #|  "expected_provisioner_origin": "https://provisioner.internal.example",
    #|  "expected_executor_image_ref": "registry.internal/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    #|  "expected_workspace_registry_repository": "registry.internal/workspaces",
    #|  "mutation_target_relative_path": "canary/sentinel.txt",
    #|  "network_probe_tool": "curl",
    #|  "network_probe_args": ["--fail", "https://canary.invalid/"],
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
test "canary builds eight hostile grants on the exact MicroVm policy path" {
  let config = test_canary_config()
  let plans = build_plans(config, test_backend())
  assert_eq(plans.length(), 8)
  for plan in plans {
    let grant = make_grant(plan, config, "approval-test", "request-test")
    assert_true(grant.backend is MicroVm)
    assert_true(grant.enforcement_requirement is RequireEnforced)
    assert_true(grant.network is Deny)
    assert_true(grant.allowed_egress.is_empty())
  }
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
