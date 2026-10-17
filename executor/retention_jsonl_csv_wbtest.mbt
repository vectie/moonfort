///|
fn jsonl_csv_mapping(columns : Array[RetentionJsonColumn]) -> Bytes {
  @utf8.encode(
    ({ "version": 1, "columns": columns.to_json() } : Json).stringify(),
  )
}

///|
async fn jsonl_fixture(
  config : ExecutorConfig,
  bytes : Bytes,
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "jsonl-results",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/jsonl-results"
  @fs.mkdir(scratch, permission=0o700)
  @fs.write_file(
    scratch + "/diagnostics.jsonl",
    bytes,
    create_mode=CreateNew,
    permission=0o600,
  )
  let entries = @sandbox.inventory_scratch(scratch, 32_000_000L).unwrap().entries.filter(entry => {
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
      entries,
      config,
    ),
  )
  binding
}

///|
test "JSONL CSV preserves exact values and physical lines across CRLF and blank separators" {
  let source = "{\"id\":9007199254740993,\"v\":1.2300e+4,\"a/b\":{\"~\":\"月🌙, \\\"yes\\\"\\r\\nline\"},\"note\":null}\r\n \t\r\n{\"id\":-0,\"v\":1e400,\"a/b\":{\"~\":\"=A1\"}}\n"
  let columns : Array[RetentionJsonColumn] = [
    { header: "ID", pointer: "/id", },
    { header: "Duration", pointer: "/v", },
    { header: "Text", pointer: "/a~1b/~0", },
    { header: "Note", pointer: "/note", },
  ]
  let (rows, source_lines, total, blanks) = retained_jsonl_rows(source, true)
  assert_eq(source_lines, [1, 3])
  assert_eq((total, blanks), (3, 1))
  let (csv, count, missing, nulls) = retained_json_csv(
    Json::array(rows),
    columns,
    source_lines~,
  )
  assert_eq(parse_retained_csv(csv), [
    ["__source_line", "ID", "Duration", "Text", "Note"],
    ["1", "9007199254740993", "1.2300e+4", "月🌙, \"yes\"\r\nline", ""],
    ["3", "-0", "1e400", "=A1", ""],
  ])
  assert_eq((count, missing, nulls), (2, 1, 1))
  assert_true(csv.has_suffix("\r\n"))
  assert_eq(retained_jsonl_columns(jsonl_csv_mapping(columns)), columns)
}

