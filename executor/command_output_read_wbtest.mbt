///|
fn test_output_read_request(
  reference : @sandbox.CommandOutputArtifactRef,
  max_bytes? : Int = 32_768,
) -> CommandOutputReadRequest {
  {
    protocol_version: 1,
    reference,
    run_id: reference.run_id,
    approval_digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    command_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    offset: 0L,
    max_bytes,
  }
}

///|
async fn test_retained_output(
  output : String,
  config : ExecutorConfig,
) -> @sandbox.CommandOutputArtifactRef {
  retain_command_output_artifact(
    "run-readable-output",
    output,
    config.limits.max_output_bytes,
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    config,
  )
}

///|
async test "output reader resumes exact byte chunks with retry and no execution" {
  let (config, roots) = test_executor_config()
  let output = [ for _ in 0..<5_000 => "A月🌙\u{0}\n" ].join("")
  let expected = @utf8.encode(output)
  let reference = test_retained_output(output, config)
  let request = test_output_read_request(reference, max_bytes=1003)
  let decoded = decode_command_output_read_request(request.to_json())
  assert_eq(decoded, request)
  let restored = @buffer.Buffer()
  let mut offset = 0L
  while offset < reference.size_bytes {
    let page = read_command_output({ ..request, offset, }, config)
    assert_eq(page.status, "available")
    assert_true(page.error is None)
    assert_eq(page.reference, Some(reference))
    assert_eq(page.offset, offset)
    assert_eq(page, read_command_output({ ..request, offset, }, config))
    let bytes = @base64.decode(page.content_base64)
    assert_true(bytes.length() <= request.max_bytes)
    assert_eq(page.next_offset, offset + bytes.length().to_int64())
    assert_eq(page.eof, page.next_offset == reference.size_bytes)
    restored.write_bytes(bytes)
    offset = page.next_offset
  }
  assert_eq(restored.to_bytes(), expected)
  let end = read_command_output({ ..request, offset, }, config)
  assert_true(end.eof)
  assert_eq(end.content_base64, "")
  assert_eq(end.next_offset, offset)
  assert_eq(@fs.readdir(config.approval_root + "/pending"), [])
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.scratch_root), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  cleanup_test_roots(roots)
}

///|
async test "output reader rejects invalid cursors requests and receipt bindings" {
  let (config, roots) = test_executor_config()
  let reference = test_retained_output("hello 🌙", config)
  let request = test_output_read_request(reference)
  for
    invalid in [
      { ..request, protocol_version: 3, },
      { ..request, offset: -1L, },
      { ..request, offset: reference.size_bytes + 1L, },
      { ..request, max_bytes: 0, },
      { ..request, max_bytes: config.limits.max_output_bytes + 1, },
      { ..request, run_id: "another-run", },
      { ..request, approval_digest: request.command_digest, },
      { ..request, command_digest: request.approval_digest, },
      { ..request, reference: { ..reference, artifact_id: "../escape", }, },
      {
        ..request,
        reference: { ..reference, sha256: request.command_digest, },
      },
    ] {
    let response = read_command_output(invalid, config)
    assert_eq(response.status, "refused")
    assert_true(response.error is Some(_))
    assert_true(response.reference is None)
    assert_eq(response.content_base64, "")
    assert_false(response.eof)
    assert_false(response.to_json().stringify().contains(config.retention_root))
  }
  guard request.to_json() is Object(fields) else { fail("expected object") }
  fields["path"] = ToJson::to_json("/tmp/untrusted")
  assert_true(
    try {
      ignore(decode_command_output_read_request(Json::object(fields)))
      false
    } catch {
      _ => true
    },
  )
  cleanup_test_roots(roots)
}

