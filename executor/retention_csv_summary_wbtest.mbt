///|
test "CSV frequency groups exact tuples and ranks by count then first source row" {
  let source = parse_retained_csv(
    "area,status,note\nA,error,one\na,error,two\nA,error,three\nA,warn,four\n,error,five\na,error,six\n A,error,space\n01,error,zero\n1,error,one\n",
  )
  let (csv, matching, groups) = summarize_csv_records(source, [2, 1], 0, "")
  assert_eq((matching, groups), (9, 7))
  assert_eq(parse_retained_csv(csv), [
    ["status", "area", "row_count", "first_source_row"],
    ["error", "A", "2", "1"],
    ["error", "a", "2", "2"],
    ["warn", "A", "1", "4"],
    ["error", "", "1", "5"],
    ["error", " A", "1", "7"],
    ["error", "01", "1", "8"],
    ["error", "1", "1", "9"],
  ])
  assert_eq(source[0], ["area", "status", "note"])
  assert_eq(source[1], ["A", "error", "one"])
  assert_eq(
    summarize_csv_records(source, [2, 1], 0, ""),
    (csv, matching, groups),
  )
}

///|
test "CSV frequency preserves quoted Unicode empty formula cells and tuple boundaries" {
  let source = parse_retained_csv(
    "\u{feff}row_count,row_count\r\n\"a,b\",c\r\na,\"b,c\"\r\n\"月🌙\r\nquote \"\"ok\"\"\",=SUM(A1:A2)\r\n\"a,b\",c\r\n,\r\n",
  )
  let (csv, matching, groups) = summarize_csv_records(source, [1, 2], 0, "")
  assert_eq((matching, groups), (5, 4))
  assert_eq(parse_retained_csv(csv), [
    ["row_count", "row_count", "row_count", "first_source_row"],
    ["a,b", "c", "2", "1"],
    ["a", "b,c", "1", "2"],
    ["月🌙\r\nquote \"ok\"", "=SUM(A1:A2)", "1", "3"],
    ["", "", "1", "5"],
  ])
}

///|
test "CSV frequency filters before grouping and preserves original logical row positions" {
  let source = parse_retained_csv(
    "area,status\nA,pass\nB,error\nA,error\nA,error\nB,pass\nC,\n",
  )
  let (csv, matching, groups) = summarize_csv_records(source, [1], 2, "error")
  assert_eq((matching, groups), (3, 2))
  assert_eq(parse_retained_csv(csv), [
    ["area", "row_count", "first_source_row"],
    ["A", "2", "3"],
    ["B", "1", "2"],
  ])
  let (empty_cell, _, _) = summarize_csv_records(source, [1], 2, "")
  assert_eq(parse_retained_csv(empty_cell)[1], ["C", "1", "6"])
  for records in [source, [["area", "status"]]] {
    let (empty, count, groups) = summarize_csv_records(
      records,
      [1],
      2,
      "absent",
    )
    assert_eq((count, groups), (0, 0))
    assert_eq(parse_retained_csv(empty), [
      ["area", "row_count", "first_source_row"],
    ])
  }
}

