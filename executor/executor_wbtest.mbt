///|
async fn test_executor_config() -> (ExecutorConfig, Array[String]) {
  let approval = @fs.realpath(@fs.tmpdir(prefix="moonfort-approvals-"))
  let scratch = @fs.realpath(@fs.tmpdir(prefix="moonfort-private-scratch-"))
  let workspace = @fs.realpath(@fs.tmpdir(prefix="moonfort-trusted-workspace-"))
  let retention = @fs.realpath(@fs.tmpdir(prefix="moonfort-retention-"))
  @fs.mkdir("\{approval}/pending", permission=0o700)
  @fs.mkdir("\{approval}/consumed", permission=0o700)
  let limits : ExecutorLimits = {
    max_protocol_bytes: 64 * 1024,
    max_wall_clock_ms: 5_000,
    max_cpu_seconds: 2,
    max_memory_mib: 256,
    max_disk_mib: 32,
    max_processes: 32,
    max_output_bytes: 64 * 1024,
    max_command_args: 16,
    max_argument_bytes: 4_096,
    max_changed_paths: 32,
    retention_ms: 60_000L,
  }
  let policy : WorkspacePolicy = {
    root: workspace,
    read_only_roots: [workspace],
    allowed_backends: [LocalOs],
    allowed_networks: [Deny],
    allowed_egress: [],
    allowed_commands: ["true"],
    allow_degraded: true,
  }
  (
    {
      approval_root: approval,
      scratch_root: scratch,
      retention_root: retention,
      workspaces: { "book": policy },
      local_tools: { "true": "/usr/bin/true" },
      aen_backends: Map([]),
      limits,
    },
    [approval, scratch, workspace, retention],
  )
}

///|
fn test_grant(approval_id : String) -> ExecutionGrant {
  {
    protocol_version: 3,
    approval_id,
    request_id: "request-1",
    workspace_id: "book",
    backend: LocalOs,
    enforcement_requirement: AllowDegraded,
    network: Deny,
    allowed_egress: [],
    allowed_commands: ["true"],
    limits: {
      wall_clock_ms: 2_000,
      cpu_seconds: 1,
      memory_mib: 128,
      disk_mib: 16,
      processes: 16,
      output_bytes: 8_192,
    },
    working_directory: "",
    command: Exec(tool="true", args=[]),
    backend_config_id: "local",
    expires_at_ms: @env.now().reinterpret_as_int64() + 60_000L,
  }
}

///|
fn test_aen_config() -> TrustedAenConfig {
  {
    base_url: "https://aen.internal.example",
    api_key: "aen-secret",
    executor_image_ref: "registry.internal/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    expected_vcpu_count: 2,
    expected_root_disk_mib: 4096,
    provisioner_url: "https://provisioner.internal.example",
    provisioner_api_key: "provisioner-secret",
    provisioner_receipt_key: "0123456789abcdef0123456789abcdef",
    provisioner_key_id: "key-1",
    workspace_registry_repository: "registry.internal/workspaces",
    max_workspace_bytes: 1_048_576L,
    guest_workspace: "/workspace",
    guest_scratch: "/scratch",
    guest_attester: "/opt/moonfort/bin/attester",
    guest_supervisor: "/opt/moonfort/bin/supervisor",
    executor_root_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    guest_attester_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    guest_supervisor_digest: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    tool_registry_digest: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    guest_tools: { "moon": "/opt/moonfort/tools/moon" },
  }
}

