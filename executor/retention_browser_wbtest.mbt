///|
fn artifact_sample_files() -> Array[(String, Bytes)] {
  [
    (
      "reports/launch-summary.md",
      @utf8.encode(
        "# Launch readiness\n\nSynthetic result for the Maple release.\n- 42 checks passed\n- 2 documentation follow-ups\n- Review owner: Demo Operator\n\nGenerated output is ready for review, not yet accepted.\n",
      ),
    ),
    ("reports/checks.csv", b"area,passed,follow_ups\ncore,24,0\nui,18,2\n"),
    (
      "reports/details.json", b"{\"release\":\"Maple\",\"checks\":42,\"follow_ups\":[\"Update quickstart\",\"Add migration note\"]}\n",
    ),
    (
      "notes/月-review.txt",
      @utf8.encode(
        "Review 🌙: inspect reports/checks.csv, then share the summary.\n",
      ),
    ),
    ("data/measurement.bin", Bytes::from_array([0, 255, 10, 13, 27, 128, 42])),
    ("data/empty.txt", b""),
  ]
}

///|
async fn artifact_fixture(config : ExecutorConfig) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "maple-results",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/" + binding.retention_id
  @fs.mkdir(scratch, permission=0o700)
  for directory in ["reports", "notes", "data"] {
    @fs.mkdir(scratch + "/" + directory, permission=0o700)
  }
  for (name, bytes) in artifact_sample_files() {
    @fs.write_file(
      scratch + "/" + name,
      bytes,
      create_mode=CreateNew,
      permission=0o600,
    )
  }
  let inventory = @sandbox.inventory_scratch(scratch, 32_000_000L).unwrap()
  let manifest = inventory.entries.filter(entry => entry.kind is RegularFile)
  assert_true(
    retain_scratch(
      scratch,
      binding.retention_id,
      binding.workspace_id,
      "a".repeat(64),
      binding.approval_digest,
      binding.command_digest,
      manifest,
      config,
    ),
  )
  @fs.write_file(
    scratch + "/not-in-receipt.txt",
    "unselected scratch bytes",
    create_mode=CreateNew,
    permission=0o600,
  )
  binding
}

///|
async test "artifact browser explores a generated multi-file result without writes" {
  let (config, roots) = test_executor_config()
  let binding = artifact_fixture(config)
  assert_eq(decode_retention_artifact_binding(binding.to_json()), binding)
  let original = @fs.read_file(config.retention_root + "/maple-results.json").binary()
  let all = list_retained_artifacts(binding, config)
  assert_eq(all.total_files, 6)
  assert_eq(all.matched_files, 6)
  assert_eq(
    all.total_bytes,
    artifact_sample_files().fold(init=0L, (sum, item) => {
      sum + item.1.length().to_int64()
    }),
  )
  assert_eq(all.files.map(file => file.relative_path), [
    "data/empty.txt", "data/measurement.bin", "notes/月-review.txt", "reports/checks.csv",
    "reports/details.json", "reports/launch-summary.md",
  ])
  let first = list_retained_artifacts(
    binding,
    config,
    prefix="reports/",
    limit=2,
  )
  assert_eq(first.matched_files, 3)
  assert_eq(first.files.length(), 2)
  assert_true(first.has_more)
  assert_eq(first.next_after, "reports/details.json")
  assert_eq(
    first,
    list_retained_artifacts(binding, config, prefix="reports/", limit=2),
  )
  let last = list_retained_artifacts(
    binding,
    config,
    prefix="reports/",
    after=first.next_after,
    limit=2,
  )
  assert_eq(last.files.map(file => file.relative_path), [
    "reports/launch-summary.md",
  ])
  assert_false(last.has_more)
  assert_eq(last.matched_files, 3)
  let csv = list_retained_artifacts(
    binding,
    config,
    prefix="reports/",
    contains=".csv",
  )
  assert_eq(csv.files.map(file => file.relative_path), ["reports/checks.csv"])
  assert_eq(csv.matched_bytes, artifact_sample_files()[1].1.length().to_int64())
  assert_eq(
    list_retained_artifacts(binding, config, contains="no-matches").files,
    [],
  )
  for (name, bytes) in artifact_sample_files() {
    assert_eq(export_retained_artifact(binding, name, config), bytes)
  }
  assert_eq(
    @fs.read_file(config.retention_root + "/maple-results.json").binary(),
    original,
  )
  assert_eq(@fs.readdir(config.approval_root + "/pending"), [])
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  cleanup_test_roots(roots)
}