///|
async test "output reader preserves expiry absence and integrity refusal" {
  let (config, roots) = test_executor_config()
  let reference = test_retained_output("retained original", config)
  let request = test_output_read_request(reference)
  let expired = read_command_output(
    { ..request, reference: { ..reference, expires_at_ms: 1L, }, },
    config,
  )
  assert_eq(expired.status, "expired")
  assert_eq(expired.error.unwrap().code, "output-expired")
  let blob = command_output_artifact_root(config) +
    "/" +
    reference.artifact_id +
    ".blob"
  @fs.write_file(
    blob,
    "substitute bytes!",
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  let changed = read_command_output(request, config)
  assert_eq(changed.status, "refused")
  assert_eq(changed.error.unwrap().code, "output-integrity-refused")
  assert_eq(changed.content_base64, "")
  @fs.remove(blob)
  let missing = read_command_output(request, config)
  assert_eq(missing.status, "unavailable")
  assert_eq(missing.error.unwrap().code, "output-unavailable")
  assert_eq(missing.content_base64, "")
  cleanup_test_roots(roots)
}

///|
async test "output reader bounds base64 protocol responses and permits empty artifacts" {
  let (base, roots) = test_executor_config()
  let config = {
    ..base,
    limits: { ..base.limits, max_protocol_bytes: 4_096, },
  }
  let reference = test_retained_output(
    [ for _ in 0..<20_000 => "x" ].join(""),
    config,
  )
  let page = read_command_output(test_output_read_request(reference), config)
  assert_eq(page.status, "available")
  assert_true(
    @utf8.encode(page.to_json().stringify()).length() <=
    config.limits.max_protocol_bytes,
  )
  assert_true(page.next_offset > 0L)
  assert_true(page.next_offset <= 1_536L)
  let empty = test_retained_output("", config)
  let end = read_command_output(test_output_read_request(empty), config)
  assert_eq(end.status, "available")
  assert_true(end.eof)
  assert_eq(end.next_offset, 0L)
  assert_eq(end.content_base64, "")
  cleanup_test_roots(roots)
}

///|
async test "output export reads a multi megabyte artifact once without paging or execution" {
  let (base, roots) = test_executor_config()
  let config = {
    ..base,
    limits: { ..base.limits, max_output_bytes: 4 * 1024 * 1024, },
  }
  let output = [ for _ in 0..<(256 * 1024) => "A月🌙" ].join("")
  let expected = @utf8.encode(output)
  assert_eq(expected.length(), 2 * 1024 * 1024)
  let reference = test_retained_output(output, config)
  let request = test_output_read_request(reference, max_bytes=expected.length())
  let started = @env.now()
  let bytes = export_command_output(request, config)
  let elapsed = @env.now() - started
  println("2 MiB verified export elapsed_ms=\{elapsed}; one export invocation")
  assert_eq(bytes, expected)
  assert_eq(export_command_output(request, config), expected)
  match @env.get_env_var("MOONFORT_OUTPUT_READER_CLI") {
    Some(executable) =>
      test_output_reader_cli(executable, request, expected, config)
    None => ()
  }
  for
    partial in [
      { ..request, offset: 1L, },
      { ..request, max_bytes: expected.length() - 1, },
    ] {
    assert_true(
      try {
        ignore(export_command_output(partial, config))
        false
      } catch {
        InvalidReference => true
        _ => false
      },
    )
  }
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.scratch_root), [])
  cleanup_test_roots(roots)
}

///|
/// Optional integration leg: the validation script supplies the freshly built
/// reader. It invokes only that read-only controller, never an executor.
async fn test_output_reader_cli(
  executable : String,
  request : CommandOutputReadRequest,
  expected : Bytes,
  config : ExecutorConfig,
) -> Unit {
  let config_path = config.retention_root + "/test-config.json"
  let request_path = config.retention_root + "/test-request.json"
  let destination = config.retention_root + "/downloaded-output.txt"
  let limits = config.limits
  let config_json : Json = {
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
    config_path,
    config_json.stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  @fs.write_file(
    request_path,
    request.to_json().stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let (code, stdout, stderr) = @process.collect_output(
    executable,
    ["--export"],
    extra_env~,
    stdin=@process.redirect_from_file(request_path),
  )
  assert_eq(code, 0)
  assert_eq(stderr.binary(), b"")
  assert_eq(stdout.binary(), expected)
  let file_code = @process.run(
    executable,
    ["--export"],
    extra_env~,
    stdin=@process.redirect_from_file(request_path),
    stdout=@process.redirect_to_file(
      destination,
      create_mode=CreateNew,
      permission=0o600,
    ),
  )
  assert_eq(file_code, 0)
  assert_eq(@fs.read_file(destination).binary(), expected)
  let (page_code, page_stdout, _) = @process.collect_output(
    executable,
    [],
    extra_env~,
    stdin=@process.redirect_from_file(request_path),
  )
  assert_eq(page_code, 0)
  let page = @json.parse(@utf8.decode(page_stdout.binary()))
  guard page is Object(fields) else { fail("CLI page must be an object") }
  assert_eq(fields["status"], ToJson::to_json("available"))
  assert_eq(fields["next_offset"], ToJson::to_json("32768"))
  let partial = { ..request, offset: 1L, }
  @fs.write_file(
    request_path,
    partial.to_json().stringify(),
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  let (refused_code, refused_stdout, refused_stderr) = @process.collect_output(
    executable,
    ["--export"],
    extra_env~,
    stdin=@process.redirect_from_file(request_path),
  )
  assert_true(refused_code != 0)
  assert_eq(refused_stdout.binary(), b"")
  assert_true(refused_stderr.binary().length() > 0)
  assert_false(
    @utf8.decode(refused_stderr.binary()).contains(config.retention_root),
  )
  let oversized = [
    for _ in 0..<(config.limits.max_protocol_bytes + 1) => "x"
  ].join("")
  for
    (arguments, payload, configured) in [
      (["--export", "--unsupported"], request.to_json().stringify(), true),
      (["--export"], request.to_json().stringify(), false),
      (["--export"], "{not-json", true),
      (["--export"], "{}", true),
      (["--export"], oversized, true),
    ] {
    @fs.write_file(
      request_path,
      payload,
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    let (exit_code, output, error) = @process.collect_output(
      executable,
      arguments,
      inherit_env=false,
      extra_env=if configured { extra_env } else { Map([]) },
      stdin=@process.redirect_from_file(request_path),
    )
    assert_true(exit_code != 0)
    assert_eq(output.binary(), b"")
    assert_true(error.binary().length() > 0)
    assert_false(@utf8.decode(error.binary()).contains(config.retention_root))
  }
  println(
    "CLI verified: exact 2 MiB stdout and destination file, JSON page; partial cursor, unsupported arguments, missing config, malformed, incomplete and oversized input all emit zero stdout and nonzero exit",
  )
}
