///|
async fn fixture_terminal_output(
  bytes : Bytes,
  grant : ExecutionGrant,
  config : ExecutorConfig,
  truncated? : Bool = false,
) -> (@sandbox.SandboxReceipt, LiveOutputReference) {
  let digest = grant_digest(grant)
  let started = begin_live_output(
    grant.request_id,
    grant.approval_id,
    digest,
    config,
  )
  @fs.write_file(
    live_output_root(config) + "/" + started.stream_id + ".blob",
    bytes,
    create_mode=CreateNew,
    permission=0o600,
  )
  let raw = if truncated {
    @sandbox.killed_receipt(
      grant.request_id,
      LocalOs,
      Degraded,
      "c".repeat(64),
      @utf8.decode_lossy(bytes),
      true,
      "output-limit",
    )
  } else {
    @sandbox.exited_receipt(
      grant.request_id,
      LocalOs,
      Degraded,
      "c".repeat(64),
      0,
      @utf8.decode_lossy(bytes),
    )
  }
  let raw = { ..raw, unverified_limits: ["synthetic-backend-fixture"], }
  let finished = finalize_live_output(
    started,
    grant.approval_id,
    digest,
    raw,
    config,
  )
  let retained = retain_receipt_command_output(
    raw,
    grant,
    digest,
    "b".repeat(64),
    Some(finished),
    config,
  )
  (
    retained.with_approval_binding(
      approval_id=grant.approval_id,
      approval_digest=digest,
      command_digest="b".repeat(64),
      cleanup_verified=true,
    ),
    finished,
  )
}

///|
async test "terminal spool retains small binary NUL Unicode and hard-limit bytes exactly" {
  let (config, roots) = test_executor_config()
  defer cleanup_test_roots(roots)
  for
    i, (bytes, truncated, media) in [
      (b"\x00\xff\x80\xc0\xfe\n", false, "application/octet-stream"),
      (b"hello\x00world", true, CommandOutputMediaType),
      (@utf8.encode("月🌙\n"), true, CommandOutputMediaType),
      (b"prefix\xf0\x9f", true, "application/octet-stream"),
    ] {
    let grant = {
      ..test_grant("approval-raw-\{i}"),
      request_id: "run-raw-\{i}",
      limits: {
        ..test_grant("unused").limits,
        output_bytes: bytes.length().max(1),
      },
    }
    let (receipt, live) = fixture_terminal_output(
      bytes,
      grant,
      config,
      truncated~,
    )
    guard receipt.output_artifact is Some(reference) else {
      fail("exact bytes must be retained")
    }
    assert_eq(reference.media_type, media)
    assert_eq(reference.sha256, live.sha256)
    assert_eq(reference.size_bytes, bytes.length().to_int64())
    assert_true(
      @utf8.encode(receipt.output).length() <= grant.limits.output_bytes,
    )
    let request : CommandOutputReadRequest = {
      protocol_version: 1,
      reference,
      run_id: receipt.run_id,
      approval_digest: receipt.approval_digest,
      command_digest: receipt.command_digest,
      offset: 0L,
      max_bytes: 8192,
    }
    assert_eq(export_command_output(request, config), bytes)
    assert_eq(export_command_output(request, config), bytes)
  }
  let grant = {
    ..test_grant("approval-small-text"),
    request_id: "run-small-text",
  }
  let (text, _) = fixture_terminal_output(
    @utf8.encode("small 🌙\u0000"),
    grant,
    config,
  )
  assert_true(text.output_artifact is None)
}

///|
async test "changed signed terminal spool never falls back to text projection" {
  let (config, roots) = test_executor_config()
  defer cleanup_test_roots(roots)
  let grant = {
    ..test_grant("approval-spool-tamper"),
    request_id: "run-spool-tamper",
  }
  let (receipt, live) = fixture_terminal_output(b"a\xff", grant, config)
  @fs.write_file(
    live_output_root(config) + "/" + live.stream_id + ".blob",
    b"b\xff",
    create_mode=CreateOrTruncate,
  )
  try
    retained_receipt_output_bytes(
      receipt,
      grant,
      grant_digest(grant),
      Some(live),
      config,
    )
  catch {
    ArtifactIntegrityFailure => ()
    error => fail("wrong refusal: \{error}")
  } noraise {
    _ => fail("mismatched spool accepted")
  }
  try
    retained_receipt_output_bytes(
      receipt,
      { ..grant, approval_id: "other-approval", },
      grant_digest(grant),
      Some(live),
      config,
    )
  catch {
    ArtifactIntegrityFailure => ()
    error => fail("wrong refusal: \{error}")
  } noraise {
    _ => fail("mismatched approval accepted")
  }
}

