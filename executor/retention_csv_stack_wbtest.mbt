///|
fn csv_stack_manifest(files : Array[(String, Bytes)]) -> Bytes {
  @utf8.encode(
    (
      {
        "version": 1,
        "files": ToJson::to_json(
          files.map(pair => {
            let (path, bytes) = pair
            (
              {
                "path": ToJson::to_json(path),
                "fingerprint": ToJson::to_json(
                  @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
                ),
              } : Json)
          }),
        ),
      } : Json).stringify() +
    "\n",
  )
}

///|
fn csv_stack_sources() -> Array[(String, Bytes)] {
  [
    (
      "logs/west.csv",
      @utf8.encode(
        "id,area,seconds,note\r\n01,docs,2.5,\"review, then fix\r\nsecond line\"\r\n02,code,1,月🌙\r\n",
      ),
    ),
    ("logs/empty.csv", b"id,area,seconds,note\n"),
    (
      "logs/east.csv", b"id,area,seconds,note\n01,docs,3.25,=A1\n03,code,,waiting\n",
    ),
  ]
}

///|
test "CSV stack manifests require explicit unique fingerprint bound paths and retain order" {
  let selected = retained_csv_stack_manifest(
    csv_stack_manifest(csv_stack_sources()),
  )
  assert_eq(selected.map(item => item.0), [
    "logs/west.csv", "logs/empty.csv", "logs/east.csv",
  ])
  let valid = @utf8.decode(
    csv_stack_manifest([("a.csv", b"h\n"), ("b.csv", b"h\n")]),
  )
  for
    invalid in [
      "{}",
      "[]",
      valid.replace_all(old="\"version\":1", new="\"version\":1.0"),
      valid.replace_all(old="\"version\":1", new="\"version\":1,\"version\":1"),
      valid.replace_all(old="\"version\":1", new="\"version\":1,\"unknown\":0"),
      valid.replace_all(
        old="\"path\":\"a.csv\"",
        new="\"path\":\"a.csv\",\"path\":\"a.csv\"",
      ),
      valid.replace_all(
        old="\"path\":\"a.csv\"",
        new="\"path\":\"a.csv\",\"unknown\":0",
      ),
      valid.replace_all(old="fingerprint", new="wrong"),
    ] {
    try retained_csv_stack_manifest(@utf8.encode(invalid)) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail(invalid)
    }
  }
  for
    invalid in [
      csv_stack_manifest([]),
      csv_stack_manifest([("a", b"h")]),
      csv_stack_manifest([("same", b"h"), ("same", b"h")]),
      csv_stack_manifest(Array::makei(33, index => (index.to_string(), b"h"))),
      b"\xff",
      Bytes::make(65_537, 32),
    ] {
    try retained_csv_stack_manifest(invalid) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  for
    path in [
      "",
      "/absolute",
      "../parent",
      "a/../b",
      "./a",
      "a//b",
      "a/",
      "a\\b",
      "a\u{0}b",
      "x".repeat(4097),
    ] {
    try
      retained_csv_stack_manifest(
        csv_stack_manifest([(path, b"h"), ("b", b"h")]),
      )
      |> ignore
    catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let digest = selected[0].1
  for fingerprint in ["", "A".repeat(64), "g".repeat(64), "f".repeat(63)] {
    let altered = @utf8.decode(csv_stack_manifest(csv_stack_sources())).replace_all(
      old=digest,
      new=fingerprint,
    )
    try retained_csv_stack_manifest(@utf8.encode(altered)) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
}

///|
test "CSV stack preserves exact duplicate rows headers quotes and original locators" {
  let first = parse_retained_csv(
    "\u{feff}id,,note,note\r\n01,001,\"quote \"\"yes\"\"\r\nnext\",=A1\r\n01,001,\"quote \"\"yes\"\"\r\nnext\",=A1\r\n",
  )
  let second = parse_retained_csv("id,,note,note\n02,-0,月🌙,\n")
  let original = first.map(row => row.copy())
  let (csv, count) = stack_retained_csv_records([
    ("z.csv", first),
    ("a.csv", second),
  ])
  assert_eq(count, 3)
  assert_eq(first, original)
  assert_eq(parse_retained_csv(csv), [
    ["__source_path", "__source_row", "id", "", "note", "note"],
    ["z.csv", "1", "01", "001", "quote \"yes\"\r\nnext", "=A1"],
    ["z.csv", "2", "01", "001", "quote \"yes\"\r\nnext", "=A1"],
    ["a.csv", "1", "02", "-0", "月🌙", ""],
  ])
  assert_true(csv.has_suffix("\r\n"))
}

///|
test "CSV stack handles empty shards and rejects incompatible or colliding headers" {
  let (csv, count) = stack_retained_csv_records([("a", [["h"]]), ("b", [["h"]])])
  assert_eq(count, 0)
  assert_eq(parse_retained_csv(csv), [["__source_path", "__source_row", "h"]])
  for
    tables in [
      [("a", [["x", "y"]]), ("b", [["y", "x"]])],
      [("a", [["x"]]), ("b", [["X"]])],
      [("a", [["x"]]), ("b", [[" x"]])],
      [("a", [["x"]]), ("b", [["x", "y"]])],
      [("a", [["__source_path"]]), ("b", [["__source_path"]])],
      [("a", [["__source_row"]]), ("b", [["__source_row"]])],
      [("a", [Array::make(63, "h")]), ("b", [Array::make(63, "h")])],
    ] {
    try stack_retained_csv_records(tables) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let (wide, _) = stack_retained_csv_records([
    ("a", [Array::make(62, "h")]),
    ("b", [Array::make(62, "h")]),
  ])
  assert_eq(parse_retained_csv(wide)[0].length(), 64)
}

///|
test "CSV stack validates full row and serialized byte limits without truncation" {
  let full = parse_retained_csv("h\n" + "a\n".repeat(20_000))
  let (csv, count) = stack_retained_csv_records([("a", full), ("b", [["h"]])])
  assert_eq(count, 20_000)
  assert_eq(parse_retained_csv(csv).length(), 20_001)
  try
    stack_retained_csv_records([("a", full), ("b", [["h"], ["b"]])]) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let dense = parse_retained_csv(
    "h,".repeat(19) + "h\n" + ("a,".repeat(19) + "a\n").repeat(14_000),
  )
  try
    stack_retained_csv_records([("a", dense), ("b", [dense[0]])]) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let long_header = [Array::make(62, "月".repeat(16_384))]
  try
    stack_retained_csv_records([("a", long_header), ("b", long_header)])
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "CSV stack verifies all originals and exact output metadata without authority changes" {
  let (config, _) = test_executor_config()
  let files = csv_stack_sources()
  let binding = run_search_fixture(config, files)
  let receipt_path = config.retention_root + "/run-search.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let manifest = csv_stack_manifest(files)
  let result = stack_retained_csv(binding, config, manifest)
  assert_eq(result.row_count, 4)
  assert_eq(result.sources.map(source => source.row_count), [2, 0, 2])
  assert_eq(
    result.sources.map(source => source.file.relative_path),
    files.map(pair => pair.0),
  )
  assert_eq(
    result.manifest_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(manifest)),
  )
  assert_eq(result.manifest_size_bytes, manifest.length())
  assert_eq(
    result.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(result.csv))),
  )
  assert_eq(result.candidate_size_bytes, @utf8.encode(result.csv).length())
  assert_eq(
    stack_retained_csv(binding, config, manifest).context(),
    result.context(),
  )
  let (rollup, groups) = aggregate_csv_records(
    parse_retained_csv(result.csv),
    [4],
    5,
  )
  assert_eq(groups, 2)
  assert_eq(parse_retained_csv(rollup)[1][4], "5.750000")
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  for (path, bytes) in files {
    assert_eq(
      @fs.read_file(config.scratch_root + "/run-search/" + path).binary(),
      bytes,
    )
  }
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  let stale = csv_stack_manifest([(files[0].0, b"stale"), files[2]])
  try stack_retained_csv(binding, config, stale) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    stack_retained_csv(
      binding,
      config,
      csv_stack_manifest([files[0], ("missing.csv", b"h\n")]),
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    stack_retained_csv(
      { ..binding, command_digest: "d".repeat(64), },
      config,
      manifest,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(
    config.scratch_root + "/run-search/" + files[2].0,
    b"id,area,seconds,note\n01,docs,9,tampered\n",
  )
  try stack_retained_csv(binding, config, manifest) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "CSV stack rejects a malformed later shard and cumulative source limits" {
  for
    invalid in [
      b"",
      b"h\n\xff",
      b"h\nx,y\n",
      b"h\n\"unfinished",
      Bytes::make(1_048_577, 32),
    ] {
    let (config, _) = test_executor_config()
    let files = [("a.csv", b"h\nok\n"), ("b.csv", invalid)]
    let binding = run_search_fixture(config, files)
    try
      stack_retained_csv(binding, config, csv_stack_manifest(files)) |> ignore
    catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let (config, _) = test_executor_config()
  let files = Array::makei(5, index => {
    (index.to_string() + ".csv", Bytes::make(900_000, 32))
  })
  let binding = run_search_fixture(config, files)
  try
    stack_retained_csv(binding, config, csv_stack_manifest(files)) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled CSV stack connects inventory consolidation downstream rollup and source drillback" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail(
      "set MOONFORT_ARTIFACT_READER_CLI for compiled CSV consolidation journey",
    )
  }
  let (config, _) = test_executor_config()
  let files = csv_stack_sources()
  let binding = run_search_fixture(config, files)
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let (listed, inventory, _) = @process.collect_output(
    executable,
    ["list", "--json"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(listed, 0)
  let list : RetentionArtifactList = @json.from_json(
    @json.parse(inventory.text()),
  )
  assert_eq(list.files.length(), 3)
  // User-selected order is deliberately different from lexical inventory order.
  let manifest = @utf8.encode(
    (
      {
        "version": 1,
        "files": ToJson::to_json(
          files.map(pair => {
            let file = list.files.filter(file => file.relative_path == pair.0)[0]
            (
              {
                "path": ToJson::to_json(file.relative_path),
                "fingerprint": ToJson::to_json(file.fingerprint),
              } : Json)
          }),
        ),
      } : Json).stringify() +
    "\n",
  )
  let manifest_path = config.scratch_root + "/combine.json"
  @fs.write_file(manifest_path, manifest, create_mode=CreateNew)
  let args = ["stack-csv", "--manifest", manifest_path]
  let receipt_path = config.retention_root + "/run-search.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let (code, output, errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/binding"), binding.to_json())
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())),
    ),
  )
  let candidate_path = config.scratch_root + "/combined.csv"
  @fs.write_file(candidate_path, output.binary(), create_mode=CreateNew)
  let rows = parse_retained_csv(@fs.read_file(candidate_path).text())
  assert_eq(rows.length(), 5)
  assert_eq(rows[1][0], "logs/west.csv")
  assert_eq(rows[3][0], "logs/east.csv")
  // This is the existing typed engine, not a forged retained input for the CLI.
  let (rollup, groups) = aggregate_csv_records(rows, [4], 5)
  assert_eq(groups, 2)
  let summary = parse_retained_csv(rollup)
  assert_eq(summary[1][0], "docs")
  assert_eq(summary[1][4], "5.750000")
  let (drill_code, drillback, _) = @process.collect_output(
    executable,
    ["table", rows[3][0], "--after-row", "0", "--limit", "1", "--json"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(drill_code, 0)
  let page : RetentionCsvPage = @json.from_json(@json.parse(drillback.text()))
  assert_eq(page.rows[0].row.to_string(), rows[3][1])
  assert_eq(page.rows[0].cells, rows[3][2:].to_owned())
  let (again, repeat, repeat_context) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(repeat.binary(), output.binary())
  assert_eq(repeat_context.binary(), errors.binary())
  for
    bad in [
      ["stack-csv"],
      args + ["--json"],
      args + ["--manifest", manifest_path],
      ["stack-csv", "unexpected.csv", "--manifest", manifest_path],
      ["stack-csv", "--manifest", manifest_path + ".missing"],
      ["stack-csv", "--manifest", config.scratch_root],
    ] {
    let (status, empty, _) = @process.collect_output(
      executable,
      bad,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(status != 0)
    assert_eq(empty.binary(), b"")
  }
  if @env.get_env_var("MOONFORT_CSV_STACK_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("west.csv", files[0].1),
        ("empty.csv", files[1].1),
        ("east.csv", files[2].1),
        ("inventory.json", inventory.binary()),
        ("combine.json", manifest),
        ("combined.csv", output.binary()),
        ("combined.context.json", errors.binary()),
        ("rollup.csv", @utf8.encode(rollup)),
        ("drillback.json", drillback.binary()),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  @fs.write_file(
    manifest_path,
    csv_stack_manifest([files[0], (files[2].0, b"stale")]),
  )
  let (refused, empty, _) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_true(refused != 0)
  assert_eq(empty.binary(), b"")
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  for (path, bytes) in files {
    assert_eq(
      @fs.read_file(config.scratch_root + "/run-search/" + path).binary(),
      bytes,
    )
  }
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "compiled CSV stack emits no partial rows when a later selected schema is incompatible" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("compiled reader required")
  }
  let (config, _) = test_executor_config()
  let files = [
    ("a.csv", b"id,value\n01,first\n"),
    ("b.csv", b"value,id\nsecond,02\n"),
  ]
  let binding = run_search_fixture(config, files)
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let manifest_path = config.scratch_root + "/combine.json"
  @fs.write_file(
    manifest_path,
    csv_stack_manifest(files),
    create_mode=CreateNew,
  )
  let (status, output, error) = @process.collect_output(
    executable,
    ["stack-csv", "--manifest", manifest_path],
    extra_env={ "MOONFORT_EXECUTOR_CONFIG": config_path },
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_true(status != 0)
  assert_eq(output.binary(), b"")
  assert_true(error.text().contains("Artifact browse refused"))
}

///|
async test "CSV stack accepts maximum shard count and refuses oversized provenance context" {
  let (config, _) = test_executor_config()
  let files = Array::makei(32, index => (index.to_string() + ".csv", b"h\n"))
  let binding = run_search_fixture(config, files)
  let manifest = csv_stack_manifest(files)
  let result = stack_retained_csv(binding, config, manifest)
  assert_eq(result.sources.length(), 32)
  assert_eq(result.row_count, 0)
  assert_eq(parse_retained_csv(result.csv), [
    ["__source_path", "__source_row", "h"],
  ])
  assert_true(@utf8.encode(result.context().stringify()).length() > 4096)
  let bounded = {
    ..config,
    limits: {
      ..config.limits,
      max_protocol_bytes: @utf8.encode(result.context().stringify()).length(),
    },
  }
  let error = try stack_retained_csv(binding, bounded, manifest) catch {
    error => error
  } noraise {
    _ => fail("expected context refusal")
  }
  assert_true(
    error.to_string().contains("context exceeds protocol budget"),
    msg=error.to_string(),
  )
}
