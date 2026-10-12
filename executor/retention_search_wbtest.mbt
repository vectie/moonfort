///|
async fn search_fixture(
  config : ExecutorConfig,
  bytes : Bytes,
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "search-results",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/search-results"
  @fs.mkdir(scratch, permission=0o700)
  @fs.write_file(
    scratch + "/build.log",
    bytes,
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
async test "retained search finds literal Unicode and resumes matching lines" {
  let (config, _roots) = test_executor_config()
  let bytes = @utf8.encode(
    "Starting\r\nERROR: missing fixture\r\nerror: stale snapshot\n月🌙 ready\nERROR repeated ERROR\nDone",
  )
  let binding = search_fixture(config, bytes)
  let record_path = config.retention_root + "/search-results.json"
  let original = @fs.read_file(record_path).binary()
  let first = search_retained_artifact(
    binding,
    "build.log",
    "error",
    config,
    ignore_ascii_case=true,
    limit=1,
  )
  assert_eq(first.total_lines, 6)
  assert_eq(first.matching_lines, 3)
  assert_eq(first.matches[0].line, 2)
  assert_eq(first.matches[0].excerpt, "ERROR: missing fixture")
  assert_true(first.has_more)
  let rest = search_retained_artifact(
    binding,
    "build.log",
    "error",
    config,
    ignore_ascii_case=true,
    after_line=first.next_after_line,
  )
  assert_eq(rest.matches.map(hit => hit.line), [3, 5])
  assert_false(rest.has_more)
  assert_eq(
    search_retained_artifact(binding, "build.log", "error", config).matching_lines,
    1,
  )
  assert_eq(
    search_retained_artifact(binding, "build.log", "月🌙", config).matches[0].line,
    4,
  )
  assert_eq(
    search_retained_artifact(binding, "build.log", ".*", config).matching_lines,
    0,
  )
  assert_eq(
    search_retained_artifact(
      binding,
      "build.log",
      "ERROR",
      config,
      after_line=6,
    ).matches,
    [],
  )
  assert_eq(@fs.read_file(record_path).binary(), original)
  assert_eq(
    @fs.read_file(config.scratch_root + "/search-results/build.log").binary(),
    bytes,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "retained search handles empty files final newlines and long Unicode excerpts" {
  for (text, count) in [("", 0), ("\n", 1), ("a\n", 1), ("a\n\n", 2), ("a", 1)] {
    let (config, _roots) = test_executor_config()
    let binding = search_fixture(config, @utf8.encode(text))
    assert_eq(
      search_retained_artifact(binding, "build.log", "a", config).total_lines,
      count,
    )
  }
  let (config, _roots) = test_executor_config()
  let line = "🌙".repeat(100) + "MATCH" + "🌙".repeat(100)
  let binding = search_fixture(config, @utf8.encode(line))
  let result = search_retained_artifact(binding, "build.log", "MATCH", config)
  let hit = result.matches[0]
  assert_true(hit.omitted_before && hit.omitted_after)
  assert_eq(hit.excerpt, "🌙".repeat(20) + "MATCH" + "🌙".repeat(40))
  assert_eq(@utf8.decode(@utf8.encode(hit.excerpt)), hit.excerpt)
}

///|
async test "retained search fits protocol pages without losing results" {
  let (base, _roots) = test_executor_config()
  let config = { ..base, limits: { ..base.limits, max_protocol_bytes: 4096, }, }
  let text = ("\u{1}".repeat(40) + "error" + "\u{1}".repeat(80) + "\n").repeat(
    30,
  )
  let binding = search_fixture(config, @utf8.encode(text))
  let found : Array[Int] = []
  for after_line = 0 {
    let page = search_retained_artifact(
      binding,
      "build.log",
      "error",
      config,
      after_line~,
      limit=100,
    )
    assert_eq(page.matching_lines, 30)
    assert_true(@utf8.encode(page.to_json().stringify()).length() <= 4096)
    for hit in page.matches {
      found.push(hit.line)
    }
    if !page.has_more {
      break
    }
    assert_true(page.next_after_line > after_line)
    continue page.next_after_line
  }
  assert_eq(found.length(), 30)
  for index, line in found {
    assert_eq(line, index + 1)
  }
}

///|
async test "retained search refuses invalid selections binary stale bytes and expired records" {
  let (config, _roots) = test_executor_config()
  let binding = search_fixture(config, b"error\n")
  for query in ["", "x".repeat(129), "a\nb", "a\rb", "\u{0}"] {
    assert_true(
      (try? search_retained_artifact(binding, "build.log", query, config))
      is Err(_),
    )
  }
  assert_true(
    (try? search_retained_artifact(
      binding,
      "build.log",
      "error",
      config,
      after_line=-1,
    ))
    is Err(_),
  )
  assert_true(
    (try? search_retained_artifact(
      binding,
      "build.log",
      "error",
      config,
      after_line=2,
    ))
    is Err(_),
  )
  for limit in [0, 101] {
    assert_true(
      (try? search_retained_artifact(
        binding,
        "build.log",
        "error",
        config,
        limit~,
      ))
      is Err(_),
    )
  }
  assert_true(
    (try? search_retained_artifact(
      { ..binding, command_digest: "d".repeat(64), },
      "build.log",
      "error",
      config,
    ))
    is Err(_),
  )
  for path in ["../outside", "missing.txt"] {
    assert_true(
      (try? search_retained_artifact(binding, path, "error", config)) is Err(_),
    )
  }
  @fs.write_file(config.scratch_root + "/search-results/build.log", b"ERROR\n")
  assert_true(
    (try? search_retained_artifact(binding, "build.log", "error", config))
    is Err(_),
  )
  @fs.write_file(config.scratch_root + "/search-results/build.log", b"error\n")
  let record = load_retention_record(binding.retention_id, config)
  @fs.write_file(
    config.retention_root + "/search-results.json",
    { ..record, expires_at_ms: 1L, }.to_json().stringify(),
  )
  assert_true(
    (try? search_retained_artifact(binding, "build.log", "error", config))
    is Err(_),
  )
  for bytes in [b"error\x00", b"error\xff", Bytes::make(1_048_577, 65)] {
    let (other, _roots) = test_executor_config()
    let selected = search_fixture(other, bytes)
    assert_true(
      (try? search_retained_artifact(selected, "build.log", "error", other))
      is Err(_),
    )
  }
}

///|
async test "compiled retained search locates diagnostic lines and exports usable JSON" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    println("CLI integration not enabled; set MOONFORT_ARTIFACT_READER_CLI")
    return
  }
  let (config, _roots) = test_executor_config()
  let text = "Build: Maple release\nINFO: 42 checks started\nERROR: quickstart fixture missing\nINFO: retrying documentation check\nerror: migration note absent\nReview 🌙: do not promote until documentation is checked\n"
  let binding = search_fixture(config, @utf8.encode(text))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  for
    (label, args) in [
      (
        "search-first.txt",
        [
          "search", "build.log", "--query", "error", "--ignore-case", "--limit",
          "1",
        ],
      ),
      (
        "search-rest.json",
        [
          "search", "build.log", "--query", "error", "--ignore-case", "--after-line",
          "3", "--json",
        ],
      ),
      (
        "search-unicode.json",
        ["search", "build.log", "--query", "🌙", "--json"],
      ),
    ] {
    let (code, out, errors) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_eq(code, 0)
    assert_eq(errors.binary(), b"")
    if label == "search-first.txt" {
      assert_true(out.text().contains("3: ERROR: quickstart fixture missing"))
      assert_true(out.text().contains("[More: --after-line 3"))
    } else {
      let page : RetentionTextSearch = @json.from_json(@json.parse(out.text()))
      assert_eq(page.binding, binding)
      assert_eq(
        page.matches[0].line,
        if label == "search-rest.json" {
          5
        } else {
          6
        },
      )
    }
    if @env.get_env_var("MOONFORT_SEARCH_EVIDENCE") is Some(root) {
      @fs.write_file(
        root + "/" + label,
        out.binary(),
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      @fs.write_file(
        root + "/build.log",
        text,
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      @fs.write_file(
        root + "/receipt-binding.json",
        binding.to_json().stringify(),
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
    }
  }
  for
    args in [
      ["search", "build.log"],
      ["search", "build.log", "--query", "error", "--limit", "0"],
      [
        "search", "build.log", "--query", "error", "--ignore-case", "--ignore-case",
      ],
    ] {
    let (code, out, errors) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(code != 0)
    assert_eq(out.binary(), b"")
    assert_true(errors.text().contains("Artifact browse refused"))
  }
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}
