///|
async test "artifact browser exports a multi megabyte generated CSV with exact readback" {
  let (config, roots) = test_executor_config()
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "measurements",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/measurements"
  @fs.mkdir(scratch, permission=0o700)
  let expected = @utf8.encode(
    "region,timestamp,value\n" +
    "north,2026-10-08T12:00:00Z,42\n".repeat(100_000),
  )
  assert_true(expected.length() > 2 * 1024 * 1024)
  @fs.write_file(
    scratch + "/measurements.csv",
    expected,
    create_mode=CreateNew,
    permission=0o600,
  )
  let inventory = @sandbox.inventory_scratch(scratch, 32_000_000L).unwrap()
  assert_true(
    retain_scratch(
      scratch,
      binding.retention_id,
      binding.workspace_id,
      "a".repeat(64),
      binding.approval_digest,
      binding.command_digest,
      inventory.entries,
      config,
    ),
  )
  assert_eq(
    export_retained_artifact(binding, "measurements.csv", config),
    expected,
  )
  let tail_offset = expected.length().to_int64() - 19L
  let tail = read_retained_artifact(
    binding,
    "measurements.csv",
    config,
    offset=tail_offset,
  )
  assert_true(tail.eof)
  assert_eq(
    @base64.decode(tail.content_base64),
    expected[expected.length() - 19:].to_owned(),
  )
  if @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) {
    let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
    let destination = config.retention_root + "/measurements-copy.csv"
    let code = @process.run(
      executable,
      ["export", "measurements.csv"],
      extra_env={ "MOONFORT_EXECUTOR_CONFIG": config_path },
      stdin=@process.redirect_from_file(binding_path),
      stdout=@process.redirect_to_file(
        destination,
        create_mode=CreateNew,
        permission=0o600,
      ),
    )
    assert_eq(code, 0)
    assert_eq(@fs.read_file(destination).binary(), expected)
  }
  println(
    "Generated CSV export verified: \{expected.length()} bytes, 100000 rows",
  )
  cleanup_test_roots(roots)
}
