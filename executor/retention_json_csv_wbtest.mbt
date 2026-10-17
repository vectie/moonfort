///|
fn json_csv_mapping(
  pointer : String,
  columns : Array[RetentionJsonColumn],
) -> Bytes {
  @utf8.encode(
    (
      { "version": 1, "rows": pointer.to_json(), "columns": columns.to_json() } :
      Json).stringify(),
  )
}

///|
test "JSON CSV preserves nested scalar values exact numbers and column order" {
  let source = parse_retained_json(
    "[{\"id\":9007199254740993,\"stats\":{\"time\":1.2300e+4},\"ok\":false,\"a/b\":{\"~\":\"月🌙, \\\"yes\\\"\\r\\nline\"},\"note\":null},{\"id\":-0,\"stats\":{\"time\":1e400},\"ok\":true,\"a/b\":{\"~\":\"=A1\"}}]",
  )
  let columns : Array[RetentionJsonColumn] = [
    { header: "Note", pointer: "/a~1b/~0", },
    { header: "ID", pointer: "/id", },
    { header: "Latency", pointer: "/stats/time", },
    { header: "Passed", pointer: "/ok", },
    { header: "Optional", pointer: "/note", },
  ]
  let before = source.stringify()
  let (csv, rows, missing, nulls) = retained_json_csv(source, columns)
  assert_eq(parse_retained_csv(csv), [
    ["Note", "ID", "Latency", "Passed", "Optional"],
    ["月🌙, \"yes\"\r\nline", "9007199254740993", "1.2300e+4", "false", ""],
    ["=A1", "-0", "1e400", "true", ""],
  ])
  assert_eq(rows, 2)
  assert_eq(missing, 1)
  assert_eq(nulls, 1)
  assert_eq(source.stringify(), before)
}

///|
test "JSON CSV supports empty arrays primitive rows and positional extraction" {
  let columns : Array[RetentionJsonColumn] = [{ header: "Value", pointer: "", }]
  let (empty, rows, missing, nulls) = retained_json_csv(
    parse_retained_json("[]"),
    columns,
  )
  assert_eq(empty, "\"Value\"\r\n")
  assert_eq((rows, missing, nulls), (0, 0, 0))
  let (csv, _, _, _) = retained_json_csv(
    parse_retained_json("[\"01\",\"\",null,true,2]"),
    columns,
  )
  assert_eq(parse_retained_csv(csv), [
    ["Value"],
    ["01"],
    [""],
    [""],
    ["true"],
    ["2"],
  ])
  let positional : Array[RetentionJsonColumn] = [
    { header: "First", pointer: "/values/0", },
    { header: "Empty key", pointer: "/", },
  ]
  let (csv, _, _, _) = retained_json_csv(
    parse_retained_json("[{\"values\":[\"first\"],\"\":\"blank-key\"}]"),
    positional,
  )
  assert_eq(parse_retained_csv(csv)[1], ["first", "blank-key"])
  let (pointer, decoded) = retained_json_columns(
    json_csv_mapping("/checks", positional),
  )
  assert_eq(pointer, "/checks")
  assert_eq(decoded, positional)
}

