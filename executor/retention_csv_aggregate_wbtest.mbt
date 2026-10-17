///|
test "decimal aggregation is exact and rounds mean halfway away from zero" {
  for
    (text, expected) in [
      ("0", 0L),
      ("-0.000000", 0L),
      ("0001.20", 1_200_000L),
      ("-0.000001", -1L),
      ("9000000000000.000000", 9_000_000_000_000_000_000L),
      ("-9000000000000", -9_000_000_000_000_000_000L),
    ] {
    assert_eq(retained_decimal(text), expected)
    assert_eq(retained_decimal(retained_decimal_text(expected)), expected)
  }
  for
    invalid in [
      "", "-", ".1", "1.", "+1", " 1", "1 ", "1e2", "NaN", "Infinity", "1,000", "1.0000001",
      "1..0", "--1", "9000000000000.000001", "-9000000000001", "999999999999999999999999",
      "月",
    ] {
    try retained_decimal(invalid) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let records = parse_retained_csv(
    "area,value\nA,0.1\nA,0.2\nB,-0.000001\nB,0\nC,0.000001\nC,0\n",
  )
  let (csv, count) = aggregate_csv_records(records, [1], 2)
  assert_eq(count, 3)
  assert_eq(parse_retained_csv(csv), [
    [
      "area", "row_count", "numeric_count", "blank_count", "sum", "minimum", "maximum",
      "mean", "first_source_row",
    ],
    ["A", "2", "2", "0", "0.300000", "0.100000", "0.200000", "0.150000", "1"],
    ["C", "2", "2", "0", "0.000001", "0.000000", "0.000001", "0.000001", "5"],
    ["B", "2", "2", "0", "-0.000001", "-0.000001", "0.000000", "-0.000001", "3"],
  ])
}

///|
test "numeric groups preserve exact keys blanks ties and logical row drillback" {
  let records = parse_retained_csv(
    "key,other,value\n\"a,b\",c,1\na,\"b,c\",1\n\"月\n🌙\",=formula,\n\"a,b\",c,\nnegative,x,-2\nzero,x,0\n",
  )
  let (csv, count) = aggregate_csv_records(records, [1, 2], 3)
  assert_eq(count, 5)
  let rows = parse_retained_csv(csv)
  assert_eq(rows[1], [
    "a,b", "c", "2", "1", "1", "1.000000", "1.000000", "1.000000", "1.000000", "1",
  ])
  assert_eq(rows[2][0], "a")
  assert_eq(rows[3][0], "zero")
  assert_eq(rows[4][0], "negative")
  assert_eq(rows[5], [
    "月\n🌙", "=formula", "1", "0", "1", "", "", "", "", "3",
  ])
  let (total, _) = aggregate_csv_records(records, [], 3)
  assert_eq(parse_retained_csv(total)[1], [
    "6", "4", "2", "0.000000", "-2.000000", "1.000000", "0.000000", "1",
  ])
  assert_eq(aggregate_csv_records(records, [1, 2], 3), (csv, count))
  assert_eq(aggregate_csv_records([["value"]], [], 1).1, 0)
}

///|
test "numeric aggregation refuses invalid columns late numbers overflow and oversized output" {
  let records = parse_retained_csv("key,value\nx,1\ny,nope\n")
  for groups in [[0], [3], [1, 1]] {
    try aggregate_csv_records(records, groups, 2) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  for value in [0, -1, 3] {
    try aggregate_csv_records(records, [], value) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let message = try aggregate_csv_records(records, [1], 2) catch {
    Failure(message) => message
    _ => fail("expected late value refusal")
  } noraise {
    _ => fail("expected late value refusal")
  }
  assert_true(message.contains("source data row 2, column 2"))
  for
    values in [
      "value\n9000000000000\n0.000001\n", "value\n-9000000000000\n-0.000001\n",
    ] {
    try
      aggregate_csv_records(parse_retained_csv(values), [], 1) |> ignore
    catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let (safe, _) = aggregate_csv_records(
    parse_retained_csv("v\n9000000000000\n-9000000000000\n"),
    [],
    1,
  )
  assert_eq(parse_retained_csv(safe)[1][3], "0.000000")
  let wide = [Array::make(64, "h"), Array::make(64, "1")]
  assert_eq(
    parse_retained_csv(
      aggregate_csv_records(wide, [ for i in 1..<=56 => i ], 64).0,
    )[0].length(),
    64,
  )
  try
    aggregate_csv_records(wide, [ for i in 1..<=57 => i ], 64) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let repeated = [["v"]] + Array::make(20000, ["0.000001"])
  assert_eq(parse_retained_csv(aggregate_csv_records(repeated, [], 1).0)[1], [
    "20000", "20000", "0", "0.020000", "0.000001", "0.000001", "0.000001", "1",
  ])
  let large = [["key", "v"]] + [ for i in 1..<=20000 => [i.to_string(), "1"] ]
  let message = try aggregate_csv_records(large, [1], 2) catch {
    Failure(message) => message
    _ => fail("expected full output refusal")
  } noraise {
    _ => fail("expected full output refusal")
  }
  assert_true(message.contains("candidate exceeds 1 MiB"))
}

///|
async test "retained decimal aggregation binds source output and leaves receipts unchanged" {
  let (config, _) = test_executor_config()
  let bytes = b"area,seconds\ncore,0.1\ncore,0.2\n"
  let binding = csv_fixture(config, bytes)
  let receipt_path = config.retention_root + "/table-results.json"
  let before = @fs.read_file(receipt_path).binary()
  let result = aggregate_retained_csv(
    binding,
    "checks.csv",
    config,
    value_column=2,
    group_by=[1],
  )
  assert_eq(result.source_rows, 2)
  assert_eq(result.group_count, 1)
  assert_eq(
    result.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
  )
  assert_eq(
    result.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(result.csv))),
  )
  assert_eq(result.candidate_size_bytes, @utf8.encode(result.csv).length())
  assert_eq(retained_json_at(result.context(), "/decimal_places"), (6 : Json))
  assert_eq(@fs.read_file(receipt_path).binary(), before)
  assert_eq(
    @fs.read_file(config.scratch_root + "/table-results/checks.csv").binary(),
    bytes,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  try
    aggregate_retained_csv(
      { ..binding, command_digest: "d".repeat(64), },
      "checks.csv",
      config,
      value_column=2,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(
    config.scratch_root + "/table-results/checks.csv",
    b"area,seconds\ncore,9.9\n",
  )
  try
    aggregate_retained_csv(binding, "checks.csv", config, value_column=2)
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(config.scratch_root + "/table-results/checks.csv", bytes)
  let record = load_retention_record(binding.retention_id, config)
  @fs.write_file(
    receipt_path,
    { ..record, expires_at_ms: 1L, }.to_json().stringify(),
  )
  try
    aggregate_retained_csv(binding, "checks.csv", config, value_column=2)
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled decimal rollup exports ranked groups total and original evidence drillback" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI")
  }
  let (config, _) = test_executor_config()
  let source = "id,area,seconds,note\r\n01,core,0.1,ready\r\n02,docs,3.250001,\"slow, sample\r\nretry\"\r\n03,core,0.2,月🌙\r\n04,docs,1.25,ok\r\n05,ui,,missing\r\n06,core,-0.05,adjustment\r\n"
  let binding = csv_fixture(config, @utf8.encode(source))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = [
    "aggregate-csv", "checks.csv", "--value-column", "3", "--group-by", "2",
  ]
  let (code, output, errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let expected = [
    [
      "area", "row_count", "numeric_count", "blank_count", "sum", "minimum", "maximum",
      "mean", "first_source_row",
    ],
    ["docs", "2", "2", "0", "4.500001", "1.250000", "3.250001", "2.250001", "2"],
    [
      "core", "3", "3", "0", "0.250000", "-0.050000", "0.200000", "0.083333", "1",
    ],
    ["ui", "1", "0", "1", "", "", "", "", "5"],
  ]
  assert_eq(parse_retained_csv(output.text()), expected)
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/binding"), binding.to_json())
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())),
    ),
  )
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
  assert_eq(
    retained_json_at(@json.parse(row_output.text()), "/rows/0/cells/3"),
    ("slow, sample\r\nretry" : Json),
  )
  let (total_code, total_output, total_context) = @process.collect_output(
    executable,
    ["aggregate-csv", "checks.csv", "--value-column", "3"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(total_code, 0)
  assert_eq(parse_retained_csv(total_output.text())[1], [
    "6", "5", "1", "4.750001", "-0.050000", "3.250001", "0.950000", "1",
  ])
  for
    bad_args in [
      ["aggregate-csv", "checks.csv"],
      args + ["--json"],
      args + ["--limit", "1"],
      args + ["--value-column", "1"],
      ["aggregate-csv", "checks.csv", "--value-column", "0"],
      ["aggregate-csv", "checks.csv", "--value-column", "3", "--group-by", ""],
      [
        "aggregate-csv", "checks.csv", "--value-column", "3", "--group-by", "2,2",
      ],
      ["aggregate-csv", "checks.csv", "--value-column", "4"],
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
  if @env.get_env_var("MOONFORT_CSV_AGGREGATE_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("retained-checks.csv", @utf8.encode(source)),
        ("rollup.csv", output.binary()),
        ("rollup.context.json", errors.binary()),
        ("total.csv", total_output.binary()),
        ("total.context.json", total_context.binary()),
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
