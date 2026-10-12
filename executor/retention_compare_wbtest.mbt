///|
async fn comparison_fixture(
  config : ExecutorConfig,
) -> (RetentionArtifactBinding, RetentionArtifactBinding) {
  let left = artifact_fixture(config)
  let right = {
    ..left,
    retention_id: "maple-revised",
    command_digest: "d".repeat(64),
  }
  let scratch = config.scratch_root + "/" + right.retention_id
  @fs.mkdir(scratch, permission=0o700)
  for dir in ["reports", "notes", "data"] {
    @fs.mkdir(scratch + "/" + dir, permission=0o700)
  }
  for (name, bytes) in artifact_sample_files() {
    if name == "data/measurement.bin" {
      continue
    }
    @fs.write_file(
      scratch + "/" + name,
      if name == "reports/checks.csv" {
        b"area,passed,follow_ups\ncore,24,0\nui,20,0\n"
      } else {
        bytes
      },
      create_mode=CreateNew,
      permission=0o600,
    )
  }
  @fs.write_file(
    scratch + "/reports/next-steps.md",
    "# Next steps\nReview updated check counts before promotion.\n",
    create_mode=CreateNew,
    permission=0o600,
  )
  let manifest = @sandbox.inventory_scratch(scratch, 32_000_000L).unwrap().entries.filter(entry => {
      entry.kind is RegularFile
    },
  )
  assert_true(
    retain_scratch(
      scratch,
      right.retention_id,
      right.workspace_id,
      "e".repeat(64),
      right.approval_digest,
      right.command_digest,
      manifest,
      config,
    ),
  )
  (left, right)
}

///|
async test "retention comparison explores iteration changes with paging and verified selected export" {
  let (config, roots) = test_executor_config()
  let (left, right) = comparison_fixture(config)
  let saved_left = @fs.read_file(
    config.retention_root + "/" + left.retention_id + ".json",
  ).binary()
  let saved_right = @fs.read_file(
    config.retention_root + "/" + right.retention_id + ".json",
  ).binary()
  let result = compare_retained_artifacts(left, right, config)
  assert_eq(
    (result.added, result.removed, result.changed, result.unchanged),
    (1, 1, 1, 4),
  )
  assert_eq(result.entries.map(row => (row.path, row.change)), [
    ("data/measurement.bin", "removed"),
    ("reports/checks.csv", "changed"),
    ("reports/next-steps.md", "added"),
  ])
  assert_false(result.has_more)
  let first = compare_retained_artifacts(left, right, config, limit=1)
  let rest = compare_retained_artifacts(
    left,
    right,
    config,
    after=first.next_after,
  )
  assert_eq(first.entries + rest.entries, result.entries)
  let report = compare_retained_artifacts(
    left,
    right,
    config,
    prefix="reports/",
    include_unchanged=true,
  )
  assert_eq(
    (report.added, report.removed, report.changed, report.unchanged),
    (1, 0, 1, 2),
  )
  let same = compare_retained_artifacts(left, left, config)
  assert_eq(same.entries, [])
  assert_eq(same.unchanged, 6)
  assert_eq(
    compare_retained_artifacts(left, right, config, prefix="absent/").matched,
    0,
  )
  assert_eq(
    export_retained_artifact(right, "reports/checks.csv", config),
    b"area,passed,follow_ups\ncore,24,0\nui,20,0\n",
  )
  assert_true(
    (try? compare_retained_artifacts(
      { ..left, command_digest: "f".repeat(64), },
      right,
      config,
    ))
    is Err(_),
  )
  assert_true(
    (try? compare_retained_artifacts(left, right, config, limit=0)) is Err(_),
  )
  assert_eq(
    @fs.read_file(config.retention_root + "/" + left.retention_id + ".json").binary(),
    saved_left,
  )
  assert_eq(
    @fs.read_file(config.retention_root + "/" + right.retention_id + ".json").binary(),
    saved_right,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  cleanup_test_roots(roots)
}

///|
async test "compiled retention comparison exports real iteration report" {
  guard @env.get_env_var("MOONFORT_COMPARISON_CLI") is Some(executable) else {
    fail("set MOONFORT_COMPARISON_CLI to compiled comparison executable")
  }
  let (config, roots) = test_executor_config()
  let (left, right) = comparison_fixture(config)
  let (config_path, _) = write_artifact_cli_inputs(config, left)
  let input : Json = {
    "baseline": left.to_json(),
    "candidate": right.to_json(),
  }
  let input_path = config.retention_root + "/compare-input.json"
  @fs.write_file(
    input_path,
    input.stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  for
    (label, args) in [
      ("comparison", []),
      ("comparison-json", ["--json"]),
      (
        "comparison-reports",
        ["--prefix", "reports/", "--include-unchanged", "--json"],
      ),
      ("comparison-first", ["--limit", "1", "--json"]),
    ] {
    let (code, output, errors) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(input_path),
    )
    assert_eq(code, 0)
    assert_eq(errors.binary(), b"")
    if label == "comparison" {
      assert_true(
        output.text().contains("Added 1; removed 1; changed 1; unchanged 4"),
      )
    } else {
      let decoded : RetentionComparison = @json.from_json(
        @json.parse(output.text()),
      )
      assert_eq(decoded.baseline, left)
      assert_eq(decoded.candidate, right)
    }
    if @env.get_env_var("MOONFORT_COMPARISON_EVIDENCE") is Some(root) {
      @fs.write_file(
        root + "/" + label + ".txt",
        output.binary(),
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      @fs.write_file(
        root + "/comparison-input.json",
        input.stringify(indent=2),
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      @fs.write_file(
        root + "/revised-checks.csv",
        export_retained_artifact(right, "reports/checks.csv", config),
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
    }
  }
  let (code, _, _) = @process.collect_output(
    executable,
    ["--limit", "0"],
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_eq(code, 1)
  cleanup_test_roots(roots)
}