///|
test "trusted AEN binding digest rejects runtime and repository substitution" {
  let config = test_aen_config()
  let expected = trusted_aen_binding_digest(config)
  let substitutions = [
    { ..config, workspace_registry_repository: "registry.evil/workspaces" },
    {
      ..config,
      executor_root_digest: "0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    },
    {
      ..config,
      guest_attester_digest: "0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    },
    {
      ..config,
      guest_supervisor_digest: "0ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    },
    {
      ..config,
      tool_registry_digest: "0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    },
  ]
  assert_true(
    substitutions.all(value => trusted_aen_binding_digest(value) != expected),
  )
}

///|
test "trusted AEN config requires exact runtime digests and repository" {
  let config = test_aen_config()
  assert_true(trusted_aen_config_is_valid(config))
  assert_false(
    trusted_aen_config_is_valid({ ..config, executor_root_digest: "ABC" }),
  )
  assert_false(
    trusted_aen_config_is_valid({ ..config, guest_attester_digest: "" }),
  )
  assert_false(
    trusted_aen_config_is_valid({
      ..config,
      guest_supervisor_digest: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    }),
  )
  assert_false(
    trusted_aen_config_is_valid({
      ..config,
      tool_registry_digest: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    }),
  )
  assert_false(
    trusted_aen_config_is_valid({
      ..config,
      workspace_registry_repository: "https://registry.internal/workspaces",
    }),
  )
}

///|
async fn install_grant(config : ExecutorConfig, grant : ExecutionGrant) -> Unit {
  @fs.write_file(
    "\{config.approval_root}/pending/\{grant.approval_id}.json",
    grant.to_json().stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
}

///|
async fn cleanup_test_roots(roots : Array[String]) -> Unit {
  for root in roots {
    ignore(@fs.rmdir(root, recursive=true) catch { _ => () })
  }
}

///|
async test "single-use grants reject replay before backend execution" {
  let (config, roots) = test_executor_config()
  let grant = { ..test_grant("approval-replay"), workspace_id: "missing" }
  install_grant(config, grant)
  let first = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  assert_true(first.error() is Some(error) && error.code == "grant-refused")
  let replay = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  assert_true(replay.error() is Some(error) && error.code == "approval-refused")
  assert_false(
    @fs.exists("\{config.approval_root}/pending/\{grant.approval_id}.json"),
  )
  assert_true(
    @fs.exists("\{config.approval_root}/consumed/\{grant.approval_id}.json"),
  )
  cleanup_test_roots(roots)
}

///|
async test "grant publisher validates registry policy and refuses duplicate IDs" {
  let (config, roots) = test_executor_config()
  let grant = test_grant("approval-publisher")
  let published = publish_grant({ protocol_version: 3, grant }, config)
  assert_true(published.published)
  assert_eq(published.approval_digest, grant_digest(grant))
  assert_true(published.error is None)
  let duplicate = publish_grant({ protocol_version: 3, grant }, config)
  assert_false(duplicate.published)
  assert_true(duplicate.error is Some(error) && error.code == "grant-conflict")
  let refused = publish_grant(
    {
      protocol_version: 3,
      grant: { ..grant, approval_id: "approval-bad", workspace_id: "unknown" },
    },
    config,
  )
  assert_false(refused.published)
  assert_true(refused.error is Some(error) && error.code == "grant-refused")
  cleanup_test_roots(roots)
}

///|
async test "caller cannot supply workspace command or executable substitutions" {
  let (config, roots) = test_executor_config()
  let grant = {
    ..test_grant("approval-capability"),
    command: Exec(tool="cat", args=["/etc/passwd"]),
  }
  install_grant(config, grant)
  let response = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  assert_true(response.error() is Some(error) && error.code == "grant-refused")
  assert_false(response.receipt() is Some(_))
  cleanup_test_roots(roots)
}

///|
async test "oversized limits are refused before scratch allocation" {
  let (config, roots) = test_executor_config()
  let grant = {
    ..test_grant("approval-limits"),
    limits: { ..test_grant("unused").limits, output_bytes: 128 * 1024 },
  }
  install_grant(config, grant)
  let response = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  assert_true(response.error() is Some(error) && error.code == "grant-refused")
  assert_eq(@fs.readdir(config.scratch_root).length(), 0)
  cleanup_test_roots(roots)
}

///|
async test "process ceilings are deployment bounded" {
  let (config, roots) = test_executor_config()
  let grant = {
    ..test_grant("approval-process-limit"),
    limits: { ..test_grant("unused").limits, processes: 33 },
  }
  install_grant(config, grant)
  let response = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  assert_true(response.error() is Some(error) && error.code == "grant-refused")
  assert_eq(@fs.readdir(config.scratch_root).length(), 0)
  cleanup_test_roots(roots)
}

///|
async test "working directory traversal is refused before scratch allocation" {
  let (config, roots) = test_executor_config()
  let grant = {
    ..test_grant("approval-cwd-traversal"),
    working_directory: "nested/../outside",
  }
  install_grant(config, grant)
  let response = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  assert_true(response.error() is Some(error) && error.code == "grant-refused")
  assert_eq(@fs.readdir(config.scratch_root).length(), 0)
  cleanup_test_roots(roots)
}

///|
async test "receipt binds consumed approval and complete command manifest" {
  let (config, roots) = test_executor_config()
  let grant = test_grant("approval-binding")
  install_grant(config, grant)
  let response = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  guard response.receipt() is Some(receipt) else {
    fail("expected a bound terminal receipt")
  }
  assert_eq(receipt.approval_id, grant.approval_id)
  assert_eq(receipt.approval_digest, grant_digest(grant))
  assert_true(receipt.command_digest.length() == 64)
  match receipt.enforcement {
    Degraded => assert_true(receipt.cleanup_verified)
    Refused => assert_false(receipt.cleanup_verified)
    Enforced => fail("local executor must not claim enforced isolation")
  }
  assert_true(receipt.retention_id is None)
  cleanup_test_roots(roots)
}

///|
async test "changed local scratch is retained by opaque ID and TTL sweep removes it" {
  let (config, roots) = test_executor_config()
  let (scratch, retention_id) = allocate_scratch("request-retain", config)
  @fs.write_file(
    "\{scratch}/made",
    "artifact",
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  assert_true(
    retain_scratch(
      scratch,
      retention_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [
        {
          relative_path: "made",
          kind: RegularFile,
          size_bytes: 8L,
          fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"artifact")),
        },
      ],
      config,
    ),
  )
  let scratch = "\{config.scratch_root}/\{retention_id}"
  let metadata = "\{config.retention_root}/\{retention_id}.json"
  assert_true(@fs.exists("\{scratch}/made"))
  assert_true(@fs.exists(metadata))
  let record : RetentionRecord = @json.from_json(
    @json.parse(bounded_regular_file(metadata, 16_384)),
  )
  @fs.write_file(
    metadata,
    { ..record, expires_at_ms: 0L }.to_json().stringify(),
    create_mode=CreateOrTruncate,
  )
  assert_eq(sweep_expired_retentions(config), 1)
  assert_false(@fs.exists(scratch))
  assert_false(@fs.exists(metadata))
  cleanup_test_roots(roots)
}

///|
async test "promotion requires matching retained execution digests" {
  let (config, roots) = test_executor_config()
  let (scratch, retention_id) = allocate_scratch("request-promote", config)
  @fs.write_file(
    "\{scratch}/generated.txt",
    "reviewed artifact",
    create_mode=CreateNew,
    permission=0o600,
  )
  assert_true(
    retain_scratch(
      scratch,
      retention_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [
        {
          relative_path: "generated.txt",
          kind: RegularFile,
          size_bytes: 17L,
          fingerprint: @crypto.bytes_to_hex_string(
            @crypto.sha256(b"reviewed artifact"),
          ),
        },
      ],
      config,
    ),
  )
  let base : RetentionPromotionRequest = {
    protocol_version: 4,
    retention_id,
    workspace_id: "book",
    approval_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    command_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    items: [
      {
        artifact_path: "generated.txt",
        destination_path: "promoted/generated.txt",
      },
    ],
  }
  let legacy = promote_retention({ ..base, protocol_version: 3 }, config)
  assert_false(legacy.completed)
  assert_eq(legacy.protocol_version, 4)
  assert_eq(legacy.destination_outcome, "not-applied")
  assert_true(@fs.exists("\{config.retention_root}/\{retention_id}.json"))
  let mismatch = promote_retention(
    { ..base, command_digest: "substituted" },
    config,
  )
  assert_false(mismatch.completed)
  assert_false(@fs.exists("\{config.workspaces["book"].root}/promoted"))
  @fs.mkdir("\{config.workspaces["book"].root}/promoted", permission=0o700)
  let promoted = promote_retention(base, config)
  assert_true(promoted.completed)
  assert_eq(promoted.destination_outcome, "applied-durable")
  assert_true(promoted.uncertain_paths.is_empty())
  assert_eq(promoted.workspace_id, "book")
  assert_eq(
    promoted.approval_digest,
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  )
  assert_eq(
    promoted.command_digest,
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  )
  assert_eq(promoted.promoted_paths, ["promoted/generated.txt"])
  let promoted_bytes = @fs.read_file(
    "\{config.workspaces["book"].root}/promoted/generated.txt",
  )
  assert_eq(@utf8.decode_lossy(promoted_bytes.binary()), "reviewed artifact")
  let replay = promote_retention(base, config)
  assert_false(replay.completed)
  assert_true(replay.error is Some(error) && error.code == "promotion-refused")
  cleanup_test_roots(roots)
}

///|
fn exported_aen_receipt(
  relative_path : String,
  payload : Bytes,
  fingerprint? : String,
  artifacts? : Array[String],
) -> @sandbox.SandboxReceipt {
  let fingerprint = fingerprint.unwrap_or(
    @crypto.bytes_to_hex_string(@crypto.sha256(payload)),
  )
  let entry : @sandbox.ScratchEntry = {
    relative_path,
    kind: RegularFile,
    size_bytes: payload.length().to_int64(),
    fingerprint,
  }
  {
    ..@sandbox.exited_receipt(
      "aen-run",
      MicroVm,
      Enforced,
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      0,
      "",
    ),
    changed_paths: [relative_path],
    changes: [
      { relative_path, change: Added, before: None, after: Some(entry) },
    ],
    artifacts: artifacts.unwrap_or([relative_path]),
    cleanup_verified: true,
  }
}

///|
async test "verified AEN export is retained promoted and replay refused" {
  let (config, roots) = test_executor_config()
  let (scratch, retention_id) = allocate_scratch("request-aen-promote", config)
  let payload = b"reviewed microVM artifact"
  @fs.write_file(
    "\{scratch}/result.txt",
    payload,
    create_mode=CreateNew,
    permission=0o600,
  )
  let receipt = exported_aen_receipt("result.txt", payload)
  assert_true(
    retain_execution_result(
      MicroVm,
      receipt,
      scratch,
      retention_id,
      "book",
      receipt.profile_digest,
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      config,
    ),
  )
  let request : RetentionPromotionRequest = {
    protocol_version: 4,
    retention_id,
    workspace_id: "book",
    approval_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    command_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    items: [
      {
        artifact_path: "result.txt",
        destination_path: "reviewed/aen-result.txt",
      },
    ],
  }
  @fs.mkdir("\{config.workspaces["book"].root}/reviewed", permission=0o700)
  let promoted = promote_retention(request, config)
  assert_true(promoted.completed)
  assert_eq(
    @fs.read_file("\{config.workspaces["book"].root}/reviewed/aen-result.txt").binary(),
    payload,
  )
  assert_false(promote_retention(request, config).completed)
  cleanup_test_roots(roots)
}

///|
async test "AEN retention refuses forged bytes and artifact substitution" {
  let (config, roots) = test_executor_config()
  let payload = b"actual bytes"
  let forged_fingerprint = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  let (forged_scratch, forged_id) = allocate_scratch(
    "request-aen-forged", config,
  )
  @fs.write_file(
    "\{forged_scratch}/result.txt",
    payload,
    create_mode=CreateNew,
    permission=0o600,
  )
  let forged = exported_aen_receipt(
    "result.txt",
    payload,
    fingerprint=forged_fingerprint,
  )
  assert_false(
    retain_execution_result(
      MicroVm,
      forged,
      forged_scratch,
      forged_id,
      "book",
      forged.profile_digest,
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      config,
    ),
  )
  let (substituted_scratch, substituted_id) = allocate_scratch(
    "request-aen-substituted", config,
  )
  @fs.write_file(
    "\{substituted_scratch}/result.txt",
    payload,
    create_mode=CreateNew,
    permission=0o600,
  )
  let substituted = exported_aen_receipt("result.txt", payload, artifacts=[
    "different.txt",
  ])
  assert_false(
    retain_execution_result(
      MicroVm,
      substituted,
      substituted_scratch,
      substituted_id,
      "book",
      substituted.profile_digest,
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      config,
    ),
  )
  assert_true(@sandbox.discard_scratch_tree(forged_scratch) is Ok(_))
  assert_true(@sandbox.discard_scratch_tree(substituted_scratch) is Ok(_))
  cleanup_test_roots(roots)
}

///|
async test "retention manifest is sorted unique and aggregate bounded" {
  let (config, roots) = test_executor_config()
  let entry = fn(path : String, size : Int64) -> @sandbox.ScratchEntry {
    {
      relative_path: path,
      kind: RegularFile,
      size_bytes: size,
      fingerprint: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }
  }
  assert_true(
    retention_manifest_is_valid([entry("a", 1L), entry("b", 2L)], config),
  )
  assert_false(
    retention_manifest_is_valid([entry("b", 2L), entry("a", 1L)], config),
  )
  assert_false(
    retention_manifest_is_valid([entry("a", 1L), entry("a", 1L)], config),
  )
  assert_false(
    retention_manifest_is_valid(
      [entry("large", config.limits.max_disk_mib.to_int64() * 1_048_576L + 1L)],
      config,
    ),
  )
  cleanup_test_roots(roots)
}

///|
async test "retention refuses oversized encoding and tampered manifest order" {
  let (base_config, roots) = test_executor_config()
  let small_config : ExecutorConfig = {
    ..base_config,
    limits: { ..base_config.limits, max_protocol_bytes: 128 },
  }
  let (oversized_scratch, oversized_id) = allocate_scratch(
    "request-oversized-record", small_config,
  )
  @fs.write_file(
    "\{oversized_scratch}/artifact",
    "x",
    create_mode=CreateNew,
    permission=0o600,
  )
  assert_false(
    retain_scratch(
      oversized_scratch,
      oversized_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [
        {
          relative_path: "artifact",
          kind: RegularFile,
          size_bytes: 1L,
          fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"x")),
        },
      ],
      small_config,
    ),
  )
  assert_false(
    @fs.exists("\{small_config.retention_root}/\{oversized_id}.json"),
  )
  let (scratch, retention_id) = allocate_scratch(
    "request-tampered-record", base_config,
  )
  @fs.write_file("\{scratch}/a", "a", create_mode=CreateNew, permission=0o600)
  @fs.write_file("\{scratch}/b", "b", create_mode=CreateNew, permission=0o600)
  let files : Array[@sandbox.ScratchEntry] = [
    {
      relative_path: "a",
      kind: RegularFile,
      size_bytes: 1L,
      fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"a")),
    },
    {
      relative_path: "b",
      kind: RegularFile,
      size_bytes: 1L,
      fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"b")),
    },
  ]
  assert_true(
    retain_scratch(
      scratch, retention_id, "book", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      files, base_config,
    ),
  )
  let metadata = "\{base_config.retention_root}/\{retention_id}.json"
  let record : RetentionRecord = @json.from_json(
    @json.parse(
      bounded_regular_file(metadata, base_config.limits.max_protocol_bytes),
    ),
  )
  @fs.write_file(
    metadata,
    { ..record, reviewable_files: [files[1], files[0]] }.to_json().stringify(),
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  let refused = try {
    ignore(load_retention_record(retention_id, base_config))
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  assert_true(@sandbox.discard_scratch_tree(oversized_scratch) is Ok(_))
  assert_true(@sandbox.discard_scratch_tree(scratch) is Ok(_))
  @fs.remove(metadata)
  cleanup_test_roots(roots)
}

///|
async test "retention write refuses expiration overflow" {
  let (base_config, roots) = test_executor_config()
  let config : ExecutorConfig = {
    ..base_config,
    limits: { ..base_config.limits, retention_ms: 9_223_372_036_854_775_807L },
  }
  assert_false(retention_window_is_valid(config.limits.retention_ms))
  let (scratch, retention_id) = allocate_scratch(
    "request-expiration-overflow", config,
  )
  @fs.write_file(
    "\{scratch}/artifact",
    "x",
    create_mode=CreateNew,
    permission=0o600,
  )
  assert_false(
    retain_scratch(
      scratch,
      retention_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [
        {
          relative_path: "artifact",
          kind: RegularFile,
          size_bytes: 1L,
          fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"x")),
        },
      ],
      config,
    ),
  )
  assert_true(@sandbox.discard_scratch_tree(scratch) is Ok(_))
  cleanup_test_roots(roots)
}

