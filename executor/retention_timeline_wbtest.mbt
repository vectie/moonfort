///|
fn timeline_mapping(
  files : Array[String],
  columns? : Array[RetentionJsonColumn] = [
    { header: "Event", pointer: "/event", },
  ],
  timestamp? : String = "/at",
) -> Bytes {
  @utf8.encode(
    (
      {
        "version": 1,
        "files": files.to_json(),
        "timestamp": timestamp.to_json(),
        "columns": columns.to_json(),
      } : Json).stringify(),
  )
}

///|
test "timeline accepts canonical Gregorian UTC milliseconds and rejects ambiguous timestamps" {
  for
    timestamp in [
      "0001-01-01T00:00:00.000Z", "9999-12-31T23:59:59.999Z", "2000-02-29T12:34:56.789Z",
      "2024-02-29T00:00:00.000Z", "1900-02-28T00:00:00.000Z",
    ] {
    retained_timeline_timestamp(timestamp)
  }
  for
    timestamp in [
      "", "2026-10-10", "2026-10-10T00:00:00Z", "2026-10-10T00:00:00.00Z", "2026-10-10T00:00:00.0000Z",
      "2026-10-10T00:00:00.000+00:00", "2026-10-10t00:00:00.000Z", "2026-10-10T00:00:00.000z",
      "0000-01-01T00:00:00.000Z", "1900-02-29T00:00:00.000Z", "2026-02-29T00:00:00.000Z",
      "2026-04-31T00:00:00.000Z", "2026-00-10T00:00:00.000Z", "2026-13-10T00:00:00.000Z",
      "2026-01-00T00:00:00.000Z", "2026-01-32T00:00:00.000Z", "2026-01-01T24:00:00.000Z",
      "2026-01-01T00:60:00.000Z", "2026-01-01T00:00:60.000Z", "2026-01-01T00:00:00.a00Z",
      "２０２６-01-01T00:00:00.000Z",
    ] {
    assert_true((try? retained_timeline_timestamp(timestamp)) is Err(_))
  }
}

///|
test "timeline mapping requires exact unique files pointers and reserved column boundaries" {
  let (paths, timestamp, columns) = retained_timeline_mapping(
    timeline_mapping(["logs/z.jsonl", "logs/a.jsonl"]),
  )
  assert_eq(paths, ["logs/a.jsonl", "logs/z.jsonl"])
  assert_eq(timestamp, "/at")
  assert_eq(columns.length(), 1)
  let wide = Array::makei(61, i => { header: i.to_string(), pointer: "/event", })
  assert_eq(
    retained_timeline_mapping(timeline_mapping(["x"], columns=wide)).2.length(),
    61,
  )
  for
    mapping in [
      b"{}",
      b"{\"version\":1,\"version\":1,\"files\":[],\"timestamp\":\"\",\"columns\":[]}",
      timeline_mapping([]),
      timeline_mapping(["x", "x"]),
      timeline_mapping([""]),
      timeline_mapping(["x\u{0}y"]),
      timeline_mapping(["x".repeat(4097)]),
      timeline_mapping(Array::makei(33, i => i.to_string())),
      timeline_mapping(["x"], timestamp="/~2"),
      timeline_mapping(["x"], columns=[]),
      timeline_mapping(
        ["x"],
        columns=wide + [{ header: "too many", pointer: "/event", }],
      ),
      Bytes::make(65_537, 32),
    ] {
    assert_true((try? retained_timeline_mapping(mapping)) is Err(_))
  }
  for header in ["__timestamp", "__source_path", "__source_line"] {
    assert_true(
      (try? retained_timeline_mapping(
        timeline_mapping(["x"], columns=[{ header, pointer: "/event", }]),
      ))
      is Err(_),
    )
  }
}

