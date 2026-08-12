///|
async fn local_e2e_config(
  tool_label : String,
  executable : String,
) -> (ExecutorConfig, Array[String]) {
  let (base, roots) = test_executor_config()
  let policy = { ..base.workspaces["book"], allowed_commands: [tool_label] }
  (
    {
      ..base,
      workspaces: { "book": policy },
      local_tools: Map([(tool_label, executable)]),
    },
    roots,
  )
}

///|
fn local_e2e_grant(
  approval_id : String,
  request_id : String,
  tool_label : String,
  args : Array[String],
  output_bytes? : Int = 8_192,
) -> ExecutionGrant {
  {
    ..test_grant(approval_id),
    request_id,
    allowed_commands: [tool_label],
    limits: { ..test_grant("unused").limits, output_bytes, },
    command: Exec(tool=tool_label, args~),
  }
}

///|
fn require_local_e2e() -> Bool {
  @env.get_env_var("MOONFORT_REQUIRE_LOCAL_E2E") == Some("1")
}

///|
async test "published grant executes only in private local snapshot and binds evidence" {
  let shell = @fs.realpath("/bin/sh")
  let (config, roots) = local_e2e_config("sh", shell)
  let workspace = config.workspaces["book"].root
  @fs.write_file(
    "\{workspace}/original.txt",
    "canonical",
    create_mode=CreateNew,
    permission=0o600,
  )
  // The first redirection deliberately targets the canonical workspace. The
  // shell continues so a successful backend also proves scratch writes and
  // structured diffing in the same real invocation.
  let script = "printf pwned > \"$1/canonical-write.txt\"; printf artifact > generated.txt; printf mutated > original.txt; printf e2e-ok"
  let grant = local_e2e_grant("approval-local-e2e", "request-local-e2e", "sh", [
    "-c", script, "moonfort-e2e", workspace,
  ])
  let published = publish_grant({ protocol_version: 3, grant }, config)
  assert_true(published.published)
  assert_eq(published.approval_digest, grant_digest(grant))
  assert_true(
    @fs.exists("\{config.approval_root}/pending/\{grant.approval_id}.json"),
  )
  let response = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  guard response.receipt() is Some(receipt) else {
    fail("published local grant must produce a terminal receipt")
  }
  assert_eq(receipt.approval_id, grant.approval_id)
  assert_eq(receipt.approval_digest, grant_digest(grant))
  assert_true(receipt.command_digest.length() == 64)
  assert_true(receipt.profile_digest.length() == 64)
  assert_false(@fs.exists("\{workspace}/canonical-write.txt"))
  assert_eq(
    @utf8.decode_lossy(@fs.read_file("\{workspace}/original.txt").binary()),
    "canonical",
  )
  assert_true(
    @fs.exists("\{config.approval_root}/consumed/\{grant.approval_id}.json"),
  )
  match receipt.enforcement {
    Degraded => {
      assert_true(receipt.status is Exited)
      assert_eq(receipt.exit_code, Some(0))
      assert_true(receipt.output.contains("e2e-ok"))
      assert_eq(receipt.changed_paths, ["generated.txt", "original.txt"])
      assert_eq(receipt.changes.length(), 2)
      assert_true(
        receipt.changes[0].relative_path == "generated.txt" &&
        receipt.changes[0].change is Added &&
        receipt.changes[0].after is Some(after) &&
        after.kind is RegularFile &&
        after.size_bytes == 8L,
      )
      assert_true(
        receipt.changes[1].relative_path == "original.txt" &&
        receipt.changes[1].change is Modified &&
        receipt.changes[1].before is Some(before) &&
        receipt.changes[1].after is Some(after) &&
        before.fingerprint != after.fingerprint,
      )
      assert_true(receipt.artifacts.is_empty())
      assert_true(receipt.cleanup_verified)
      guard receipt.retention_id is Some(retention_id) else {
        fail("changed local execution must retain scratch by opaque ID")
      }
      let retained = "\{config.scratch_root}/\{retention_id}"
      assert_eq(
        @utf8.decode_lossy(@fs.read_file("\{retained}/generated.txt").binary()),
        "artifact",
      )
      assert_eq(
        @utf8.decode_lossy(@fs.read_file("\{retained}/original.txt").binary()),
        "mutated",
      )
      let expected_profile = profile_for_grant(
        grant,
        config.workspaces["book"],
        retained,
      )
      let selected_tools = { "sh": shell }
      assert_eq(
        receipt.profile_digest,
        @sandbox.profile_digest(expected_profile),
      )
      assert_eq(
        receipt.command_digest,
        command_digest(
          grant,
          expected_profile,
          selected_tools,
          "local",
          trusted_local_binding_digest(selected_tools),
        ),
      )
      println("moonfort local E2E: sandbox-exec execution verified")
    }
    Refused => {
      if require_local_e2e() {
        fail(
          "local sandbox enforcement was required but unavailable: \{receipt.denial_reason.unwrap_or("no backend reason")}",
        )
      }
      assert_true(receipt.status is Failed)
      assert_true(receipt.exit_code is None)
      assert_false(receipt.cleanup_verified)
      assert_true(receipt.retention_id is None)
      assert_true(@fs.readdir(config.scratch_root).is_empty())
      println(
        "moonfort local E2E: sandbox-exec unavailable or unverifiable (\{receipt.denial_reason.unwrap_or("no backend reason")}); fail-closed refusal verified",
      )
    }
    Enforced => fail("local executor must never claim full enforcement")
  }
  let replay = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  assert_true(replay.error() is Some(error) && error.code == "approval-refused")
  cleanup_test_roots(roots)
}