///|
async test "promotion claim durably binds the exact reviewed item" {
  let (config, roots) = test_executor_config()
  let (scratch, retention_id) = allocate_scratch("request-claim", config)
  @fs.write_file(
    "\{scratch}/artifact",
    "reviewed",
    create_mode=CreateNew,
    permission=0o600,
  )
  let entry : @sandbox.ScratchEntry = {
    relative_path: "artifact",
    kind: RegularFile,
    size_bytes: 8L,
    fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"reviewed")),
  }
  assert_true(
    retain_scratch(
      scratch,
      retention_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [entry],
      config,
    ),
  )
  @fs.mkdir("\{config.workspaces["book"].root}/reviewed", permission=0o700)
  let inventory : @sandbox.ScratchInventory = {
    entries: [entry],
    total_bytes: 8L,
  }
  let plan = @sandbox.plan_sandbox_promotion(
    inventory,
    config.workspaces["book"].root,
    [{ artifact_path: "artifact", destination_path: "reviewed/result" }],
  ).unwrap()
  let record = load_retention_record(retention_id, config)
  let item = plan.items()[0]
  let claimed = claim_retention_for_promotion(
    record,
    item,
    config.workspaces["book"].root,
    config,
  )
  assert_false(@fs.exists("\{config.retention_root}/\{retention_id}.json"))
  let claim_path = "\{config.retention_root}/\{retention_id}.claim"
  let claim : PromotionClaim = @json.from_json(
    @json.parse(
      bounded_regular_file(claim_path, config.limits.max_protocol_bytes),
    ),
  )
  assert_eq(claim.record, record)
  assert_eq(claim.item, item)
  assert_eq(claim.phase, "prepared")
  assert_true(
    claim.workspace_root_binding is Some(binding) && sha256_digest(binding),
  )
  assert_eq(sweep_expired_retentions(config), 0)
  assert_true(@fs.exists(claimed))
  assert_true(@fs.exists(claim_path))
  assert_false(
    rollback_pre_rename_claim(
      "\{config.retention_root}/\{retention_id}.json",
      claimed,
      claim_path,
      config,
    ),
  )
  assert_true(@fs.exists(claimed))
  assert_true(@fs.exists(claim_path))
  assert_true(restore_claimed_retention(claimed, record, config))
  assert_true(@fs.exists("\{config.retention_root}/\{retention_id}.json"))
  assert_false(@fs.exists(claimed))
  assert_false(@fs.exists(claim_path))
  assert_true(@sandbox.discard_scratch_tree(scratch) is Ok(_))
  @fs.remove("\{config.retention_root}/\{retention_id}.json")
  cleanup_test_roots(roots)
}