///|
fn timeline_sources() -> Array[(String, Bytes)] {
  [
    (
      "logs/alpha.jsonl",
      @utf8.encode(
        "{\"at\":\"2026-10-10T09:00:00.300Z\",\"event\":\"ready\",\"reading\":1.2300e+4,\"note\":\"late, arrival\"}\r\n \t\r\n{\"at\":\"2026-10-10T09:00:00.100Z\",\"event\":\"start\",\"reading\":-0,\"note\":\"=A1\"}\n{\"at\":\"2026-10-10T09:00:00.200Z\",\"event\":\"retry\",\"reading\":9007199254740993,\"note\":\"月🌙 \\\"check\\\"\\nnext\"}",
      ),
    ),
    (
      "logs/beta.jsonl",
      @utf8.encode(
        "{\"at\":\"2026-10-10T09:00:00.200Z\",\"event\":\"retry\",\"reading\":true,\"note\":null}\n{\"at\":\"2026-10-10T09:00:00.200Z\",\"event\":\"handoff\"}\n{\"at\":\"2026-10-10T09:00:00.500Z\",\"event\":\"finish\",\"reading\":1e400,\"note\":\"done\"}\n",
      ),
    ),
    ("logs/empty.jsonl", b""),
    ("notes.txt", b"not selected and not JSON"),
  ]
}

///|
fn timeline_example_mapping() -> Bytes {
  timeline_mapping(
    ["logs/beta.jsonl", "logs/empty.jsonl", "logs/alpha.jsonl"],
    columns=[
      { header: "Event", pointer: "/event", },
      { header: "Reading", pointer: "/reading", },
      { header: "Note", pointer: "/note", },
    ],
  )
}

///|
async test "timeline merges unsorted interleaved logs preserves ties exact cells and fingerprints" {
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, timeline_sources())
  let receipt_path = config.retention_root + "/run-search.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let mapping = timeline_example_mapping()
  let result = merge_retained_timeline(
    binding,
    config,
    mapping,
    skip_blank_lines=true,
  )
  let rows = parse_retained_csv(result.csv)
  assert_eq(rows[0], [
    "__source_path", "__source_line", "__timestamp", "Event", "Reading", "Note",
  ])
  assert_eq(rows[1:].to_array().map(row => (row[0], row[1], row[3])), [
    ("logs/alpha.jsonl", "3", "start"),
    ("logs/alpha.jsonl", "4", "retry"),
    ("logs/beta.jsonl", "1", "retry"),
    ("logs/beta.jsonl", "2", "handoff"),
    ("logs/alpha.jsonl", "1", "ready"),
    ("logs/beta.jsonl", "3", "finish"),
  ])
  assert_eq(rows[1][4], "-0")
  assert_eq(rows[2][4], "9007199254740993")
  assert_eq(rows[2][5], "月🌙 \"check\"\nnext")
  assert_eq(rows[3][4], "true")
  assert_eq(rows[5][4], "1.2300e+4")
  assert_eq(rows[6][4], "1e400")
  assert_eq(
    (
      result.row_count,
      result.total_lines,
      result.blank_lines_skipped,
      result.missing_cells,
      result.null_cells,
    ),
    (6, 7, 1, 2, 1),
  )
  assert_eq(result.first_timestamp, "2026-10-10T09:00:00.100Z")
  assert_eq(result.last_timestamp, "2026-10-10T09:00:00.500Z")
  assert_eq(result.sources.map(source => source.file.relative_path), [
    "logs/alpha.jsonl", "logs/beta.jsonl", "logs/empty.jsonl",
  ])
  assert_eq(result.sources[2].row_count, 0)
  assert_eq(
    result.mapping_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(mapping)),
  )
  assert_eq(
    result.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(result.csv))),
  )
  assert_eq(result.candidate_size_bytes, @utf8.encode(result.csv).length())
  assert_eq(
    merge_retained_timeline(binding, config, mapping, skip_blank_lines=true).context(),
    result.context(),
  )
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  for (path, bytes) in timeline_sources() {
    assert_eq(
      @fs.read_file(config.scratch_root + "/run-search/" + path).binary(),
      bytes,
    )
  }
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  let empty = merge_retained_timeline(
    binding,
    config,
    timeline_mapping(["logs/empty.jsonl"]),
  )
  assert_eq(
    (empty.row_count, empty.first_timestamp, empty.last_timestamp),
    (0, "", ""),
  )
  assert_eq(parse_retained_csv(empty.csv).length(), 1)
  assert_true(
    (try? merge_retained_timeline(binding, config, mapping)) is Err(_),
  )
  assert_true(
    (try? merge_retained_timeline(
      { ..binding, command_digest: "d".repeat(64), },
      config,
      mapping,
      skip_blank_lines=true,
    ))
    is Err(_),
  )
  assert_true(
    (try? merge_retained_timeline(
      binding,
      config,
      timeline_mapping(["absent.jsonl"]),
    ))
    is Err(_),
  )
  @fs.write_file(
    config.scratch_root + "/run-search/logs/beta.jsonl",
    b"changed",
  )
  assert_true(
    (try? merge_retained_timeline(
      binding,
      config,
      mapping,
      skip_blank_lines=true,
    ))
    is Err(_),
  )
  @fs.write_file(
    config.scratch_root + "/run-search/logs/beta.jsonl",
    timeline_sources()[1].1,
  )
  let record = load_retention_record(binding.retention_id, config)
  @fs.write_file(
    receipt_path,
    { ..record, expires_at_ms: 1L, }.to_json().stringify(),
  )
  assert_true(
    (try? merge_retained_timeline(
      binding,
      config,
      mapping,
      skip_blank_lines=true,
    ))
    is Err(_),
  )
}