///|
async test "real local executor enforces bounded output or refuses closed" {
  let shell = @fs.realpath("/bin/sh")
  let (config, roots) = local_e2e_config("sh", shell)
  let workspace = config.workspaces["book"].root
  let grant = local_e2e_grant(
    "approval-output-e2e",
    "request-output-e2e",
    "sh",
    ["-c", "while :; do printf 0123456789abcdef; done"],
    output_bytes=256,
  )
  let published = publish_grant({ protocol_version: 3, grant }, config)
  assert_true(published.published)
  let response = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  guard response.receipt() is Some(receipt) else {
    fail("published local grant must produce a terminal receipt")
  }
  match receipt.enforcement {
    Degraded => {
      assert_true(receipt.status is Killed)
      assert_eq(receipt.limit_reason, Some("output-limit"))
      assert_true(receipt.output_truncated)
      assert_true(@utf8.encode(receipt.output).length() <= 256)
      assert_true(receipt.retention_id is None)
      assert_true(receipt.cleanup_verified)
    }
    Refused => {
      if require_local_e2e() {
        fail(
          "local sandbox output enforcement was required but unavailable: \{receipt.denial_reason.unwrap_or("no backend reason")}",
        )
      }
      assert_true(receipt.status is Failed)
      assert_true(receipt.exit_code is None)
      assert_false(receipt.cleanup_verified)
      assert_true(receipt.retention_id is None)
    }
    Enforced => fail("local executor must never claim full enforcement")
  }
  assert_true(@fs.readdir(config.scratch_root).is_empty())
  assert_true(@fs.readdir(workspace).is_empty())
  cleanup_test_roots(roots)
}

///|
async test "unavailable backend publication never falls back to a host process" {
  let (config, roots) = test_executor_config()
  let grant = {
    ..test_grant("approval-unavailable-e2e"),
    request_id: "request-unavailable-e2e",
    backend: Unavailable,
  }
  let published = publish_grant({ protocol_version: 3, grant }, config)
  assert_false(published.published)
  assert_true(published.error is Some(error) && error.code == "grant-refused")
  assert_false(
    @fs.exists("\{config.approval_root}/pending/\{grant.approval_id}.json"),
  )
  let response = execute_invocation(
    { protocol_version: 3, approval_id: grant.approval_id },
    config,
  )
  assert_true(
    response.error() is Some(error) && error.code == "approval-refused",
  )
  assert_true(response.receipt() is None)
  assert_true(@fs.readdir(config.scratch_root).is_empty())
  cleanup_test_roots(roots)
}