///|
async test "missing terminal spool cannot be replaced by a signed empty artifact" {
  let (config, roots) = test_executor_config()
  defer cleanup_test_roots(roots)
  for i, terminal in [true, false] {
    let grant = {
      ..test_grant("approval-missing-spool-\{i}"),
      request_id: "run-missing-spool-\{i}",
    }
    let started = begin_live_output(
      grant.request_id,
      grant.approval_id,
      grant_digest(grant),
      config,
    )
    let receipt = if terminal {
      @sandbox.exited_receipt(
        grant.request_id,
        LocalOs,
        Degraded,
        "c".repeat(64),
        0,
        "nonempty captured output",
      )
    } else {
      @sandbox.killed_receipt(
        grant.request_id,
        LocalOs,
        Degraded,
        "c".repeat(64),
        "nonempty captured output",
        true,
        "output-limit",
      )
    }
    try
      finalize_live_output(
        started,
        grant.approval_id,
        grant_digest(grant),
        receipt,
        config,
      )
    catch {
      error => assert_true(error.to_string().contains("spool is missing"))
    } noraise {
      _ => fail("missing terminal spool was signed as empty")
    }
    assert_false(
      @fs.exists(live_output_root(config) + "/" + started.stream_id + ".blob"),
    )
  }
  let grant = {
    ..test_grant("approval-never-started"),
    request_id: "run-never-started",
  }
  let started = begin_live_output(
    grant.request_id,
    grant.approval_id,
    grant_digest(grant),
    config,
  )
  let failed = @sandbox.failed_receipt(
    grant.request_id,
    LocalOs,
    Refused,
    "c".repeat(64),
    "fixture never started",
  )
  let finalized = finalize_live_output(
    started,
    grant.approval_id,
    grant_digest(grant),
    failed,
    config,
  )
  assert_eq(finalized.status, "failed")
  assert_eq(finalized.size_bytes, 0L)
}

///|
// Cross-product fixture. The backend observation is synthetic; these are the
// real Fort spool finalizer, retained-artifact producer and signature checks.
// Test-only credentials remain in private temporary config, never in UI output.
async test "export signed Fort receipt fixture for Claw host integration" {
  guard @env.get_env_var("MOONFORT_R13_FIXTURE_ROOT") is Some(destination) else {
    return
  }
  let (base, _) = test_executor_config()
  let config = {
    ..base,
    limits: { ..base.limits, retention_ms: 86_400_000L, },
  }
  let grant = {
    ..test_grant("approval-cross-product"),
    request_id: "run-fort-cross-product",
  }
  assert_true(publish_grant({ protocol_version: 3, grant, }, config).published)
  assert_eq(
    consume_grant(
      { protocol_version: 3, approval_id: grant.approval_id, },
      config,
    ),
    grant,
  )
  let bytes = b"Fort\x00\xff\x80\xc0\xfe\nexact"
  let (receipt, live) = fixture_terminal_output(bytes, grant, config)
  guard receipt.output_artifact is Some(reference) else {
    fail("fixture did not retain exact output")
  }
  let limits = config.limits
  let configuration : Json = {
    "approval_root": config.approval_root,
    "scratch_root": config.scratch_root,
    "retention_root": config.retention_root,
    "artifact_key_id": config.artifact_key_id,
    "artifact_signing_key": config.artifact_signing_key,
    "workspaces": Json::object(Map([])),
    "local_tools": Json::object(Map([])),
    "aen_backends": Json::object(Map([])),
    "limits": {
      "max_protocol_bytes": limits.max_protocol_bytes,
      "max_wall_clock_ms": limits.max_wall_clock_ms,
      "max_cpu_seconds": limits.max_cpu_seconds,
      "max_memory_mib": limits.max_memory_mib,
      "max_disk_mib": limits.max_disk_mib,
      "max_processes": limits.max_processes,
      "max_output_bytes": limits.max_output_bytes,
      "max_model_output_bytes": limits.max_model_output_bytes,
      "max_command_args": limits.max_command_args,
      "max_argument_bytes": limits.max_argument_bytes,
      "max_changed_paths": limits.max_changed_paths,
      "retention_ms": limits.retention_ms,
    },
  }
  @fs.write_file(
    destination + "/fort-config.json",
    configuration.stringify(),
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  @fs.write_file(
    destination + "/fort-fixture.json",
    (
      {
        "grant": grant,
        "receipt": receipt,
        "live_output": live,
        "fixture_kind": "synthetic-backend-real-Fort-retention",
        "expected_hex": @crypto.bytes_to_hex_string(bytes),
      } : Json).stringify(),
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  assert_eq(
    export_command_output(
      {
        protocol_version: 1,
        reference,
        run_id: receipt.run_id,
        approval_digest: receipt.approval_digest,
        command_digest: receipt.command_digest,
        offset: 0L,
        max_bytes: 8192,
      },
      config,
    ),
    bytes,
  )
  println("FORT_SIGNED_RETAINED_FIXTURE_READY")
}
