///|
async test "unified patches round trip varied text with a standard patch reader" {
  let root = @fs.realpath(@fs.tmpdir(prefix="moonfort-diff-roundtrip-"))
  let name = "report 月 space.txt"
  let file = root + "/" + name
  let patch_file = root + "/review.diff"
  let cases = [
    ("", "first\n"),
    ("last\n", ""),
    ("one\ntwo\n", "one\ninsert\ntwo\n"),
    ("one\ntwo\n", "one\ntwo\nappend\n"),
    ("one\ntwo\n", "two\n"),
    ("same\n", "same"),
    ("same", "same\n"),
    ("old\r\nkeep\r\n", "new\r\nkeep\r\n"),
    ("月\n🌙", "月\n星🌙"),
    ("x\nx\na\nx\nx\n", "x\nb\nx\nx\n"),
    ("a\n1\n2\n3\n4\n5\nz\n", "b\n1\n2\n3\n4\n5\ny\n"),
  ]
  for context in [0, 1, 3, 20] {
    for (before, after) in cases {
      @fs.write_file(
        file,
        before,
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      let diff = @text_diff.unified(
        before,
        after,
        "a/" + name,
        "b/" + name,
        context~,
      )
      @fs.write_file(
        patch_file,
        diff.patch,
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      let (code, _, _) = @process.collect_output("/usr/bin/patch", [
        "--batch", "--binary", "--directory", root, "-p1", "--input", patch_file,
      ])
      assert_eq(code, 0)
      assert_eq(@fs.read_file(file).binary(), @utf8.encode(after))
    }
  }
  cleanup_test_roots([root])
}

///|
async test "retained text diff verifies changed added removed and identical artifacts" {
  let (config, roots) = test_executor_config()
  let (left, right) = comparison_fixture(config)
  let result = diff_retained_artifact(left, right, "reports/checks.csv", config)
  assert_eq((result.added_lines, result.removed_lines), (1, 1))
  assert_eq(
    result.before.unwrap(),
    list_retained_artifacts(left, config, prefix="reports/checks.csv").files[0],
  )
  assert_true(result.patch.contains("-ui,18,2\n+ui,20,0\n"))
  let added = diff_retained_artifact(
    left, right, "reports/next-steps.md", config,
  )
  assert_eq(added.before, None)
  assert_eq((added.added_lines, added.removed_lines), (2, 0))
  assert_true(added.patch.has_prefix("--- /dev/null\t\n"))
  let removed = diff_retained_artifact(
    right, left, "reports/next-steps.md", config,
  )
  assert_eq(removed.after, None)
  assert_eq((removed.added_lines, removed.removed_lines), (0, 2))
  for path in ["data/empty.txt", "notes/月-review.txt", "reports/details.json"] {
    assert_eq(diff_retained_artifact(left, right, path, config).patch, "")
  }
  for
    path in [
      "data/measurement.bin", "missing.txt", "../outside", "not-in-receipt.txt",
    ] {
    assert_true(
      (try? diff_retained_artifact(left, right, path, config)) is Err(_),
    )
  }
  assert_true(
    (try? diff_retained_artifact(
      { ..left, approval_digest: "f".repeat(64), },
      right,
      "reports/checks.csv",
      config,
    ))
    is Err(_),
  )
  let before_record = @fs.read_file(
    config.retention_root + "/maple-results.json",
  ).binary()
  let after_record = @fs.read_file(
    config.retention_root + "/maple-revised.json",
  ).binary()
  @fs.write_file(
    config.scratch_root + "/maple-results/reports/checks.csv",
    "changed\n",
  )
  assert_true(
    (try? diff_retained_artifact(left, right, "reports/checks.csv", config))
    is Err(_),
  )
  assert_eq(
    @fs.read_file(config.retention_root + "/maple-results.json").binary(),
    before_record,
  )
  assert_eq(
    @fs.read_file(config.retention_root + "/maple-revised.json").binary(),
    after_record,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  cleanup_test_roots(roots)
}

///|
async test "compiled text diff exports a patch that reproduces candidate bytes" {
  guard @env.get_env_var("MOONFORT_TEXT_DIFF_CLI") is Some(executable) else {
    fail("set MOONFORT_TEXT_DIFF_CLI to the compiled diff-retention executable")
  }
  let (config, roots) = test_executor_config()
  let (left, right) = comparison_fixture(config)
  let (config_path, _) = write_artifact_cli_inputs(config, left)
  let input : Json = {
    "baseline": left.to_json(),
    "candidate": right.to_json(),
  }
  let input_path = config.retention_root + "/text-diff-input.json"
  @fs.write_file(
    input_path,
    input.stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let (code, output, errors) = @process.collect_output(
    executable,
    ["reports/checks.csv"],
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_eq(code, 0)
  assert_eq(errors.binary(), b"")
  let patch = config.retention_root + "/checks.diff"
  @fs.write_file(
    patch,
    output.binary(),
    create_mode=CreateNew,
    permission=0o600,
  )
  let original = export_retained_artifact(left, "reports/checks.csv", config)
  let candidate = export_retained_artifact(right, "reports/checks.csv", config)
  let reconstructed = config.retention_root + "/reconstructed.csv"
  @fs.write_file(
    reconstructed,
    original,
    create_mode=CreateNew,
    permission=0o600,
  )
  let (patch_code, _, _) = @process.collect_output("/usr/bin/patch", [
    "--batch", "--binary", reconstructed, patch,
  ])
  assert_eq(patch_code, 0)
  assert_eq(@fs.read_file(reconstructed).binary(), candidate)
  let (code, json, _) = @process.collect_output(
    executable,
    ["reports/checks.csv", "--context", "0", "--json"],
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_eq(code, 0)
  let decoded : RetentionTextDiff = @json.from_json(@json.parse(json.text()))
  assert_eq(decoded.baseline, left)
  assert_eq(decoded.candidate, right)
  assert_eq((decoded.added_lines, decoded.removed_lines), (1, 1))
  assert_true(decoded.patch.contains("@@ -3 +3 @@"))
  let (same_code, same, _) = @process.collect_output(
    executable,
    ["reports/details.json"],
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_eq(same_code, 0)
  assert_eq(same.binary(), b"")
  if @env.get_env_var("MOONFORT_TEXT_DIFF_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("comparison-input.json", @utf8.encode(input.stringify(indent=2))),
        ("baseline-checks.csv", original),
        ("candidate-checks.csv", candidate),
        ("checks.diff", output.binary()),
        ("checks-diff.json", json.binary()),
        ("reconstructed-checks.csv", @fs.read_file(reconstructed).binary()),
      ] {
      @fs.write_file(
        root + "/" + name,
        bytes,
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
    }
  }
  for
    args in [
      ["missing.txt"],
      ["data/measurement.bin"],
      ["reports/checks.csv", "--context", "21"],
      ["reports/checks.csv", "--json", "--json"],
    ] {
    let (code, stdout, _) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(input_path),
    )
    assert_eq(code, 1)
    assert_eq(stdout.binary(), b"")
  }
  @fs.write_file(
    config.scratch_root + "/maple-revised/reports/checks.csv",
    "changed\n",
  )
  let (code, stdout, _) = @process.collect_output(
    executable,
    ["reports/checks.csv"],
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_eq(code, 1)
  assert_eq(stdout.binary(), b"")
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  cleanup_test_roots(roots)
}
