///|
async fn write_artifact_cli_inputs(
  config : ExecutorConfig,
  binding : RetentionArtifactBinding,
) -> (String, String) {
  let config_path = config.retention_root + "/fixture-config.json"
  let binding_path = config.retention_root + "/fixture-binding.json"
  let limits = config.limits
  let value : Json = {
    "approval_root": config.approval_root,
    "scratch_root": config.scratch_root,
    "retention_root": config.retention_root,
    "artifact_key_id": config.artifact_key_id,
    "artifact_signing_key": config.artifact_signing_key,
    "workspaces": {},
    "local_tools": {},
    "aen_backends": {},
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
    value.stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  @fs.write_file(
    binding_path,
    binding.to_json().stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  (config_path, binding_path)
}

///|
async test "compiled artifact browser lists filters previews exports and reopens exact files" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    println("CLI integration not enabled; set MOONFORT_ARTIFACT_READER_CLI")
    return
  }
  let (config, roots) = test_executor_config()
  let binding = artifact_fixture(config)
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let evidence = @env.get_env_var("MOONFORT_ARTIFACT_EVIDENCE")
  if evidence is Some(root) && !@fs.exists(root) {
    @fs.mkdir(root, permission=0o700)
  }
  let (list_code, list_bytes, list_errors) = @process.collect_output(
    executable,
    ["list", "--json"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(list_code, 0)
  assert_eq(list_errors.binary(), b"")
  let all : RetentionArtifactList = @json.from_json(
    @json.parse(list_bytes.text()),
  )
  assert_eq(all.total_files, 6)
  assert_eq(all.binding, binding)
  if evidence is Some(root) {
    @fs.write_file(
      root + "/all-files.json",
      list_bytes.binary(),
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
  }
  for
    (label, arguments) in [
      (
        "filtered",
        ["list", "--prefix", "reports/", "--contains", ".csv", "--json"],
      ),
      ("first-page", ["list", "--prefix", "reports/", "--limit", "2", "--json"]),
      (
        "next-page",
        [
          "list", "--prefix", "reports/", "--limit", "2", "--after", "reports/details.json",
          "--json",
        ],
      ),
      ("empty", ["list", "--contains", "missing", "--json"]),
    ] {
    let (code, output, _) = @process.collect_output(
      executable,
      arguments,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_eq(code, 0)
    let list : RetentionArtifactList = @json.from_json(
      @json.parse(output.text()),
    )
    match label {
      "filtered" => {
        assert_eq(list.matched_files, 1)
        assert_eq(list.files[0].relative_path, "reports/checks.csv")
      }
      "first-page" => {
        assert_eq(list.files.length(), 2)
        assert_true(list.has_more)
      }
      "next-page" => {
        assert_eq(list.files.length(), 1)
        assert_false(list.has_more)
      }
      "empty" => assert_eq(list.matched_files, 0)
      _ => fail("unexpected fixture")
    }
    if evidence is Some(root) {
      @fs.write_file(
        root + "/" + label + ".json",
        output.binary(),
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
    }
  }
  let (preview_code, preview, _) = @process.collect_output(
    executable,
    ["preview", "reports/launch-summary.md"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(preview_code, 0)
  assert_true(preview.text().contains("42 checks passed"))
  assert_true(preview.text().contains("[End of artifact]"))
  if evidence is Some(root) {
    @fs.write_file(
      root + "/preview.txt",
      preview.binary(),
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
  }
  let (page_code, page_output, _) = @process.collect_output(
    executable,
    [
      "preview", "notes/月-review.txt", "--bytes", "10", "--offset", "3", "--json",
    ],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(page_code, 0)
  let page : RetentionArtifactPage = @json.from_json(
    @json.parse(page_output.text()),
  )
  assert_eq(page.offset, 3L)
  assert_eq(page.next_offset, 13L)
  assert_eq(
    @base64.decode(page.content_base64),
    artifact_sample_files()[3].1[3:13].to_owned(),
  )
  if evidence is Some(root) {
    @fs.write_file(
      root + "/unicode-page.json",
      page_output.binary(),
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
  }
  for (name, expected) in artifact_sample_files() {
    let destination = config.retention_root + "/downloaded.bin"
    let code = @process.run(
      executable,
      ["export", name],
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
      stdout=@process.redirect_to_file(
        destination,
        create_mode=CreateOrTruncate,
        permission=0o600,
      ),
    )
    assert_eq(code, 0)
    let reopened = @fs.read_file(destination).binary()
    assert_eq(reopened, expected)
    if evidence is Some(root) {
      let filename = name.replace(old="/", new="-")
      @fs.write_file(
        root + "/export-" + filename,
        reopened,
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
    }
  }
  for
    arguments in [
      ["export", "not-in-receipt.txt"],
      ["export", "../outside"],
      ["preview", "reports/checks.csv", "--bytes", "0"],
    ] {
    let (code, stdout, stderr) = @process.collect_output(
      executable,
      arguments,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(code != 0)
    assert_eq(stdout.binary(), b"")
    assert_true(stderr.text().contains("Artifact browse refused"))
    assert_false(stderr.text().contains(config.retention_root))
  }
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  assert_true(@fs.exists(config.retention_root + "/maple-results.json"))
  if evidence is Some(root) {
    @fs.write_file(
      root + "/receipt-binding.json",
      binding.to_json().stringify(),
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    @fs.write_file(
      root + "/proof.txt",
      "Compiled CLI: list, prefix+substring filter, cursor pages, empty filter, human preview, Unicode byte page, six exact file exports reopened, three refusal cases; no consumed grant or workspace write.\n",
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
  }
  println(
    "Compiled artifact browser journey passed; six exported files reopened byte-for-byte",
  )
  cleanup_test_roots(roots)
}