///|
async test "timeline rejects malformed later sources and missing null numeric or invalid time" {
  for
    invalid in [
      b"{}", b"{\"at\":null}", b"{\"at\":123}", b"{\"at\":\"2026-02-29T00:00:00.000Z\"}",
      b"{\"at\":\"2026-10-10T00:00:00.000Z\",\"at\":\"2026-10-10T00:00:00.000Z\"}",
      b"{", b"\xff", b"\xef\xbb\xbf{}", b"{\"at\":\"2026-10-10T00:00:00.000Z\",\"event\":[]}",
    ] {
    let (config, _) = test_executor_config()
    let binding = run_search_fixture(config, [
      (
        "logs/a.jsonl", b"{\"at\":\"2026-10-10T00:00:00.000Z\",\"event\":\"ok\"}\n",
      ),
      ("logs/z.jsonl", invalid),
    ])
    assert_true(
      (try? merge_retained_timeline(
        binding,
        config,
        timeline_mapping(["logs/a.jsonl", "logs/z.jsonl"]),
      ))
      is Err(_),
    )
  }
}

///|
async test "timeline enforces whole selection value line byte candidate and context budgets" {
  let event = "{\"at\":\"2026-10-10T00:00:00.000Z\",\"event\":\"ok\"}\n"
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, [
    ("logs/a.jsonl", @utf8.encode(event.repeat(3333))),
    ("logs/b.jsonl", @utf8.encode(event.repeat(3334))),
    ("logs/blanks-a.jsonl", @utf8.encode("\n".repeat(10000))),
    ("logs/blanks-b.jsonl", @utf8.encode("\n".repeat(10001))),
    ("logs/large.jsonl", Bytes::make(1_048_577, 32)),
    (
      "logs/repeat.jsonl",
      @utf8.encode(
        ("{\"at\":\"2026-10-10T00:00:00.000Z\",\"event\":\"" +
        "x".repeat(1000) +
        "\"}\n").repeat(20),
      ),
    ),
  ])
  assert_true(
    (try? merge_retained_timeline(
      binding,
      config,
      timeline_mapping(["logs/a.jsonl", "logs/b.jsonl"]),
    ))
    is Err(_),
  )
  assert_true(
    (try? merge_retained_timeline(
      binding,
      config,
      timeline_mapping(["logs/blanks-a.jsonl", "logs/blanks-b.jsonl"]),
      skip_blank_lines=true,
    ))
    is Err(_),
  )
  assert_true(
    (try? merge_retained_timeline(
      binding,
      config,
      timeline_mapping(["logs/large.jsonl"]),
    ))
    is Err(_),
  )
  assert_true(
    (try? merge_retained_timeline(
      binding,
      config,
      timeline_mapping(
        ["logs/repeat.jsonl"],
        columns=Array::makei(61, i => {
          header: i.to_string(),
          pointer: "/event",
        }),
      ),
    ))
    is Err(_),
  )
  let limited = {
    ..config,
    limits: { ..config.limits, max_protocol_bytes: 4096, },
  }
  assert_true(
    (try? merge_retained_timeline(
      binding,
      limited,
      timeline_mapping(["logs/repeat.jsonl"], columns=[
        { header: "h".repeat(5000), pointer: "/event", },
      ]),
    ))
    is Err(_),
  )
  let (many_config, _) = test_executor_config()
  let many = [
    for i in 1..<=5 => {
      ("logs/" + i.to_string() + ".jsonl", Bytes::make(900000, 32))
    }
  ]
  let many_binding = run_search_fixture(many_config, many)
  guard (try? merge_retained_timeline(
      many_binding,
      many_config,
      timeline_mapping(many.map(file => file.0)),
    ))
    is Err(error) else {
    fail("expected aggregate byte limit")
  }
  assert_true(error.to_string().contains("exceed 4 MiB"))
}