///|
async test "recovery inspection is read-only and classifies confined content" {
  let (config, roots) = test_executor_config()
  let workspace = config.workspaces["book"].root
  let (scratch, retention_id) = allocate_scratch("request-inspect", config)
  @fs.write_file(
    "\{scratch}/artifact",
    "reviewed",
    create_mode=CreateNew,
    permission=0o600,
  )
  let fingerprint = @crypto.bytes_to_hex_string(@crypto.sha256(b"reviewed"))
  let entry : @sandbox.ScratchEntry = {
    relative_path: "artifact",
    kind: RegularFile,
    size_bytes: 8L,
    fingerprint,
  }
  assert_true(
    retain_scratch(
      scratch,
      retention_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [entry],
      config,
    ),
  )
  @fs.mkdir("\{workspace}/reviewed", permission=0o700)
  let plan = @sandbox.plan_sandbox_promotion(
    { entries: [entry], total_bytes: 8L },
    workspace,
    [{ artifact_path: "artifact", destination_path: "reviewed/result" }],
  ).unwrap()
  let record = load_retention_record(retention_id, config)
  let claimed = claim_retention_for_promotion(
    record,
    plan.items()[0],
    workspace,
    config,
  )
  let claim_path = "\{config.retention_root}/\{retention_id}.claim"
  let before_claim = bounded_regular_file(
    claim_path,
    config.limits.max_protocol_bytes,
  )
  let before_promoting = bounded_regular_file(
    claimed,
    config.limits.max_protocol_bytes,
  )
  let request : RetentionRecoveryInspectionRequest = {
    protocol_version: 4,
    retention_id,
  }
  let prestate = inspect_retention_recovery(request, config)
  assert_eq(prestate.outcome, "reviewed-prestate")
  assert_true(prestate.error is None)
  assert_eq(prestate.destination_path, "reviewed/result")
  assert_true(sha256_digest(prestate.reviewed_state_digest))
  assert_true(sha256_digest(prestate.desired_state_digest))
  assert_true(sha256_digest(prestate.observed_state_digest))
  @fs.write_file(
    "\{workspace}/reviewed/result",
    "reviewed",
    create_mode=CreateNew,
    permission=0o600,
  )
  let desired = inspect_retention_recovery(request, config)
  assert_eq(desired.outcome, "desired-applied")
  assert_eq(desired.observed_state_digest, desired.desired_state_digest)
  @fs.write_file(
    "\{workspace}/reviewed/result",
    "diverged",
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  let diverged = inspect_retention_recovery(request, config)
  assert_eq(diverged.outcome, "diverged")
  assert_true(diverged.error is None)
  @fs.remove("\{workspace}/reviewed/result")
  @fs.symlink("\{workspace}/reviewed/result", target="/etc/passwd")
  let unavailable = inspect_retention_recovery(request, config)
  assert_eq(unavailable.outcome, "unavailable")
  assert_true(
    unavailable.error is Some(error) && error.code == "destination-unavailable",
  )
  let encoded = unavailable.to_json().stringify()
  assert_false(encoded.contains(workspace))
  assert_false(encoded.contains("/etc/passwd"))
  assert_eq(
    bounded_regular_file(claim_path, config.limits.max_protocol_bytes),
    before_claim,
  )
  assert_eq(
    bounded_regular_file(claimed, config.limits.max_protocol_bytes),
    before_promoting,
  )
  @fs.remove("\{workspace}/reviewed/result")
  assert_true(restore_claimed_retention(claimed, record, config))
  assert_true(@sandbox.discard_scratch_tree(scratch) is Ok(_))
  @fs.remove("\{config.retention_root}/\{retention_id}.json")
  cleanup_test_roots(roots)
}

///|
async test "recovery inspection refuses legacy and remapped workspace roots" {
  let (config, roots) = test_executor_config()
  let workspace = config.workspaces["book"].root
  let (scratch, retention_id) = allocate_scratch(
    "request-inspect-binding", config,
  )
  @fs.write_file(
    "\{scratch}/artifact",
    "reviewed",
    create_mode=CreateNew,
    permission=0o600,
  )
  let entry : @sandbox.ScratchEntry = {
    relative_path: "artifact",
    kind: RegularFile,
    size_bytes: 8L,
    fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"reviewed")),
  }
  assert_true(
    retain_scratch(
      scratch,
      retention_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [entry],
      config,
    ),
  )
  let plan = @sandbox.plan_sandbox_promotion(
    { entries: [entry], total_bytes: 8L },
    workspace,
    [{ artifact_path: "artifact", destination_path: "result" }],
  ).unwrap()
  let record = load_retention_record(retention_id, config)
  let claimed = claim_retention_for_promotion(
    record,
    plan.items()[0],
    workspace,
    config,
  )
  let request : RetentionRecoveryInspectionRequest = {
    protocol_version: 4,
    retention_id,
  }
  let alternate = @fs.realpath(
    @fs.tmpdir(prefix="moonfort-remapped-workspace-"),
  )
  let remapped_policy : WorkspacePolicy = {
    ..config.workspaces["book"],
    root: alternate,
    read_only_roots: [alternate],
  }
  let remapped : ExecutorConfig = {
    ..config,
    workspaces: { "book": remapped_policy },
  }
  let root_refused = inspect_retention_recovery(request, remapped)
  assert_eq(root_refused.outcome, "manual-recovery")
  assert_true(
    root_refused.error is Some(error) && error.code == "root-mapping-unproven",
  )
  assert_false(root_refused.to_json().stringify().contains(alternate))
  let claim_path = "\{config.retention_root}/\{retention_id}.claim"
  let claim : PromotionClaim = @json.from_json(
    @json.parse(
      bounded_regular_file(claim_path, config.limits.max_protocol_bytes),
    ),
  )
  @fs.write_file(
    claim_path,
    { ..claim, workspace_root_binding: None }.to_json().stringify(),
    create_mode=CreateOrTruncate,
    permission=0o600,
    sync=Full,
  )
  let legacy = inspect_retention_recovery(request, config)
  assert_eq(legacy.outcome, "manual-recovery")
  assert_true(
    legacy.error is Some(error) && error.code == "root-mapping-unproven",
  )
  assert_true(restore_claimed_retention(claimed, record, config))
  assert_true(@sandbox.discard_scratch_tree(scratch) is Ok(_))
  @fs.remove("\{config.retention_root}/\{retention_id}.json")
  ignore(@fs.rmdir(alternate, recursive=true) catch { _ => () })
  cleanup_test_roots(roots)
}