///|
test "JSON CSV rejects malformed mappings traversal containers and oversized output" {
  let column : RetentionJsonColumn = { header: "Value", pointer: "/v", }
  for
    mapping in [
      b"{}",
      b"{\"version\":2,\"rows\":\"\",\"columns\":[]}",
      b"{\"version\":1,\"rows\":\"\",\"columns\":[{\"header\":\"v\",\"pointer\":\"\",\"unknown\":0}]}",
      b"{\"version\":1,\"rows\":\"\",\"columns\":[],\"rows\":\"/x\"}",
      json_csv_mapping("bad", [column]),
      json_csv_mapping("", []),
      json_csv_mapping("", [column, column]),
      json_csv_mapping("", [{ header: "", pointer: "/v", }]),
      json_csv_mapping("", [{ header: "v", pointer: "/~2", }]),
      json_csv_mapping("", [{ header: "v", pointer: "/" + "x".repeat(4096), }]),
      json_csv_mapping("", [{ header: "x".repeat(16_385), pointer: "", }]),
      Bytes::make(65_537, 32),
    ] {
    try retained_json_columns(mapping) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  for
    (source, pointer) in [
      ("{}", "/v"),
      ("[{\"v\":{}}]", "/v"),
      ("[{\"v\":[]}]", "/v"),
      ("[{\"v\":null}]", "/v/x"),
      ("[{\"v\":1}]", "/v/x"),
      ("[{\"v\":[1]}]", "/v/01"),
      ("[{\"v\":[1]}]", "/v/1"),
      ("[{\"v\":[1]}]", "/v/-"),
      ("[\"\\u0000\"]", ""),
    ] {
    try
      retained_json_csv(parse_retained_json(source), [{ ..column, pointer, }])
      |> ignore
    catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  try
    retained_json_csv(Json::array(["x".repeat(16_385).to_json()]), [
      { ..column, pointer: "", },
    ])
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let repeated = Json::array(Array::make(100, "x".repeat(16_000).to_json()))
  try
    retained_json_csv(repeated, [{ ..column, pointer: "", }]) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "JSON CSV binds source mapping and candidate without changing retained evidence" {
  let (config, _) = test_executor_config()
  let source = b"{\"checks\":[{\"id\":9007199254740993},{\"id\":null},{}]}"
  let mapping = json_csv_mapping("/checks", [{ header: "ID", pointer: "/id", }])
  let binding = json_fixture(config, source)
  let receipt_path = config.retention_root + "/json-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let table = tabulate_retained_json(binding, "report.json", config, mapping)
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
  assert_eq((table.row_count, table.missing_cells, table.null_cells), (3, 1, 1))
  assert_eq(retained_json_at(table.context(), "/pointer"), "/checks".to_json())
  assert_eq(
    retained_json_at(table.context(), "/derived_candidate"),
    (true : Json),
  )
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/json-results/report.json").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  try
    tabulate_retained_json(
      { ..binding, command_digest: "d".repeat(64), },
      "report.json",
      config,
      mapping,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    tabulate_retained_json(
      binding,
      "report.json",
      config,
      json_csv_mapping("/missing", [{ header: "ID", pointer: "/id", }]),
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(config.scratch_root + "/json-results/report.json", b"[]")
  try
    tabulate_retained_json(binding, "report.json", config, mapping) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  for bad in [b"\xff", b"[{\"id\":1,\"id\":2}]", Bytes::make(1_048_577, 32)] {
    let (other, _) = test_executor_config()
    let selected = json_fixture(other, bad)
    try
      tabulate_retained_json(selected, "report.json", other, mapping) |> ignore
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
  let selected = json_fixture(limited, b"[]")
  try
    tabulate_retained_json(
      selected,
      "report.json",
      limited,
      json_csv_mapping("", [{ header: "h".repeat(5000), pointer: "", }]),
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled JSON CSV exports and reopens nested report rows with context" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI for compiled JSON CSV journey")
  }
  let (config, _) = test_executor_config()
  let source = "{\"checks\":[{\"id\":9007199254740993,\"result\":{\"status\":\"review\",\"duration\":1.2300e+4},\"owner\":\"月🌙\",\"note\":\"first, \\\"check\\\"\\nsecond line\"},{\"id\":2,\"result\":{\"status\":\"pass\",\"duration\":-0},\"note\":null}]}\n"
  let mapping = json_csv_mapping("/checks", [
    { header: "ID", pointer: "/id", },
    { header: "Status", pointer: "/result/status", },
    { header: "Duration", pointer: "/result/duration", },
    { header: "Owner", pointer: "/owner", },
    { header: "Note", pointer: "/note", },
  ])
  let binding = json_fixture(config, @utf8.encode(source))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let mapping_path = config.scratch_root + "/columns.json"
  @fs.write_file(mapping_path, mapping, create_mode=CreateNew)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = ["json-csv", "report.json", "--mapping", mapping_path]
  let receipt_path = config.retention_root + "/json-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let (code, output, errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let rows = parse_retained_csv(output.text())
  assert_eq(rows, [
    ["ID", "Status", "Duration", "Owner", "Note"],
    [
      "9007199254740993", "review", "1.2300e+4", "月🌙", "first, \"check\"\nsecond line",
    ],
    ["2", "pass", "-0", "", ""],
  ])
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/binding"), binding.to_json())
  assert_eq(
    retained_json_at(context, "/source_file/fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(source))).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/mapping_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(mapping)).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/candidate_size_bytes"),
    output.binary().length().to_json(),
  )
  assert_eq(retained_json_at(context, "/row_count"), (2 : Json))
  assert_eq(retained_json_at(context, "/missing_cells"), (1 : Json))
  assert_eq(retained_json_at(context, "/null_cells"), (1 : Json))
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
  for
    bad_args in [
      ["json-csv", "report.json"],
      args + ["--json"],
      args + ["--mapping", mapping_path],
      ["json-csv", "report.json", "--mapping", mapping_path + ".missing"],
      ["json-csv", "report.json", "--mapping", config.scratch_root],
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
  if @env.get_env_var("MOONFORT_JSON_CSV_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("report.json", @utf8.encode(source)),
        ("columns.json", mapping),
        ("candidate.csv", output.binary()),
        ("candidate.context.json", errors.binary()),
        (
          "receipt-binding.json",
          @utf8.encode(binding.to_json().stringify() + "\n"),
        ),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  @fs.write_file(mapping_path, "{}")
  let (failed, empty, _) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_true(failed != 0)
  assert_eq(empty.binary(), b"")
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/json-results/report.json").text(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}