///|
async test "compiled timeline exports repeatable chronological evidence and source drillback" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI")
  }
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, timeline_sources())
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let mapping = timeline_example_mapping()
  let mapping_path = config.scratch_root + "/timeline.json"
  @fs.write_file(mapping_path, mapping, create_mode=CreateNew)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = ["timeline", "--mapping", mapping_path, "--skip-blank-lines"]
  let (code, output, errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let expected = merge_retained_timeline(
    binding,
    config,
    mapping,
    skip_blank_lines=true,
  )
  assert_eq(output.text(), expected.csv)
  assert_eq(@json.parse(errors.text()), expected.context())
  let (again, repeated, context) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(
    (repeated.binary(), context.binary()),
    (output.binary(), errors.binary()),
  )
  let (drill_code, drill, _) = @process.collect_output(
    executable,
    [
      "search", "logs/alpha.jsonl", "--query", "\"event\":\"retry\"", "--after-line",
      "3", "--limit", "1", "--json",
    ],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(drill_code, 0)
  assert_eq(
    retained_json_at(@json.parse(drill.text()), "/matches/0/line"),
    (4 : Json),
  )
  assert_eq(
    retained_json_at(@json.parse(drill.text()), "/file/fingerprint"),
    expected.sources[0].file.fingerprint.to_json(),
  )
  for
    bad_args in [
      ["timeline"],
      ["timeline", "--mapping", mapping_path],
      args + ["--json"],
      args + ["--skip-blank-lines"],
      args + ["--mapping", mapping_path],
      args + ["--limit", "1"],
      ["timeline", "unexpected-path", "--mapping", mapping_path],
      ["timeline", "--mapping", config.scratch_root],
      ["timeline", "--mapping", mapping_path + ".missing"],
    ] {
    let (failed, empty, diagnostic) = @process.collect_output(
      executable,
      bad_args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(failed != 0)
    assert_eq(empty.binary(), b"")
    assert_true(diagnostic.text().contains("Artifact browse refused"))
  }
  // A later selected file is malformed: not even a CSV header may escape.
  let (bad_config, _) = test_executor_config()
  let bad_binding = run_search_fixture(bad_config, [
    ("logs/alpha.jsonl", timeline_sources()[0].1),
    ("logs/beta.jsonl", b"{broken"),
    ("logs/empty.jsonl", b""),
  ])
  let (bad_path, bad_binding_path) = write_artifact_cli_inputs(
    bad_config, bad_binding,
  )
  let (failed, empty, _) = @process.collect_output(
    executable,
    args,
    extra_env={ "MOONFORT_EXECUTOR_CONFIG": bad_path },
    stdin=@process.redirect_from_file(bad_binding_path),
  )
  assert_true(failed != 0)
  assert_eq(empty.binary(), b"")
  if @env.get_env_var("MOONFORT_TIMELINE_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("alpha.jsonl", timeline_sources()[0].1),
        ("beta.jsonl", timeline_sources()[1].1),
        ("empty.jsonl", b""),
        ("timeline.json", mapping),
        ("timeline.csv", output.binary()),
        ("timeline.context.json", errors.binary()),
        ("drilled-source-line.json", drill.binary()),
        (
          "receipt-binding.json",
          @utf8.encode(binding.to_json().stringify() + "\n"),
        ),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
}
