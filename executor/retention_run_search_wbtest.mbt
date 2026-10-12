///|
async fn run_search_fixture(
  config : ExecutorConfig,
  files : Array[(String, Bytes)],
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "run-search",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/" + binding.retention_id
  @fs.mkdir(scratch, permission=0o700)
  @fs.mkdir(scratch + "/logs", permission=0o700)
  for (path, bytes) in files {
    @fs.write_file(
      scratch + "/" + path,
      bytes,
      create_mode=CreateNew,
      permission=0o600,
    )
  }
  let manifest = @sandbox.inventory_scratch(scratch, 32_000_000L).unwrap().entries.filter(file => {
      file.kind is RegularFile
    },
  )
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
  binding
}

///|
fn run_search_examples() -> Array[(String, Bytes)] {
  [
    (
      "logs/z-test.log",
      @utf8.encode(
        "INFO ready\nerror: 月🌙 fixture absent\nERROR repeated ERROR\n",
      ),
    ),
    (
      "logs/a-build.log", b"Start\r\nERROR: missing generated header\r\nerror: follow-up needed\r\n",
    ),
    ("logs/empty.txt", b""),
    ("logs/clean.log", b"All checks passed\n"),
    ("logs/raw.bin", b"error\xff"),
    ("logs/nul.bin", b"error\x00"),
    ("notes.txt", b"error outside logs\n"),
  ]
}

///|
async test "run search discovers matches across files and resumes within and across paths" {
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, run_search_examples())
  let saved = @fs.read_file(config.retention_root + "/run-search.json").binary()
  let first = search_retained_run(
    binding,
    "error",
    config,
    prefix="logs/",
    ignore_ascii_case=true,
    limit=1,
  )
  assert_eq(
    (
      first.selected_files,
      first.searched_files,
      first.matching_files,
      first.matching_lines,
    ),
    (6, 4, 2, 4),
  )
  assert_eq(first.matches.map(m => (m.file.relative_path, m.hit.line)), [
    ("logs/a-build.log", 2),
  ])
  assert_eq(first.matches[0].hit.excerpt, "ERROR: missing generated header")
  assert_eq(first.next_after_path, "logs/a-build.log")
  assert_eq(first.next_after_line, 2)
  assert_true(first.has_more)
  assert_eq(
    first.skipped_files.map(item => {
      (item.file.relative_path, item.reason, item.bytes_verified)
    }),
    [
      ("logs/nul.bin", "contains_nul", true),
      ("logs/raw.bin", "invalid_utf8", true),
    ],
  )
  let second = search_retained_run(
    binding,
    "error",
    config,
    prefix="logs/",
    ignore_ascii_case=true,
    after_path=first.next_after_path,
    after_line=first.next_after_line,
    limit=2,
  )
  assert_eq(second.matches.map(m => (m.file.relative_path, m.hit.line)), [
    ("logs/a-build.log", 3),
    ("logs/z-test.log", 2),
  ])
  assert_true(second.has_more)
  let last = search_retained_run(
    binding,
    "error",
    config,
    prefix="logs/",
    ignore_ascii_case=true,
    after_path=second.next_after_path,
    after_line=second.next_after_line,
    limit=2,
  )
  assert_eq(last.matches.map(m => (m.file.relative_path, m.hit.line)), [
    ("logs/z-test.log", 3),
  ])
  assert_false(last.has_more)
  assert_eq(last.matching_lines, 4)
  assert_eq(@json.from_json(first.to_json()), first)
  assert_eq(
    search_retained_run(
      binding,
      "error",
      config,
      prefix="logs/",
      ignore_ascii_case=true,
      limit=1,
    ),
    first,
  )
  assert_eq(
    search_retained_run(
      binding,
      "error",
      config,
      prefix="logs/",
      contains=".log",
    ).matching_lines,
    2,
  )
  assert_eq(
    search_retained_run(binding, "月🌙", config).matches[0].hit.line,
    2,
  )
  assert_eq(search_retained_run(binding, ".*", config).matching_lines, 0)
  let empty = search_retained_run(binding, "error", config, prefix="nothing/")
  assert_eq(
    (empty.selected_files, empty.matching_lines, empty.matches.length()),
    (0, 0, 0),
  )
  assert_false(empty.has_more)
  assert_eq(
    @fs.read_file(config.retention_root + "/run-search.json").binary(),
    saved,
  )
  for (name, bytes) in run_search_examples() {
    assert_eq(
      @fs.read_file(config.scratch_root + "/run-search/" + name).binary(),
      bytes,
    )
  }
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "run search bounded pages preserve all matches and Unicode excerpts" {
  let (base, _) = test_executor_config()
  let config = { ..base, limits: { ..base.limits, max_protocol_bytes: 4096, }, }
  let line = "🌙".repeat(100) + "error" + "\u{1}".repeat(100) + "\n"
  let binding = run_search_fixture(config, [
    ("a.txt", @utf8.encode(line.repeat(15))),
    ("b.txt", @utf8.encode(line.repeat(15))),
  ])
  let found : Array[(String, Int)] = []
  for path = "", row = 0 {
    let page = search_retained_run(
      binding,
      "error",
      config,
      after_path=path,
      after_line=row,
      limit=100,
    )
    assert_eq(page.matching_lines, 30)
    assert_true(@utf8.encode(page.to_json().stringify()).length() + 1 <= 4096)
    for m in page.matches {
      found.push((m.file.relative_path, m.hit.line))
      assert_eq(m.hit.excerpt, "🌙".repeat(20) + "error" + "\u{1}".repeat(80))
      assert_true(m.hit.omitted_before && m.hit.omitted_after)
    }
    if !page.has_more {
      break
    }
    assert_true((page.next_after_path, page.next_after_line) != (path, row))
    continue page.next_after_path, page.next_after_line
  }
  assert_eq(
    found,
    [
      for row in 1..<=15 => ("a.txt", row)
    ] +
    [
      for row in 1..<=15 => ("b.txt", row)
    ],
  )
}