///|
test "CSV frequency validates groups filters width and complete candidate bound" {
  let source = parse_retained_csv("a,b\nx,y\n")
  for columns in [[], [0], [-1], [3], [1, 1]] {
    assert_true((try? summarize_csv_records(source, columns, 0, "")) is Err(_))
  }
  for (column, value) in [(-1, ""), (3, ""), (0, "x"), (1, "x".repeat(16385))] {
    assert_true(
      (try? summarize_csv_records(source, [1], column, value)) is Err(_),
    )
  }
  let wide = [Array::make(64, "h"), Array::make(64, "v")]
  let (accepted, _, _) = summarize_csv_records(
    wide,
    [
      for i in 1..<=62 => i
    ],
    0,
    "",
  )
  assert_eq(parse_retained_csv(accepted)[0].length(), 64)
  assert_true(
    (try? summarize_csv_records(wide, [ for i in 1..<=63 => i ], 0, ""))
    is Err(_),
  )
  let repeated = [["key"]] + Array::make(20000, ["same"])
  let (counted, count, groups) = summarize_csv_records(repeated, [1], 0, "")
  assert_eq((count, groups), (20000, 1))
  assert_eq(parse_retained_csv(counted)[1], ["same", "20000", "1"])
  let unique = [["key"]] + [ for i in 1..<=20000 => [i.to_string()] ]
  let (all, count, groups) = summarize_csv_records(unique, [1], 0, "")
  assert_eq((count, groups), (20000, 20000))
  assert_eq(parse_retained_csv(all).length(), 20001)
  assert_eq(parse_retained_csv(all)[20000], ["20000", "1", "20000"])
  let oversized = [["key"]] +
    [
      for i in 1..<=20000 => ["x".repeat(40) + i.to_string()]
    ]
  guard (try? summarize_csv_records(oversized, [1], 0, ""))
    is Err(Failure(message)) else {
    fail("expected candidate size refusal")
  }
  assert_true(message.contains("candidate exceeds 1 MiB"))
}

///|
async test "retained CSV summary binds exact source and candidate without modifying evidence" {
  let (config, _) = test_executor_config()
  let bytes = b"area,status\ncore,pass\ndocs,error\ndocs,error\n"
  let binding = csv_fixture(config, bytes)
  let receipt_path = config.retention_root + "/table-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let result = summarize_retained_csv(
    binding,
    "checks.csv",
    config,
    group_by=[1],
    where_column=2,
    equals="error",
  )
  assert_eq(result.binding, binding)
  assert_eq(
    (result.source_rows, result.matching_rows, result.group_count),
    (3, 2, 1),
  )
  assert_eq(result.group_by, [1])
  assert_eq(
    result.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
  )
  assert_eq(
    result.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(result.csv))),
  )
  assert_eq(result.candidate_size_bytes, @utf8.encode(result.csv).length())
  assert_eq(retained_json_at(result.context(), "/excluded_rows"), (1 : Json))
  assert_eq(
    retained_json_at(result.context(), "/derived_candidate"),
    (true : Json),
  )
  assert_eq(retained_json_at(result.context(), "/group_by"), ([1] : Json))
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/table-results/checks.csv").binary(),
    bytes,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "retained CSV summary refuses stale expired malformed and over-budget evidence" {
  let (config, _) = test_executor_config()
  let bytes = b"area,status\ndocs,error\n"
  let binding = csv_fixture(config, bytes)
  assert_true(
    (try? summarize_retained_csv(
      { ..binding, command_digest: "d".repeat(64), },
      "checks.csv",
      config,
      group_by=[1],
    ))
    is Err(_),
  )
  for path in ["missing.csv", "../outside"] {
    assert_true(
      (try? summarize_retained_csv(binding, path, config, group_by=[1]))
      is Err(_),
    )
  }
  @fs.write_file(
    config.scratch_root + "/table-results/checks.csv",
    b"area,status\ndocs,ERROR\n",
  )
  assert_true(
    (try? summarize_retained_csv(binding, "checks.csv", config, group_by=[1]))
    is Err(_),
  )
  @fs.write_file(config.scratch_root + "/table-results/checks.csv", bytes)
  let record = load_retention_record(binding.retention_id, config)
  @fs.write_file(
    config.retention_root + "/table-results.json",
    { ..record, expires_at_ms: 1L, }.to_json().stringify(),
  )
  assert_true(
    (try? summarize_retained_csv(binding, "checks.csv", config, group_by=[1]))
    is Err(_),
  )
  for
    invalid in [
      b"h\n\xff",
      b"h\n\x00",
      b"a,b\nx",
      b"h\n\"open",
      Bytes::make(1048577, 65),
    ] {
    let (other, _) = test_executor_config()
    let selected = csv_fixture(other, invalid)
    assert_true(
      (try? summarize_retained_csv(selected, "checks.csv", other, group_by=[1]))
      is Err(_),
    )
  }
  let (base, _) = test_executor_config()
  let small = { ..base, limits: { ..base.limits, max_protocol_bytes: 4096, }, }
  let selected = csv_fixture(small, b"h\nv\n")
  guard (try? summarize_retained_csv(
      selected,
      "checks.csv",
      small,
      group_by=[1],
      where_column=1,
      equals="x".repeat(5000),
    ))
    is Err(Failure(message)) else {
    fail("expected summary context budget refusal")
  }
  assert_true(message.contains("context exceeds protocol budget"))
}

