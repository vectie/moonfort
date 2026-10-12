///|
// Private deterministic content/IDs; no backend execution or promotion occurs.
#skip("Run with the private round55 fixture root through the retained .mbtx runner")
async test "export five real locked promotion inspection fixtures for Claw hosts" {
  guard @env.get_env_var("ROUND55_FIXTURE_ROOT") is Some(root) else {
    fail("private fixture root required")
  }
  for name in ["approvals", "scratch", "retention", "workspace"] {
    @fs.mkdir(root + "/" + name, permission=0o700)
  }
  for name in ["pending", "consumed"] {
    @fs.mkdir(root + "/approvals/" + name, permission=0o700)
  }
  @fs.mkdir(root + "/retention/output-artifacts", permission=0o700)
  @fs.mkdir(root + "/retention/live-output", permission=0o700)
  @fs.mkdir(root + "/workspace/reviewed", permission=0o700)
  @fs.write_file(
    root + "/CANARY-private-host-path",
    "CANARY-secret-content",
    create_mode=CreateNew,
    permission=0o600,
  )
  let limits : Json = {
    "max_protocol_bytes": 65536,
    "max_wall_clock_ms": 5000,
    "max_cpu_seconds": 2,
    "max_memory_mib": 256,
    "max_disk_mib": 32,
    "max_processes": 32,
    "max_output_bytes": 65536,
    "max_model_output_bytes": 32768,
    "max_command_args": 16,
    "max_argument_bytes": 4096,
    "max_changed_paths": 32,
    "retention_ms": "86400000",
  }
  let raw_config : Json = {
    "approval_root": root + "/approvals",
    "scratch_root": root + "/scratch",
    "retention_root": root + "/retention",
    "artifact_key_id": "fixture-key-55",
    "artifact_signing_key": "CANARY-only-fixture-key-01234567890123456789",
    "workspaces": {
      "book": {
        "root": root + "/workspace",
        "read_only_roots": [root + "/workspace"],
        "allowed_backends": [@sandbox.SandboxBackendKind::LocalOs],
        "allowed_networks": [@sandbox.SandboxNetworkMode::Deny],
        "allowed_egress": [],
        "allowed_commands": ["true"],
        "allow_degraded": true,
      },
    },
    "local_tools": {},
    "aen_backends": {},
    "limits": limits,
  }
  @fs.write_file(
    root + "/fort-config.json",
    raw_config.stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  let config = load_executor_config(root + "/fort-config.json")
  let fingerprint = @crypto.bytes_to_hex_string(
    @crypto.sha256(b"reviewed-output-55"),
  )
  let entry : @sandbox.ScratchEntry = {
    relative_path: "artifact",
    kind: RegularFile,
    size_bytes: 18L,
    fingerprint,
  }
  let cases : Array[Json] = []
  for
    outcome in [
      "desired-applied", "reviewed-prestate", "diverged", "unavailable", "manual-recovery",
    ] {
    let retention_id = "return55-" + outcome
    let scratch = config.scratch_root + "/" + retention_id
    @fs.mkdir(scratch, permission=0o700)
    @fs.write_file(
      scratch + "/artifact",
      b"reviewed-output-55",
      create_mode=CreateNew,
      permission=0o600,
    )
    assert_true(
      retain_scratch(
        scratch,
        retention_id,
        "book",
        "a".repeat(64),
        "b".repeat(64),
        "c".repeat(64),
        [entry],
        config,
      ),
    )
    let destination = "reviewed/" + outcome
    let plan = @sandbox.plan_sandbox_promotion(
      { entries: [entry], total_bytes: 18L, },
      root + "/workspace",
      [{ artifact_path: "artifact", destination_path: destination, }],
    ).unwrap()
    let record = load_retention_record(retention_id, config)
    ignore(
      claim_retention_for_promotion(
        record,
        plan.items()[0],
        root + "/workspace",
        config,
      ),
    )
    match outcome {
      "desired-applied" =>
        @fs.write_file(
          root + "/workspace/" + destination,
          b"reviewed-output-55",
          create_mode=CreateNew,
          permission=0o600,
        )
      "diverged" =>
        @fs.write_file(
          root + "/workspace/" + destination,
          b"different-output-55",
          create_mode=CreateNew,
          permission=0o600,
        )
      "unavailable" =>
        @fs.symlink(
          root + "/workspace/" + destination,
          target=root + "/CANARY-private-host-path",
        )
      "manual-recovery" => {
        let path = config.retention_root + "/" + retention_id + ".claim"
        let claim : PromotionClaim = @json.from_json(
          @json.parse(@fs.read_file(path).text()),
        )
        @fs.write_file(
          path,
          { ..claim, workspace_root_binding: None, }.to_json().stringify(),
        )
      }
      _ => ()
    }
    let inspected = inspect_retention_recovery(
      { protocol_version: 4, retention_id, },
      config,
    )
    assert_eq(inspected.outcome, outcome)
    cases.push({
      "outcome": outcome,
      "retention_id": retention_id,
      "pending_attempt_id": "attempt55-" + outcome,
      "destination_relative": destination,
    })
  }
  @fs.write_file(
    root + "/cases.json",
    cases.to_json().stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  println("FORT_REAL_LOCKED_INSPECTION_FIXTURES_READY")
}