///|
async test "recovery inspection rejects a mismatched claim pair" {
  let (config, roots) = test_executor_config()
  let workspace = config.workspaces["book"].root
  let (scratch, retention_id) = allocate_scratch("request-inspect-pair", config)
  @fs.write_file(
    "\{scratch}/artifact",
    "reviewed",
    create_mode=CreateNew,
    permission=0o600,
  )
  let entry : @sandbox.ScratchEntry = {
    relative_path: "artifact",
    kind: RegularFile,
    size_bytes: 8L,
    fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"reviewed")),
  }
  assert_true(
    retain_scratch(
      scratch,
      retention_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [entry],
      config,
    ),
  )
  let plan = @sandbox.plan_sandbox_promotion(
    { entries: [entry], total_bytes: 8L },
    workspace,
    [{ artifact_path: "artifact", destination_path: "result" }],
  ).unwrap()
  let record = load_retention_record(retention_id, config)
  let claimed = claim_retention_for_promotion(
    record,
    plan.items()[0],
    workspace,
    config,
  )
  @fs.write_file(
    claimed,
    {
      ..record,
      command_digest: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    }
    .to_json()
    .stringify(),
    create_mode=CreateOrTruncate,
    permission=0o600,
    sync=Full,
  )
  let response = inspect_retention_recovery(
    { protocol_version: 4, retention_id },
    config,
  )
  assert_eq(response.outcome, "unavailable")
  assert_eq(response.destination_path, "")
  assert_true(
    response.error is Some(error) && error.code == "inspection-unavailable",
  )
  @fs.remove(claimed)
  @fs.remove("\{config.retention_root}/\{retention_id}.claim")
  assert_true(@sandbox.discard_scratch_tree(scratch) is Ok(_))
  cleanup_test_roots(roots)
}