///|
async test "compiled CSV summary ranks diagnostic groups exports context and drills back to a source row" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI for compiled summary journey")
  }
  let (config, _) = test_executor_config()
  let source = "id,area,status,note\r\n01,core,pass,ready\r\n02,docs,error,\"quickstart, sample\r\nmissing\"\r\n03,docs,error,月🌙\r\n04,ui,error,layout\r\n05,core,error,parse\r\n06,docs,warn,draft\r\n07,,error,unknown\r\n"
  let binding = csv_fixture(config, @utf8.encode(source))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = [
    "summarize-csv", "checks.csv", "--group-by", "2,3", "--where-column", "3", "--equals",
    "error",
  ]
  let (code, output, errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let expected = [
    ["area", "status", "row_count", "first_source_row"],
    ["docs", "error", "2", "2"],
    ["ui", "error", "1", "4"],
    ["core", "error", "1", "5"],
    ["", "error", "1", "7"],
  ]
  assert_eq(parse_retained_csv(output.text()), expected)
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/binding"), binding.to_json())
  assert_eq(
    retained_json_at(context, "/source_file/fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(source))).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/candidate_size_bytes"),
    output.binary().length().to_json(),
  )
  assert_eq(retained_json_at(context, "/matching_rows"), (5 : Json))
  assert_eq(retained_json_at(context, "/source_rows"), (7 : Json))
  assert_eq(retained_json_at(context, "/group_count"), (4 : Json))
  let saved = config.scratch_root + "/summary.csv"
  @fs.write_file(saved, output.binary(), create_mode=CreateNew)
  assert_eq(parse_retained_csv(@fs.read_file(saved).text()), expected)
  let (again, repeated, repeated_context) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(repeated.binary(), output.binary())
  assert_eq(repeated_context.binary(), errors.binary())
  let (row_code, row_output, _) = @process.collect_output(
    executable,
    ["table", "checks.csv", "--after-row", "1", "--limit", "1", "--json"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(row_code, 0)
  let row = @json.parse(row_output.text())
  assert_eq(retained_json_at(row, "/rows/0/row"), (2 : Json))
  assert_eq(
    retained_json_at(row, "/rows/0/cells/3"),
    ("quickstart, sample\r\nmissing" : Json),
  )
  let (all_code, all_output, all_context) = @process.collect_output(
    executable,
    ["summarize-csv", "checks.csv", "--group-by", "2"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(all_code, 0)
  assert_eq(parse_retained_csv(all_output.text())[1], ["docs", "3", "2"])
  for
    bad_args in [
      ["summarize-csv", "checks.csv"],
      ["summarize-csv", "checks.csv", "--group-by", ""],
      ["summarize-csv", "checks.csv", "--group-by", "2,2"],
      ["summarize-csv", "checks.csv", "--group-by", "2", "--where-column", "3"],
      ["summarize-csv", "checks.csv", "--group-by", "2", "--equals", "error"],
      [
        "summarize-csv", "checks.csv", "--group-by", "2", "--where-column", "0",
        "--equals", "",
      ],
      args + ["--json"],
      args + ["--limit", "1"],
      args + ["--group-by", "1"],
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
  if @env.get_env_var("MOONFORT_CSV_SUMMARY_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("retained-checks.csv", @utf8.encode(source)),
        ("summary.csv", output.binary()),
        ("summary.context.json", errors.binary()),
        ("all-areas.csv", all_output.binary()),
        ("all-areas.context.json", all_context.binary()),
        ("drilled-source-row.json", row_output.binary()),
        (
          "receipt-binding.json",
          @utf8.encode(binding.to_json().stringify() + "\n"),
        ),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
}
