///|
async fn csv_fixture(
  config : ExecutorConfig,
  bytes : Bytes,
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "table-results",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/table-results"
  @fs.mkdir(scratch, permission=0o700)
  @fs.write_file(
    scratch + "/checks.csv",
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
test "retained CSV parses quoted multiline cells empty fields and BOM" {
  assert_eq(
    parse_retained_csv(
      "\u{feff}name,note,empty\r\n月🌙,\"comma, quote \"\"ok\"\"\r\nsecond line\",\r\n",
    ),
    [
      ["name", "note", "empty"],
      ["月🌙", "comma, quote \"ok\"\r\nsecond line", ""],
    ],
  )
  assert_eq(parse_retained_csv("h\na\n\nb"), [["h"], ["a"], [""], ["b"]])
  assert_eq(parse_retained_csv("\"\"\n\"\""), [[""], [""]])
  assert_eq(parse_retained_csv("a,a\r1,2\r"), [["a", "a"], ["1", "2"]])
  assert_eq(parse_retained_csv("a,b"), [["a", "b"]])
  for
    input in [
      "",
      "\u{feff}",
      "a\n\"open",
      "a\nq\"x",
      "a\n\"q\"x",
      "a,b\n1",
      "a\n1,2",
      "a\n\u{0}",
      "a\n" + "x".repeat(16_385),
      "h,".repeat(64) + "h",
      "h\n" + "v\n".repeat(20_001),
    ] {
    assert_true((try? parse_retained_csv(input)) is Err(_))
  }
}

///|
async test "retained CSV projects filters and resumes logical rows without writes" {
  let (config, _roots) = test_executor_config()
  let text = "id,status,note\r\n01,pass,ready\r\n02,follow-up,\"quickstart, docs\r\nsecond line\"\r\n03,pass,月🌙\r\n04,follow-up,\"add \"\"migration\"\" note\"\r\n"
  let bytes = @utf8.encode(text)
  let binding = csv_fixture(config, bytes)
  let record_path = config.retention_root + "/table-results.json"
  let original = @fs.read_file(record_path).binary()
  let first = read_retained_csv(
    binding,
    "checks.csv",
    config,
    columns=[3, 1],
    where_column=2,
    equals="follow-up",
    limit=1,
  )
  assert_eq(first.columns, [3, 1])
  assert_eq(first.headers, ["note", "id"])
  assert_eq(first.total_rows, 4)
  assert_eq(first.matching_rows, 2)
  assert_eq(first.rows, [
    { row: 2, cells: ["quickstart, docs\r\nsecond line", "02"], },
  ])
  assert_eq(first.next_after_row, 2)
  assert_true(first.has_more)
  let rest = read_retained_csv(
    binding,
    "checks.csv",
    config,
    columns=[3, 1],
    where_column=2,
    equals="follow-up",
    after_row=first.next_after_row,
  )
  assert_eq(rest.rows[0].row, 4)
  assert_eq(rest.rows[0].cells, ["add \"migration\" note", "04"])
  assert_false(rest.has_more)
  assert_eq(parse_retained_csv(first.to_csv()), [
    first.headers,
    first.rows[0].cells,
  ])
  assert_eq(parse_retained_csv(rest.to_csv()), [
    rest.headers,
    rest.rows[0].cells,
  ])
  let all = read_retained_csv(binding, "checks.csv", config)
  assert_eq(all.columns, [1, 2, 3])
  assert_eq(parse_retained_csv(all.to_csv()), parse_retained_csv(text))
  let empty = read_retained_csv(
    binding,
    "checks.csv",
    config,
    where_column=2,
    equals="absent",
  )
  assert_eq(empty.matching_rows, 0)
  assert_eq(empty.rows, [])
  assert_false(empty.has_more)
  assert_eq(
    read_retained_csv(binding, "checks.csv", config, after_row=4).rows,
    [],
  )
  assert_eq(@fs.read_file(record_path).binary(), original)
  assert_eq(
    @fs.read_file(config.scratch_root + "/table-results/checks.csv").binary(),
    bytes,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "retained CSV preserves ambiguous headers and empty values" {
  let (config, _roots) = test_executor_config()
  let binding = csv_fixture(config, b",name,name\n,01,=SUM(A1:A2)\nother,02,\n")
  let result = read_retained_csv(
    binding,
    "checks.csv",
    config,
    columns=[3, 2],
    where_column=1,
    equals="",
  )
  assert_eq(result.headers, ["name", "name"])
  assert_eq(result.rows, [{ row: 1, cells: ["=SUM(A1:A2)", "01"], }])
  assert_eq(result.to_csv(), "\"name\",\"name\"\r\n\"=SUM(A1:A2)\",\"01\"\r\n")
  let (header_config, _roots) = test_executor_config()
  let header = csv_fixture(header_config, b"name,value\r\n")
  let page = read_retained_csv(header, "checks.csv", header_config)
  assert_eq(page.total_rows, 0)
  assert_eq(page.rows, [])
  assert_false(page.has_more)
}

///|
async test "retained CSV shrinks protocol pages without skipping rows" {
  let (base, _roots) = test_executor_config()
  let config = { ..base, limits: { ..base.limits, max_protocol_bytes: 4096, }, }
  let binding = csv_fixture(
    config,
    @utf8.encode(
      "name,note\n" + ("月," + "\u{1}".repeat(200) + "\n").repeat(30),
    ),
  )
  let found : Array[Int] = []
  for after_row = 0 {
    let page = read_retained_csv(
      binding,
      "checks.csv",
      config,
      after_row~,
      limit=100,
    )
    assert_eq(page.total_rows, 30)
    assert_eq(page.matching_rows, 30)
    assert_true(@utf8.encode(page.to_json().stringify()).length() <= 4096)
    assert_true(page.rows.length() < 100)
    for row in page.rows {
      found.push(row.row)
    }
    if !page.has_more {
      break
    }
    assert_true(page.next_after_row > after_row)
    continue page.next_after_row
  }
  assert_eq(found, [ for index in 1..<=30 => index ])
  let (large_base, _roots) = test_executor_config()
  let large = {
    ..large_base,
    limits: { ..large_base.limits, max_protocol_bytes: 4096, },
  }
  let large_binding = csv_fixture(
    large,
    @utf8.encode("id,note\n01," + "x".repeat(5000)),
  )
  assert_true(
    (try? read_retained_csv(large_binding, "checks.csv", large)) is Err(_),
  )
  assert_eq(
    read_retained_csv(large_binding, "checks.csv", large, columns=[1]).rows[0].cells,
    ["01"],
  )
}

///|
async test "retained CSV refuses invalid selections stale binding and malformed input" {
  let (config, _roots) = test_executor_config()
  let binding = csv_fixture(config, b"id,note\n01,ok\n")
  for columns in [[0], [3], [1, 1], [-1]] {
    assert_true(
      (try? read_retained_csv(binding, "checks.csv", config, columns~))
      is Err(_),
    )
  }
  for after_row in [-1, 2] {
    assert_true(
      (try? read_retained_csv(binding, "checks.csv", config, after_row~))
      is Err(_),
    )
  }
  for limit in [0, 101] {
    assert_true(
      (try? read_retained_csv(binding, "checks.csv", config, limit~)) is Err(_),
    )
  }
  for where_column in [-1, 3] {
    assert_true(
      (try? read_retained_csv(binding, "checks.csv", config, where_column~))
      is Err(_),
    )
  }
  assert_true(
    (try? read_retained_csv(binding, "checks.csv", config, equals="oops"))
    is Err(_),
  )
  assert_true(
    (try? read_retained_csv(
      { ..binding, command_digest: "d".repeat(64), },
      "checks.csv",
      config,
    ))
    is Err(_),
  )
  for path in ["missing.csv", "../outside"] {
    assert_true((try? read_retained_csv(binding, path, config)) is Err(_))
  }
  @fs.write_file(
    config.scratch_root + "/table-results/checks.csv",
    b"id,note\n01,NO\n",
  )
  assert_true((try? read_retained_csv(binding, "checks.csv", config)) is Err(_))
  @fs.write_file(
    config.scratch_root + "/table-results/checks.csv",
    b"id,note\n01,ok\n",
  )
  let record = load_retention_record(binding.retention_id, config)
  @fs.write_file(
    config.retention_root + "/table-results.json",
    { ..record, expires_at_ms: 1L, }.to_json().stringify(),
  )
  assert_true((try? read_retained_csv(binding, "checks.csv", config)) is Err(_))
  for
    bytes in [
      b"h\n\xff",
      b"h\n\x00",
      b"a,b\nx",
      b"h\n\"open",
      Bytes::make(1_048_577, 65),
    ] {
    let (other, _roots) = test_executor_config()
    let selected = csv_fixture(other, bytes)
    assert_true(
      (try? read_retained_csv(selected, "checks.csv", other)) is Err(_),
    )
  }
}

///|
async test "compiled retained CSV CLI explores filtered pages and exports reusable CSV" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI for the compiled CSV journey")
  }
  let (config, _roots) = test_executor_config()
  let text = "id,area,status,note\r\n01,core,pass,24 checks\r\n02,docs,follow-up,\"quickstart, fixture\r\nneeds example\"\r\n03,ui,pass,月🌙 18 checks\r\n04,docs,follow-up,\"add \"\"migration\"\" note\"\r\n"
  let binding = csv_fixture(config, @utf8.encode(text))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  for
    (label, args) in [
      (
        "table-first.txt",
        [
          "table", "checks.csv", "--columns", "1,4", "--where-column", "3", "--equals",
          "follow-up", "--limit", "1",
        ],
      ),
      (
        "table-rest.json",
        [
          "table", "checks.csv", "--columns", "1,4", "--where-column", "3", "--equals",
          "follow-up", "--after-row", "2", "--json",
        ],
      ),
      (
        "table-selected.csv",
        [
          "table", "checks.csv", "--columns", "1,4", "--where-column", "3", "--equals",
          "follow-up", "--csv",
        ],
      ),
      (
        "table-first.csv",
        [
          "table", "checks.csv", "--columns", "1,4", "--where-column", "3", "--equals",
          "follow-up", "--limit", "1", "--csv",
        ],
      ),
    ] {
    let (code, output, errors) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_eq(code, 0)
    if label == "table-first.txt" {
      assert_eq(errors.binary(), b"")
      assert_true(output.text().contains("2 matching data rows of 4"))
      assert_true(
        output
        .text()
        .contains("2: [\"02\",\"quickstart, fixture\\r\\nneeds example\"]"),
      )
      assert_true(output.text().contains("[More: --after-row 2"))
    } else if label == "table-rest.json" {
      assert_eq(errors.binary(), b"")
      let page : RetentionCsvPage = @json.from_json(@json.parse(output.text()))
      assert_eq(page.binding, binding)
      assert_eq(page.rows, [
        { row: 4, cells: ["04", "add \"migration\" note"], },
      ])
      assert_false(page.has_more)
    } else {
      let reopened = parse_retained_csv(output.text())
      assert_eq(reopened[0], ["id", "note"])
      assert_eq(reopened[1], ["02", "quickstart, fixture\r\nneeds example"])
      if label == "table-selected.csv" {
        assert_eq(reopened[2], ["04", "add \"migration\" note"])
        assert_true(errors.text().contains("[End of table selection]"))
      } else {
        assert_eq(reopened.length(), 2)
        assert_true(errors.text().contains("[More: --after-row 2"))
      }
    }
    if @env.get_env_var("MOONFORT_CSV_EVIDENCE") is Some(root) {
      @fs.write_file(
        root + "/" + label,
        output.binary(),
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      if !errors.binary().is_empty() {
        @fs.write_file(
          root + "/" + label + ".stderr.txt",
          errors.binary(),
          create_mode=CreateOrTruncate,
          permission=0o600,
        )
      }
    }
  }
  for
    args in [
      ["table", "checks.csv", "--where-column", "3"],
      ["table", "checks.csv", "--equals", "pass"],
      ["table", "checks.csv", "--where-column", "0", "--equals", ""],
      ["table", "checks.csv", "--columns", "1,1"],
      ["table", "checks.csv", "--columns", ""],
      ["table", "checks.csv", "--csv", "--json"],
      ["table", "checks.csv", "--csv", "--csv"],
      ["table", "checks.csv", "--after-row", "5"],
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
  if @env.get_env_var("MOONFORT_CSV_EVIDENCE") is Some(root) {
    @fs.write_file(
      root + "/checks.csv",
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