///|
async test "proven pre-rename claim rollback permits a clean retry" {
  let (config, roots) = test_executor_config()
  let (scratch, retention_id) = allocate_scratch(
    "request-claim-rollback", config,
  )
  @fs.write_file(
    "\{scratch}/artifact",
    "reviewed",
    create_mode=CreateNew,
    permission=0o600,
  )
  let entry : @sandbox.ScratchEntry = {
    relative_path: "artifact",
    kind: RegularFile,
    size_bytes: 8L,
    fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"reviewed")),
  }
  assert_true(
    retain_scratch(
      scratch,
      retention_id,
      "book",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      [entry],
      config,
    ),
  )
  let available = "\{config.retention_root}/\{retention_id}.json"
  let claimed = "\{config.retention_root}/\{retention_id}.promoting"
  let claim_path = "\{config.retention_root}/\{retention_id}.claim"
  @fs.write_file(
    claim_path,
    "prepared",
    create_mode=CreateNew,
    permission=0o600,
    sync=Full,
  )
  assert_true(rollback_pre_rename_claim(available, claimed, claim_path, config))
  assert_true(@fs.exists(available))
  assert_false(@fs.exists(claim_path))
  assert_false(@fs.exists(claimed))
  let record = load_retention_record(retention_id, config)
  let inventory : @sandbox.ScratchInventory = {
    entries: [entry],
    total_bytes: 8L,
  }
  let plan = @sandbox.plan_sandbox_promotion(
    inventory,
    config.workspaces["book"].root,
    [{ artifact_path: "artifact", destination_path: "result" }],
  ).unwrap()
  let retry_claimed = claim_retention_for_promotion(
    record,
    plan.items()[0],
    config.workspaces["book"].root,
    config,
  )
  assert_true(@fs.exists(retry_claimed))
  assert_true(@fs.exists(claim_path))
  assert_eq(sweep_expired_retentions(config), 0)
  assert_true(restore_claimed_retention(retry_claimed, record, config))
  assert_true(@sandbox.discard_scratch_tree(scratch) is Ok(_))
  @fs.remove(available)
  cleanup_test_roots(roots)
}

