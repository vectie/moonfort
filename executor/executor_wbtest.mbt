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
      scratch, retention_id, "book", "approval-digest", "command-digest", config,
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
      scratch, retention_id, "book", "approval-digest", "command-digest", config,
    ),
  )
  let base : RetentionPromotionRequest = {
    protocol_version: 3,
    retention_id,
    workspace_id: "book",
    approval_digest: "approval-digest",
    command_digest: "command-digest",
    items: [
      {
        artifact_path: "generated.txt",
        destination_path: "promoted/generated.txt",
      },
    ],
  }
  let mismatch = promote_retention(
    { ..base, command_digest: "substituted" },
    config,
  )
  assert_false(mismatch.completed)
  assert_false(@fs.exists("\{config.workspaces["book"].root}/promoted"))
  let promoted = promote_retention(base, config)
  assert_true(promoted.completed)
  assert_eq(promoted.workspace_id, "book")
  assert_eq(promoted.approval_digest, "approval-digest")
  assert_eq(promoted.command_digest, "command-digest")
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