///|
async test "artifact byte previews resume unicode binary and empty files exactly" {
  let (config, roots) = test_executor_config()
  let binding = artifact_fixture(config)
  for (name, bytes) in artifact_sample_files() {
    let restored = @buffer.Buffer()
    for offset = 0L {
      let page = read_retained_artifact(
        binding,
        name,
        config,
        offset~,
        max_bytes=7,
      )
      assert_eq(
        page,
        read_retained_artifact(binding, name, config, offset~, max_bytes=7),
      )
      assert_true(
        @utf8.encode(page.to_json().stringify()).length() <=
        config.limits.max_protocol_bytes,
      )
      let chunk = @base64.decode(page.content_base64)
      restored.write_bytes(chunk)
      assert_eq(page.next_offset, offset + chunk.length().to_int64())
      if page.eof {
        break
      }
      assert_true(page.next_offset > offset)
      continue page.next_offset
    }
    assert_eq(restored.to_bytes(), bytes)
    let eof = read_retained_artifact(
      binding,
      name,
      config,
      offset=bytes.length().to_int64(),
    )
    assert_true(eof.eof)
    assert_eq(eof.content_base64, "")
  }
  cleanup_test_roots(roots)
}

///|
async test "artifact browser uses the retained selection and original receipt binding" {
  let (config, roots) = test_executor_config()
  let binding = artifact_fixture(config)
  for
    wrong in [
      { ..binding, workspace_id: "another", },
      { ..binding, approval_digest: "d".repeat(64), },
      { ..binding, command_digest: "d".repeat(64), },
    ] {
    assert_true((try? list_retained_artifacts(wrong, config)) is Err(_))
    assert_true(
      (try? export_retained_artifact(wrong, "reports/checks.csv", config))
      is Err(_),
    )
  }
  for name in ["not-in-receipt.txt", "../outside", "/etc/passwd"] {
    assert_true(
      (try? export_retained_artifact(binding, name, config)) is Err(_),
    )
  }
  let path = config.scratch_root + "/maple-results/reports/checks.csv"
  let original = @fs.read_file(path).binary()
  @fs.write_file(path, Bytes::make(original.length(), 65))
  assert_true(
    (try? export_retained_artifact(binding, "reports/checks.csv", config))
    is Err(_),
  )
  @fs.remove(path)
  @fs.symlink(
    path,
    target=config.scratch_root + "/maple-results/reports/details.json",
  )
  assert_true(
    (try? read_retained_artifact(binding, "reports/checks.csv", config))
    is Err(_),
  )
  let record_path = config.retention_root + "/maple-results.json"
  let record = load_retention_record(binding.retention_id, config)
  @fs.write_file(
    record_path,
    { ..record, expires_at_ms: 1L, }.to_json().stringify(),
  )
  assert_true((try? list_retained_artifacts(binding, config)) is Err(_))
  @fs.write_file(record_path, record.to_json().stringify())
  @fs.rename(record_path, config.retention_root + "/maple-results.promoting")
  assert_true((try? list_retained_artifacts(binding, config)) is Err(_))
  cleanup_test_roots(roots)
}

///|
async test "artifact browser bounds previews and large exports without hiding list metadata" {
  let (base, roots) = test_executor_config()
  let binding = artifact_fixture(base)
  let config = { ..base, limits: { ..base.limits, max_protocol_bytes: 4096, }, }
  assert_eq(list_retained_artifacts(binding, config).total_files, 6)
  assert_true(
    (try? list_retained_artifacts(binding, config, limit=0)) is Err(_),
  )
  assert_true(
    (try? read_retained_artifact(binding, "data/empty.txt", config, offset=1L))
    is Err(_),
  )
  let record = load_retention_record(binding.retention_id, config)
  let large : @sandbox.ScratchEntry = {
    relative_path: "data/large.bin",
    kind: RegularFile,
    size_bytes: 17_000_000L,
    fingerprint: "a".repeat(64),
  }
  @fs.write_file(
    config.retention_root + "/maple-results.json",
    { ..record, reviewable_files: [large], }.to_json().stringify(),
  )
  assert_eq(list_retained_artifacts(binding, config).files, [large])
  assert_true(
    (try? export_retained_artifact(binding, large.relative_path, config))
    is Err(_),
  )
  cleanup_test_roots(roots)
}