///|
async test "multi-item promotion refuses before claiming or writing" {
  let (config, roots) = test_executor_config()
  let (scratch, retention_id) = allocate_scratch("request-multi", config)
  @fs.write_file("\{scratch}/a", "a", create_mode=CreateNew, permission=0o600)
  @fs.write_file("\{scratch}/b", "b", create_mode=CreateNew, permission=0o600)
  let entries : Array[@sandbox.ScratchEntry] = [
    {
      relative_path: "a",
      kind: RegularFile,
      size_bytes: 1L,
      fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"a")),
    },
    {
      relative_path: "b",
      kind: RegularFile,
      size_bytes: 1L,
      fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(b"b")),
    },
  ]
  assert_true(
    retain_scratch(
      scratch, retention_id, "book", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      entries, config,
    ),
  )
  let response = promote_retention(
    {
      protocol_version: 4,
      retention_id,
      workspace_id: "book",
      approval_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      command_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      items: [
        { artifact_path: "a", destination_path: "a" },
        { artifact_path: "b", destination_path: "b" },
      ],
    },
    config,
  )
  assert_false(response.completed)
  assert_eq(response.destination_outcome, "not-applied")
  assert_true(response.uncertain_paths.is_empty())
  assert_true(
    response.error is Some(error) &&
    error.message.contains("multiple-promotion-items"),
  )
  assert_true(@fs.exists("\{config.retention_root}/\{retention_id}.json"))
  assert_false(@fs.exists("\{config.retention_root}/\{retention_id}.promoting"))
  assert_false(@fs.exists("\{config.retention_root}/\{retention_id}.claim"))
  assert_false(@fs.exists("\{config.workspaces["book"].root}/a"))
  assert_false(@fs.exists("\{config.workspaces["book"].root}/b"))
  assert_true(@sandbox.discard_scratch_tree(scratch) is Ok(_))
  @fs.remove("\{config.retention_root}/\{retention_id}.json")
  cleanup_test_roots(roots)
}
