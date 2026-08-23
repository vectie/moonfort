///|
async test "complete output artifact is signed, digest checked, and projected" {
  let (config, roots) = test_executor_config()
  let approval_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let command_digest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let output = [ for _ in 0..<10_000 => "abcd" ].join("")
  let small_receipt = @sandbox.exited_receipt(
    "run-small",
    LocalOs,
    Degraded,
    command_digest,
    0,
    "small",
  )
  assert_false(
    output_artifact_required(
      small_receipt,
      config.limits.max_model_output_bytes,
    ),
  )
  assert_true(
    output_artifact_required(
      { ..small_receipt, output, },
      config.limits.max_model_output_bytes,
    ),
  )
  assert_true(
    output_artifact_required(
      { ..small_receipt, output_truncated: true },
      config.limits.max_model_output_bytes,
    ),
  )
  let reference = retain_command_output_artifact(
    "run-output-1",
    output,
    config.limits.max_output_bytes,
    approval_digest,
    command_digest,
    config,
  )
  assert_eq(reference.run_id, "run-output-1")
  assert_eq(reference.size_bytes, 40_000L)
  assert_eq(reference.media_type, "text/plain; charset=utf-8")
  assert_eq(reference.key_id, config.artifact_key_id)
  assert_eq(reference.signature.length(), 64)
  assert_false(reference.to_json().stringify().contains(config.retention_root))
  let restored = read_command_output_artifact(
    reference, "run-output-1", approval_digest, command_digest, config,
  )
  assert_eq(@utf8.decode(restored), output)
  let projected = model_output_projection(
    output,
    config.limits.max_model_output_bytes,
  )
  assert_true(
    @utf8.encode(projected).length() <= config.limits.max_model_output_bytes,
  )
  assert_true(projected.contains("full output retained in artifact"))
  assert_true(projected.has_prefix("abcd"))
  assert_true(projected.has_suffix("abcd"))
  let unicode_projection = model_output_projection(
    [ for _ in 0..<100 => "月🌙" ].join(""),
    129,
  )
  assert_true(@utf8.encode(unicode_projection).length() <= 129)
  cleanup_test_roots(roots)
}

///|
async test "output artifact refuses binding forgery and substituted bytes" {
  let (config, roots) = test_executor_config()
  let approval_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let command_digest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let reference = retain_command_output_artifact(
    "run-output-2",
    "complete-output",
    config.limits.max_output_bytes,
    approval_digest,
    command_digest,
    config,
  )
  let wrong_run_refused = try {
    ignore(
      read_command_output_artifact(
        reference, "run-output-other", approval_digest, command_digest, config,
      ),
    )
    false
  } catch {
    InvalidReference => true
    _ => false
  }
  assert_true(wrong_run_refused)
  let forged = { ..reference, sha256: command_digest }
  let forged_refused = try {
    ignore(
      read_command_output_artifact(
        forged, "run-output-2", approval_digest, command_digest, config,
      ),
    )
    false
  } catch {
    ArtifactIntegrityFailure => true
    _ => false
  }
  assert_true(forged_refused)
  let blob = "\{command_output_artifact_root(config)}/\{reference.artifact_id}.blob"
  @fs.write_file(
    blob,
    "substituted!!!!",
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  let substituted_refused = try {
    ignore(
      read_command_output_artifact(
        reference, "run-output-2", approval_digest, command_digest, config,
      ),
    )
    false
  } catch {
    ArtifactIntegrityFailure => true
    _ => false
  }
  assert_true(substituted_refused)
  @fs.remove(blob)
  let outside = @fs.realpath(@fs.tmpdir(prefix="moonfort-output-outside-"))
  @fs.write_file(
    "\{outside}/payload",
    "complete-output",
    create_mode=CreateNew,
    permission=0o600,
  )
  @fs.symlink(blob, target="\{outside}/payload")
  let linked_refused = try {
    ignore(
      read_command_output_artifact(
        reference, "run-output-2", approval_digest, command_digest, config,
      ),
    )
    false
  } catch {
    ArtifactUnavailable => true
    _ => false
  }
  assert_true(linked_refused)
  let traversal = { ..reference, artifact_id: "../escape" }
  let traversal_refused = try {
    ignore(
      read_command_output_artifact(
        traversal, "run-output-2", approval_digest, command_digest, config,
      ),
    )
    false
  } catch {
    InvalidReference => true
    _ => false
  }
  assert_true(traversal_refused)
  ignore(@fs.rmdir(outside, recursive=true))
  cleanup_test_roots(roots)
}

///|
async test "output artifact enforces byte limit and expires with bounded cleanup" {
  let (base, roots) = test_executor_config()
  let config : ExecutorConfig = {
    ..base,
    limits: { ..base.limits, retention_ms: 1L },
  }
  let approval_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let command_digest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let oversized_refused = try {
    ignore(
      retain_command_output_artifact(
        "run-output-limit", "too-large", 4, approval_digest, command_digest, config,
      ),
    )
    false
  } catch {
    InvalidReference => true
    _ => false
  }
  assert_true(oversized_refused)
  let reference = retain_command_output_artifact(
    "run-output-expire", "expires", 64, approval_digest, command_digest, config,
  )
  @async.sleep(5)
  let expired = try {
    ignore(
      read_command_output_artifact(
        reference, "run-output-expire", approval_digest, command_digest, config,
      ),
    )
    false
  } catch {
    ArtifactExpired => true
    _ => false
  }
  assert_true(expired)
  assert_eq(sweep_expired_output_artifacts(config), 1)
  let root = command_output_artifact_root(config)
  assert_false(@fs.exists("\{root}/\{reference.artifact_id}.blob"))
  assert_false(@fs.exists("\{root}/\{reference.artifact_id}.json"))
  cleanup_test_roots(roots)
}