///|
async test "run search records oversized omissions and rejects oversized corpora" {
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, [
    ("big.log", Bytes::make(1_048_577, 65)),
    ("small.log", b"error\n"),
  ])
  let page = search_retained_run(binding, "error", config)
  assert_eq(
    (page.selected_files, page.searched_files, page.matching_lines),
    (2, 1, 1),
  )
  assert_eq(page.skipped_files[0].reason, "over_1_mib")
  assert_false(page.skipped_files[0].bytes_verified)
  let (many_base, _) = test_executor_config()
  let many_config = {
    ..many_base,
    limits: { ..many_base.limits, max_changed_paths: 256, },
  }
  let many = run_search_fixture(
    many_config,
    [
      for n in 0..<129 => (n.to_string() + ".txt", b"")
    ],
  )
  guard (try? search_retained_run(many, "error", many_config))
    is Err(Failure(message)) else {
    fail("expected file count refusal")
  }
  assert_true(message.contains("more than 128 files"))
  assert_eq(
    search_retained_run(many, "error", many_config, prefix="128.").selected_files,
    1,
  )
  let (large_config, _) = test_executor_config()
  let large = run_search_fixture(
    large_config,
    [
      for n in 0..<9 => (n.to_string() + ".txt", Bytes::make(1_048_576, 65))
    ],
  )
  guard (try? search_retained_run(large, "error", large_config))
    is Err(Failure(message)) else {
    fail("expected corpus byte refusal")
  }
  assert_true(message.contains("more than 8 MiB"))
}

///|
async test "run search validates query cursors and only searches the selected manifest" {
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, [
    ("logs/one.txt", b"error\n"),
    ("skip.bin", b"\xff"),
  ])
  @fs.write_file(
    config.scratch_root + "/run-search/late.txt",
    "error",
    create_mode=CreateNew,
  )
  assert_eq(search_retained_run(binding, "error", config).selected_files, 2)
  for query in ["", "x".repeat(129), "a\nb", "a\rb", "\u{0}"] {
    assert_true((try? search_retained_run(binding, query, config)) is Err(_))
  }
  for
    (path, line) in [
      ("", 1),
      ("missing.txt", 0),
      ("logs/one.txt", 2),
      ("logs/one.txt", -1),
      ("skip.bin", 0),
    ] {
    assert_true(
      (try? search_retained_run(
        binding,
        "error",
        config,
        after_path=path,
        after_line=line,
      ))
      is Err(_),
    )
  }
  for limit in [0, 101] {
    assert_true(
      (try? search_retained_run(binding, "error", config, limit~)) is Err(_),
    )
  }
  assert_true(
    (try? search_retained_run(
      binding,
      "error",
      config,
      prefix="no-match",
      after_path="logs/one.txt",
    ))
    is Err(_),
  )
  assert_eq(
    search_retained_run(
      binding,
      "error",
      config,
      after_path="logs/one.txt",
      after_line=1,
    ).matches,
    [],
  )
  assert_eq(
    search_retained_run(
      binding,
      "error",
      config,
      after_path="logs/one.txt",
      after_line=0,
    ).matches.length(),
    1,
  )
}

