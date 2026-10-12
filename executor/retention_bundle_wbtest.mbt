///|
test "ZIP CRC matches standard check vector" {
  assert_eq(bundle_crc32(b"123456789"), 0xcbf43926U)
  assert_eq(bundle_crc32(b""), 0U)
}

///|
async test "review ZIP round trips binary Unicode empty and selected artifacts" {
  let (config, roots) = test_executor_config()
  let binding = artifact_fixture(config)
  let paths = artifact_sample_files().map(item => item.0)
  let zip = export_retained_bundle(binding, paths, config)
  assert_eq(zip, export_retained_bundle(binding, paths.rev(), config))
  let archive = config.retention_root + "/review.zip"
  @fs.write_file(archive, zip, create_mode=CreateOrTruncate, permission=0o600)
  let (code, _, errors) = @process.collect_output("/usr/bin/unzip", [
    "-t", archive,
  ])
  assert_eq(code, 0)
  assert_eq(errors.binary(), b"")
  for (name, expected) in artifact_sample_files() {
    let (code, output, _) = @process.collect_output("/usr/bin/unzip", [
      "-p",
      archive,
      "artifacts/" + name,
    ])
    assert_eq(code, 0)
    assert_eq(output.binary(), expected)
  }
  let (code, manifest_bytes, _) = @process.collect_output("/usr/bin/unzip", [
    "-p", archive, "manifest.json",
  ])
  assert_eq(code, 0)
  let manifest : RetentionBundleManifest = @json.from_json(
    @json.parse(manifest_bytes.text()),
  )
  assert_eq(manifest.binding, binding)
  assert_eq(manifest.files.length(), 6)
  assert_eq(
    manifest.total_bytes,
    list_retained_artifacts(binding, config).total_bytes,
  )
  for
    paths in [
      [],
      ["reports/checks.csv", "reports/checks.csv"],
      ["../outside"],
      ["not-in-receipt.txt"],
    ] {
    assert_true((try? export_retained_bundle(binding, paths, config)) is Err(_))
  }
  assert_true(
    (try? export_retained_bundle(
      binding,
      Array::make(201, "data/empty.txt"),
      config,
    ))
    is Err(_),
  )
  let reduced = { ..config, limits: { ..config.limits, max_disk_mib: 0, }, }
  assert_true(
    (try? export_retained_bundle(binding, ["reports/checks.csv"], reduced))
    is Err(_),
  )
  let scratch = config.scratch_root + "/maple-results/reports/checks.csv"
  @fs.write_file(scratch, b"changed bytes")
  assert_true((try? export_retained_bundle(binding, paths, config)) is Err(_))
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  cleanup_test_roots(roots)
}

///|
async test "compiled bundle command exports a complete filtered review package" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    println("CLI integration not enabled; set MOONFORT_ARTIFACT_READER_CLI")
    return
  }
  let (base, roots) = test_executor_config()
  let config = {
    ..base,
    limits: {
      ..base.limits,
      max_protocol_bytes: 4096,
      max_model_output_bytes: 2048,
    },
  }
  let binding = artifact_fixture(config)
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let archive = config.retention_root + "/selected.zip"
  let code = @process.run(
    executable,
    ["bundle", "--prefix", "reports/"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
    stdout=@process.redirect_to_file(
      archive,
      create_mode=CreateOrTruncate,
      permission=0o600,
    ),
  )
  assert_eq(code, 0)
  let (code, listing, _) = @process.collect_output("/usr/bin/unzip", [
    "-Z1", archive,
  ])
  assert_eq(code, 0)
  assert_eq(
    listing.text(),
    "manifest.json\nartifacts/reports/checks.csv\nartifacts/reports/details.json\nartifacts/reports/launch-summary.md\n",
  )
  for
    (name, expected) in artifact_sample_files().filter(item => {
      item.0.has_prefix("reports/")
    }) {
    let (code, output, _) = @process.collect_output("/usr/bin/unzip", [
      "-p",
      archive,
      "artifacts/" + name,
    ])
    assert_eq(code, 0)
    assert_eq(output.binary(), expected)
  }
  if @env.get_env_var("MOONFORT_BUNDLE_EVIDENCE") is Some(root) {
    @fs.write_file(
      root + "/maple-review.zip",
      @fs.read_file(archive).binary(),
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    @fs.write_file(
      root + "/maple-complete.zip",
      export_retained_bundle(
        binding,
        artifact_sample_files().map(item => item.0),
        config,
      ),
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    @fs.write_file(
      root + "/receipt-binding.json",
      binding.to_json().stringify(),
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    @fs.write_file(
      root + "/archive-contents.txt",
      listing.text(),
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    for (name, bytes) in artifact_sample_files() {
      @fs.write_file(
        root + "/input-" + name.replace(old="/", new="-"),
        bytes,
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
    }
  }
  for
    args in [
      ["bundle", "--contains", "missing"],
      ["bundle", "--json"],
      ["bundle", "--limit", "1"],
    ] {
    let (code, out, _) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(code != 0)
    assert_eq(out.binary(), b"")
  }
  @fs.write_file(
    config.scratch_root + "/maple-results/reports/checks.csv",
    b"modified",
  )
  let (code, out, _) = @process.collect_output(
    executable,
    ["bundle", "--prefix", "reports/"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_true(code != 0)
  assert_eq(out.binary(), b"")
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  cleanup_test_roots(roots)
}

///|
async test "bundle CLI collects every bounded metadata page" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    println("CLI integration not enabled; set MOONFORT_ARTIFACT_READER_CLI")
    return
  }
  let (base, roots) = test_executor_config()
  let config = { ..base, limits: { ..base.limits, max_changed_paths: 100, }, }
  let binding = artifact_fixture(config)
  let record = load_retention_record(binding.retention_id, config)
  for index = 0; index < 60; index = index + 1 {
    @fs.write_file(
      record.scratch_path + "/reports/page-\{index}.txt",
      "Row \{index}\n",
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
  }
  let inventory = @sandbox.inventory_scratch(record.scratch_path, 32_000_000L).unwrap()
  let entries = inventory.entries.filter(entry => {
    entry.kind is RegularFile && entry.relative_path.has_prefix("reports/page-")
  })
  @fs.write_file(
    config.retention_root + "/maple-results.json",
    { ..record, reviewable_files: entries, }.to_json().stringify(),
  )
  assert_true(list_retained_artifacts(binding, config, limit=50).has_more)
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let archive = config.retention_root + "/pages.zip"
  let code = @process.run(
    executable,
    ["bundle", "--contains", "page-"],
    extra_env={ "MOONFORT_EXECUTOR_CONFIG": config_path },
    stdin=@process.redirect_from_file(binding_path),
    stdout=@process.redirect_to_file(
      archive,
      create_mode=CreateOrTruncate,
      permission=0o600,
    ),
  )
  assert_eq(code, 0)
  let (code, output, _) = @process.collect_output("/usr/bin/unzip", [
    "-p", archive, "manifest.json",
  ])
  assert_eq(code, 0)
  let manifest : RetentionBundleManifest = @json.from_json(
    @json.parse(output.text()),
  )
  assert_eq(manifest.files.length(), 60)
  for index = 0; index < 60; index = index + 1 {
    let (code, output, _) = @process.collect_output("/usr/bin/unzip", [
      "-p",
      archive,
      "artifacts/reports/page-\{index}.txt",
    ])
    assert_eq(code, 0)
    assert_eq(output.text(), "Row \{index}\n")
  }
  cleanup_test_roots(roots)
}