///|
test "JSONL supports empty files scalar records and explicit blank handling" {
  let columns : Array[RetentionJsonColumn] = [{ header: "Value", pointer: "", }]
  for
    (source, expected_lines, expected_blanks) in [
      ("", 0, 0),
      ("\n", 1, 1),
      (" \t\r\n\r\n ", 3, 3),
    ] {
    let (rows, source_lines, total, blanks) = retained_jsonl_rows(source, true)
    let (csv, count, _, _) = retained_json_csv(
      Json::array(rows),
      columns,
      source_lines~,
    )
    assert_eq(csv, "\"__source_line\",\"Value\"\r\n")
    assert_eq((count, total, blanks), (0, expected_lines, expected_blanks))
  }
  for blank in ["\n", " ", "1\n\n2", "1\n\n"] {
    try retained_jsonl_rows(blank, false) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let (rows, source_lines, total, blanks) = retained_jsonl_rows(
    "\"01\"\nnull\ntrue\r\n-0", false,
  )
  let (csv, _, missing, nulls) = retained_json_csv(
    Json::array(rows),
    columns,
    source_lines~,
  )
  assert_eq(parse_retained_csv(csv), [
    ["__source_line", "Value"],
    ["1", "01"],
    ["2", ""],
    ["3", "true"],
    ["4", "-0"],
  ])
  assert_eq((total, blanks, missing, nulls), (4, 0, 0, 1))
  let (rows, lines, _, _) = retained_jsonl_rows(
    "[\"first\", 2]\n[\"second\", 3]\n", false,
  )
  let (csv, _, _, _) = retained_json_csv(
    Json::array(rows),
    [{ header: "Value", pointer: "/0", }],
    source_lines=lines,
  )
  assert_eq(parse_retained_csv(csv)[2], ["2", "second"])
}

///|
test "JSONL rejects malformed later records duplicates pretty JSON and invalid projection" {
  for
    bad in [
      "{\"id\":1,\"id\":2}",
      "{\"x\":0,\"\\u0078\":1}",
      "{} trailing",
      "1 2",
      "{",
      "[1,",
      "\u{feff}{}",
      "\u{a0}",
      "[".repeat(65) + "0" + "]".repeat(65),
    ] {
    let error = try retained_jsonl_rows("{}\n\n" + bad, true) catch {
      error => error
    } noraise {
      _ => fail("expected bad later record")
    }
    assert_true(error.to_string().contains("source line 3"))
  }
  try retained_jsonl_rows("{\n\"id\":1\n}\n", false) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let columns : Array[RetentionJsonColumn] = [
    { header: "Value", pointer: "/v/0", },
  ]
  let (rows, source_lines, _, _) = retained_jsonl_rows(
    "{\"v\":[1]}\n\n{\"v\":null}", true,
  )
  let error = try
    retained_json_csv(Json::array(rows), columns, source_lines~)
  catch {
    error => error
  } noraise {
    _ => fail("expected scalar traversal error")
  }
  assert_true(error.to_string().contains("source line 3 column 1"))
  let (containers, lines, _, _) = retained_jsonl_rows("{\"v\":{}}\n", false)
  try
    retained_json_csv(
      Json::array(containers),
      [{ header: "Value", pointer: "/v", }],
      source_lines=lines,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
test "JSONL mapping and aggregate value line candidate budgets remain bounded" {
  let column : RetentionJsonColumn = { header: "Value", pointer: "", }
  for
    mapping in [
      b"{}",
      b"{\"version\":1,\"rows\":\"\",\"columns\":[]}",
      b"{\"version\":1,\"version\":1,\"columns\":[]}",
      jsonl_csv_mapping([]),
      jsonl_csv_mapping([column, column]),
      jsonl_csv_mapping([{ header: "__source_line", pointer: "", }]),
      jsonl_csv_mapping([{ header: "Value", pointer: "/~2", }]),
      jsonl_csv_mapping(
        Array::makei(64, i => { header: i.to_string(), pointer: "", }),
      ),
      Bytes::make(65_537, 32),
    ] {
    try retained_jsonl_columns(mapping) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  assert_eq(
    retained_jsonl_columns(
      jsonl_csv_mapping(
        Array::makei(63, i => { header: i.to_string(), pointer: "", }),
      ),
    ).length(),
    63,
  )
  let (rows, lines, total, blanks) = retained_jsonl_rows(
    "0\n".repeat(20_000),
    false,
  )
  assert_eq(
    (rows.length(), lines[19_999], total, blanks),
    (20_000, 20_000, 20_000, 0),
  )
  try retained_jsonl_rows("0\n".repeat(20_001), false) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try retained_jsonl_rows("\n".repeat(20_001), true) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let (objects, _, _, _) = retained_jsonl_rows(
    "{\"v\":0}\n".repeat(10_000),
    false,
  )
  assert_eq(objects.length(), 10_000)
  try retained_jsonl_rows("{\"v\":0}\n".repeat(10_001), false) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let repeated = Json::array(Array::make(100, "x".repeat(16_000).to_json()))
  try
    retained_json_csv(
      repeated,
      [column],
      source_lines=Array::makei(100, i => i + 1),
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "JSONL API binds exact source mapping candidate and leaves originals unchanged" {
  let (config, _) = test_executor_config()
  let source = b"{\"id\":9007199254740993}\n\n{\"id\":null}\n{}\n"
  let mapping = jsonl_csv_mapping([{ header: "ID", pointer: "/id", }])
  let binding = jsonl_fixture(config, source)
  let receipt_path = config.retention_root + "/jsonl-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let table = tabulate_retained_jsonl(
    binding,
    "diagnostics.jsonl",
    config,
    mapping,
    skip_blank_lines=true,
  )
  assert_eq(table.binding, binding)
  assert_eq(
    table.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(source)),
  )
  assert_eq(
    table.mapping_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(mapping)),
  )
  assert_eq(
    table.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(table.csv))),
  )
  assert_eq(table.candidate_size_bytes, @utf8.encode(table.csv).length())
  assert_eq(
    (
      table.total_lines,
      table.row_count,
      table.blank_lines_skipped,
      table.missing_cells,
      table.null_cells,
    ),
    (4, 3, 1, 1, 1),
  )
  assert_eq(
    retained_json_at(table.context(), "/source_line_column"),
    "__source_line".to_json(),
  )
  assert_eq(
    retained_json_at(table.context(), "/skip_blank_lines"),
    (true : Json),
  )
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/jsonl-results/diagnostics.jsonl").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  try
    tabulate_retained_jsonl(binding, "diagnostics.jsonl", config, mapping)
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    tabulate_retained_jsonl(
      { ..binding, command_digest: "d".repeat(64), },
      "diagnostics.jsonl",
      config,
      mapping,
      skip_blank_lines=true,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(
    config.scratch_root + "/jsonl-results/diagnostics.jsonl",
    b"{}\n",
  )
  try
    tabulate_retained_jsonl(
      binding,
      "diagnostics.jsonl",
      config,
      mapping,
      skip_blank_lines=true,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "JSONL API refuses invalid UTF8 oversized source expired receipt and context overflow" {
  let mapping = jsonl_csv_mapping([{ header: "ID", pointer: "/id", }])
  for source in [b"{}\n\xff", b"{}\n\xef\xbb\xbf{}", Bytes::make(1_048_577, 32)] {
    let (config, _) = test_executor_config()
    let binding = jsonl_fixture(config, source)
    try
      tabulate_retained_jsonl(binding, "diagnostics.jsonl", config, mapping)
      |> ignore
    catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let (base, _) = test_executor_config()
  let limited = {
    ..base,
    limits: { ..base.limits, max_protocol_bytes: 4096, },
  }
  let binding = jsonl_fixture(limited, b"{}\n")
  try
    tabulate_retained_jsonl(
      binding,
      "diagnostics.jsonl",
      limited,
      jsonl_csv_mapping([{ header: "h".repeat(5000), pointer: "/id", }]),
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let path = base.retention_root + "/jsonl-results.json"
  let saved = load_retention_record(binding.retention_id, base)
  @fs.write_file(path, { ..saved, expires_at_ms: 1L, }.to_json().stringify())
  try
    tabulate_retained_jsonl(binding, "diagnostics.jsonl", base, mapping)
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled JSONL browser exports reopens drills back and refuses partial candidates" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI")
  }
  let (config, _) = test_executor_config()
  let source = "{\"id\":9007199254740993,\"result\":{\"status\":\"review\",\"duration\":1.2300e+4},\"owner\":\"月🌙\",\"note\":\"first, \\\"check\\\"\\nsecond line\"}\r\n \t\r\n{\"id\":2,\"result\":{\"status\":\"pass\",\"duration\":-0},\"note\":null}\n{\"id\":3,\"result\":{\"status\":\"review\",\"duration\":1e400},\"note\":\"=A1\"}"
  let mapping = jsonl_csv_mapping([
    { header: "ID", pointer: "/id", },
    { header: "Status", pointer: "/result/status", },
    { header: "Duration", pointer: "/result/duration", },
    { header: "Owner", pointer: "/owner", },
    { header: "Note", pointer: "/note", },
  ])
  let binding = jsonl_fixture(config, @utf8.encode(source))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let mapping_path = config.scratch_root + "/columns.json"
  @fs.write_file(mapping_path, mapping, create_mode=CreateNew)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = [
    "jsonl-csv", "diagnostics.jsonl", "--mapping", mapping_path, "--skip-blank-lines",
  ]
  let receipt = @fs.read_file(config.retention_root + "/jsonl-results.json").binary()
  let (code, output, errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let rows = parse_retained_csv(output.text())
  assert_eq(rows, [
    ["__source_line", "ID", "Status", "Duration", "Owner", "Note"],
    [
      "1", "9007199254740993", "review", "1.2300e+4", "月🌙", "first, \"check\"\nsecond line",
    ],
    ["3", "2", "pass", "-0", "", ""],
    ["4", "3", "review", "1e400", "", "=A1"],
  ])
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/binding"), binding.to_json())
  assert_eq(retained_json_at(context, "/row_count"), (3 : Json))
  assert_eq(retained_json_at(context, "/total_lines"), (4 : Json))
  assert_eq(retained_json_at(context, "/blank_lines_skipped"), (1 : Json))
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())).to_json(),
  )
  let reopened = config.scratch_root + "/candidate.csv"
  @fs.write_file(reopened, output.binary(), create_mode=CreateNew)
  assert_eq(parse_retained_csv(@fs.read_file(reopened).text()), rows)
  let (again, repeated, repeated_context) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(repeated.binary(), output.binary())
  assert_eq(repeated_context.binary(), errors.binary())
  let (found, drillback, _) = @process.collect_output(
    executable,
    [
      "search", "diagnostics.jsonl", "--query", "\"id\":2", "--after-line", "2",
      "--limit", "1", "--json",
    ],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(found, 0)
  let detail = @json.parse(drillback.text())
  assert_eq(retained_json_at(detail, "/matches/0/line"), (3 : Json))
  assert_eq(
    retained_json_at(detail, "/file/fingerprint"),
    retained_json_at(context, "/source_file/fingerprint"),
  )
  for
    bad_args in [
      ["jsonl-csv", "diagnostics.jsonl"],
      ["jsonl-csv", "diagnostics.jsonl", "--mapping", mapping_path],
      args + ["--json"],
      args + ["--skip-blank-lines"],
      args + ["--mapping", mapping_path],
      ["jsonl-csv", "diagnostics.jsonl", "--mapping", mapping_path + ".missing"],
      ["jsonl-csv", "diagnostics.jsonl", "--mapping", config.scratch_root],
      [
        "json-csv", "diagnostics.jsonl", "--mapping", mapping_path, "--skip-blank-lines",
      ],
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
  if @env.get_env_var("MOONFORT_JSONL_CSV_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("diagnostics.jsonl", @utf8.encode(source)),
        ("columns.json", mapping),
        ("candidate.csv", output.binary()),
        ("candidate.context.json", errors.binary()),
        ("drilled-source-line.json", drillback.binary()),
        (
          "receipt-binding.json",
          @utf8.encode(binding.to_json().stringify() + "\n"),
        ),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  assert_eq(
    @fs.read_file(config.retention_root + "/jsonl-results.json").binary(),
    receipt,
  )
  assert_eq(
    @fs.read_file(config.scratch_root + "/jsonl-results/diagnostics.jsonl").text(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  // A new retained fixture contains a valid first record and broken last one.
  // The CLI must not emit even a header from that incomplete candidate.
  let (bad_config, _) = test_executor_config()
  let bad_binding = jsonl_fixture(bad_config, b"{\"id\":1}\n{\"id\":2")
  let (bad_config_path, bad_binding_path) = write_artifact_cli_inputs(
    bad_config, bad_binding,
  )
  let (failed, empty, diagnostic) = @process.collect_output(
    executable,
    args,
    extra_env={ "MOONFORT_EXECUTOR_CONFIG": bad_config_path },
    stdin=@process.redirect_from_file(bad_binding_path),
  )
  assert_true(failed != 0)
  assert_eq(empty.binary(), b"")
  assert_true(diagnostic.text().contains("Artifact browse refused"))
}