///|
async test "run search refuses changed missing expired or mismatched evidence without hiding it as binary" {
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, [
    ("one.txt", b"error\n"),
    ("skip.bin", b"\xff"),
  ])
  assert_true(
    (try? search_retained_run(
      { ..binding, command_digest: "d".repeat(64), },
      "error",
      config,
    ))
    is Err(_),
  )
  @fs.write_file(config.scratch_root + "/run-search/skip.bin", b"\xfe")
  assert_true((try? search_retained_run(binding, "error", config)) is Err(_))
  // Explicitly narrowing to the unchanged text file remains useful.
  assert_eq(
    search_retained_run(binding, "error", config, contains=".txt").matching_lines,
    1,
  )
  @fs.write_file(config.scratch_root + "/run-search/skip.bin", b"\xff")
  @fs.write_file(config.scratch_root + "/run-search/one.txt", b"ERROR\n")
  assert_true((try? search_retained_run(binding, "error", config)) is Err(_))
  @fs.write_file(config.scratch_root + "/run-search/one.txt", b"error\n")
  let file_path = config.scratch_root + "/run-search/one.txt"
  @fs.rename(file_path, file_path + ".moved", replace=false)
  assert_true((try? search_retained_run(binding, "error", config)) is Err(_))
  @fs.rename(file_path + ".moved", file_path, replace=false)
  let record = load_retention_record(binding.retention_id, config)
  @fs.write_file(
    config.retention_root + "/run-search.json",
    { ..record, expires_at_ms: 1L, }.to_json().stringify(),
  )
  assert_true((try? search_retained_run(binding, "error", config)) is Err(_))
}

///|
async test "compiled run search locates unknown logs and reopens paged JSON with source identities" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI")
  }
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, run_search_examples())
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = [
    "search-all", "--query", "error", "--prefix", "logs/", "--ignore-case", "--limit",
    "2",
  ]
  let (code, output, errors) = @process.collect_output(
    executable,
    args + ["--json"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  assert_eq(errors.binary(), b"")
  let first : RetentionRunSearch = @json.from_json(@json.parse(output.text()))
  assert_eq(first.binding, binding)
  assert_eq(first.matching_lines, 4)
  assert_eq(first.matches.map(m => m.file.relative_path), [
    "logs/a-build.log", "logs/a-build.log",
  ])
  let (next_code, next_output, next_errors) = @process.collect_output(
    executable,
    args +
    [
      "--after-path",
      first.next_after_path,
      "--after-line",
      first.next_after_line.to_string(),
      "--json",
    ],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(next_code, 0)
  assert_eq(next_errors.binary(), b"")
  let last : RetentionRunSearch = @json.from_json(
    @json.parse(next_output.text()),
  )
  assert_eq(last.matches.map(m => m.hit.line), [2, 3])
  assert_false(last.has_more)
  let (text_code, text_output, text_errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(text_code, 0)
  assert_eq(text_errors.binary(), b"")
  assert_true(
    text_output.text().contains("4 matching lines in 2 files; searched 4/6"),
  )
  assert_true(text_output.text().contains("\"logs/a-build.log\":2: ERROR"))
  assert_true(text_output.text().contains("invalid_utf8"))
  assert_true(
    text_output
    .text()
    .contains("Next path (JSON string): \"logs/a-build.log\"; line: 3"),
  )
  for
    bad in [
      ["search-all"],
      ["search-all", "--query", "error", "--limit", "0"],
      args + ["--ignore-case"],
      args + ["--prefix", "logs/"],
      args + ["--csv"],
      args + ["--after-path", "missing.log"],
      args + ["--after-line", "1"],
    ] {
    let (status, empty, diagnostic) = @process.collect_output(
      executable,
      bad,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(status != 0)
    assert_eq(empty.binary(), b"")
    assert_true(diagnostic.text().contains("Artifact browse refused"))
  }
  if @env.get_env_var("MOONFORT_RUN_SEARCH_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("first-page.json", output.binary()),
        ("last-page.json", next_output.binary()),
        ("search.txt", text_output.binary()),
        ("binding.json", @utf8.encode(binding.to_json().stringify() + "\n")),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
    for (name, bytes) in run_search_examples() {
      @fs.write_file(
        root + "/" + name.replace_all(old="/", new="-"),
        bytes,
        create_mode=CreateOrTruncate,
      )
    }
  }
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "run search does not silently drop omission metadata to fit a page" {
  let (base, _) = test_executor_config()
  let files = [
    for n in 0..<20 => (n.to_string() + ".bin", b"\xff")
  ]
  let binding = run_search_fixture(base, files)
  let small = { ..base, limits: { ..base.limits, max_protocol_bytes: 4096, }, }
  guard (try? search_retained_run(binding, "error", small))
    is Err(Failure(message)) else {
    fail("expected omission metadata refusal")
  }
  assert_true(message.contains("metadata exceeds response budget"))
  let narrowed = search_retained_run(binding, "error", small, prefix="0.")
  assert_eq(
    (narrowed.selected_files, narrowed.searched_files, narrowed.matching_lines),
    (1, 0, 0),
  )
  assert_eq(narrowed.skipped_files.length(), 1)
  assert_eq(narrowed.matches, [])
  assert_false(narrowed.has_more)
}
