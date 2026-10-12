///|
async fn keyed_csv_fixture(
  config : ExecutorConfig,
  id : String,
  bytes : Bytes,
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: id,
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/" + id
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
      id,
      "book",
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
test "keyed CSV matches compound records despite reordering and reports exact cell changes" {
  let left = parse_retained_csv(
    "id,platform,status,note\n01,linux,pass,steady\n01,mac,review,old\n02,linux,pass,retired\n",
  )
  let right = parse_retained_csv(
    "id,platform,status,note\n03,linux,review,new\n01,mac,pass,\"月🌙, quote \"\"ok\"\"\r\nline\"\n01,linux,pass,steady\n",
  )
  let (changes, added, removed, changed, unchanged) = compare_retained_csv_records(
    left,
    right,
    [1, 2],
  )
  assert_eq((added, removed, changed, unchanged), (1, 1, 1, 1))
  assert_eq(changes.map(row => (row.key, row.change)), [
    (["01", "mac"], "changed"),
    (["02", "linux"], "removed"),
    (["03", "linux"], "added"),
  ])
  assert_eq(changes[0].changed_columns, [3, 4])
  assert_eq(changes[0].before_row, Some(2))
  assert_eq(changes[0].after_row, Some(2))
  assert_eq(changes[0].after.unwrap()[3], "月🌙, quote \"ok\"\r\nline")
  assert_eq(changes[1].after, None)
  assert_eq(changes[2].before, None)
  assert_eq(changes[2].changed_columns, [1, 2, 3, 4])
  assert_eq(left[2][2], "review")
  let (reordered, _, _, _, count) = compare_retained_csv_records(
    left,
    [left[0], left[3], left[1], left[2]],
    [2, 1],
  )
  assert_eq(reordered, [])
  assert_eq(count, 3)
}

///|
test "keyed CSV preserves literal keys numeric spellings and separator collisions" {
  let left = parse_retained_csv(
    "key,part,value\n01,x,1.2300e+4\n1,x,9007199254740993\nA,x,=SUM(A1:A2)\na,x,\n a,x,space\na|b,c,one\na,b|c,two\n",
  )
  let right = parse_retained_csv(
    "\u{feff}key,part,value\r\na,b|c,two\r\na|b,c,changed\r\n a,x,space\r\na,x,\r\nA,x,=SUM(A1:A2)\r\n1,x,9007199254740993\r\n01,x,12300\r\n",
  )
  let (changes, added, removed, changed, unchanged) = compare_retained_csv_records(
    left,
    right,
    [1, 2],
  )
  assert_eq((added, removed, changed, unchanged), (0, 0, 2, 5))
  assert_eq(changes[0].key, ["01", "x"])
  assert_eq(changes[0].before.unwrap()[2], "1.2300e+4")
  assert_eq(changes[1].key, ["a|b", "c"])
  let (renamed, add, remove, _, _) = compare_retained_csv_records(
    [["id"], ["old"]],
    [["id"], ["new"]],
    [1],
  )
  assert_eq((add, remove), (1, 1))
  assert_eq(renamed.map(row => row.change), ["added", "removed"])
}

///|
test "keyed CSV handles header-only tables and duplicate header names by position" {
  let empty = [["id", "id", ""]]
  let rows = [["id", "id", ""], ["a", "x", ""]]
  let (none, a, r, c, u) = compare_retained_csv_records(empty, empty, [2])
  assert_eq(none, [])
  assert_eq((a, r, c, u), (0, 0, 0, 0))
  let (added, _, _, _, _) = compare_retained_csv_records(empty, rows, [2])
  assert_eq(added[0].key, ["x"])
  assert_eq(added[0].before_row, None)
  let (removed, _, _, _, _) = compare_retained_csv_records(rows, empty, [2])
  assert_eq(removed[0].after_row, None)
  assert_eq(removed[0].before.unwrap(), ["a", "x", ""])
}

///|
test "keyed CSV refuses ambiguous keys with side and row diagnostics and schema changes" {
  let valid = parse_retained_csv("id,part\na,x\n")
  for columns in [[], [0], [3], [1, 1]] {
    assert_true(
      (try? compare_retained_csv_records(valid, valid, columns)) is Err(_),
    )
  }
  let duplicate = parse_retained_csv("id,part\na,x\na,y\n")
  guard (try? compare_retained_csv_records(duplicate, valid, [1]))
    is Err(Failure(message)) else {
    fail("expected duplicate-key refusal")
  }
  assert_true(
    message.contains("baseline CSV data row 2 repeats the key of data row 1"),
  )
  guard (try? compare_retained_csv_records(valid, duplicate, [1]))
    is Err(Failure(message)) else {
    fail("expected candidate duplicate-key refusal")
  }
  assert_true(
    message.contains("candidate CSV data row 2 repeats the key of data row 1"),
  )
  let missing = parse_retained_csv("id,part\na,\n")
  guard (try? compare_retained_csv_records(valid, missing, [1, 2]))
    is Err(Failure(message)) else {
    fail("expected empty-key refusal")
  }
  assert_true(
    message.contains("candidate CSV data row 1 has an empty key in column 2"),
  )
  assert_true(
    (try? compare_retained_csv_records(valid, [["part", "id"], ["x", "a"]], [1]))
    is Err(_),
  )
  assert_true(
    (try? compare_retained_csv_records(valid, [["id"], ["a"]], [1])) is Err(_),
  )
}

///|
async test "retained keyed CSV binds both verified sources and exports complete reusable changes" {
  let (config, _) = test_executor_config()
  let left_bytes = b"id,state,note\n01,review,old\n02,pass,steady\n03,pass,removed\n"
  let right_bytes = @utf8.encode(
    "id,state,note\n02,pass,steady\n04,review,\n01,pass,\"月🌙, quote \"\"ok\"\"\r\nline\"\n",
  )
  let left = keyed_csv_fixture(config, "keyed-before", left_bytes)
  let right = keyed_csv_fixture(config, "keyed-after", right_bytes)
  let saved_left = @fs.read_file(config.retention_root + "/keyed-before.json").binary()
  let saved_right = @fs.read_file(config.retention_root + "/keyed-after.json").binary()
  let result = compare_retained_csv(left, right, "checks.csv", config, key_columns=[
    1,
  ])
  assert_eq(
    (result.added, result.removed, result.changed, result.unchanged),
    (1, 1, 1, 1),
  )
  assert_eq((result.baseline_rows, result.candidate_rows), (3, 3))
  assert_eq(result.baseline, left)
  assert_eq(result.candidate, right)
  assert_eq(
    result.before_file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(left_bytes)),
  )
  assert_eq(
    result.after_file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(right_bytes)),
  )
  assert_eq(@json.from_json(result.to_json()), result)
  let csv = parse_retained_csv(result.to_csv())
  assert_eq(csv.length(), 9)
  assert_eq(csv[1], [
    "changed", "[\"01\"]", "1", "3", "2", "state", "review", "pass",
  ])
  assert_eq(csv[2][7], "月🌙, quote \"ok\"\r\nline")
  assert_eq(csv[8], ["added", "[\"04\"]", "", "2", "3", "note", "", ""])
  let same = compare_retained_csv(left, left, "checks.csv", config, key_columns=[
    1,
  ])
  assert_eq(same.entries, [])
  assert_eq(parse_retained_csv(same.to_csv()).length(), 1)
  assert_eq(
    compare_retained_csv(left, right, "checks.csv", config, key_columns=[1]),
    result,
  )
  assert_eq(
    @fs.read_file(config.retention_root + "/keyed-before.json").binary(),
    saved_left,
  )
  assert_eq(
    @fs.read_file(config.retention_root + "/keyed-after.json").binary(),
    saved_right,
  )
  assert_eq(
    @fs.read_file(config.scratch_root + "/keyed-before/checks.csv").binary(),
    left_bytes,
  )
  assert_eq(
    @fs.read_file(config.scratch_root + "/keyed-after/checks.csv").binary(),
    right_bytes,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "retained keyed CSV rejects unreadable invalid oversized or changed evidence" {
  for
    invalid in [
      b"id,state\na\n",
      b"id,state\na,\xff\n",
      Bytes::make(1_048_577, 65),
    ] {
    let (config, _) = test_executor_config()
    let left = keyed_csv_fixture(config, "valid", b"id,state\na,pass\n")
    let right = keyed_csv_fixture(config, "invalid", invalid)
    assert_true(
      (try? compare_retained_csv(left, right, "checks.csv", config, key_columns=[
        1,
      ]))
      is Err(_),
    )
  }
  let (config, _) = test_executor_config()
  let left = keyed_csv_fixture(config, "before", b"id,state\na,pass\n")
  let right = keyed_csv_fixture(config, "after", b"id,state\na,open\n")
  assert_true(
    (try? compare_retained_csv(
      { ..left, command_digest: "d".repeat(64), },
      right,
      "checks.csv",
      config,
      key_columns=[1],
    ))
    is Err(_),
  )
  assert_true(
    (try? compare_retained_csv(
      left,
      { ..right, approval_digest: "e".repeat(64), },
      "checks.csv",
      config,
      key_columns=[1],
    ))
    is Err(_),
  )
  for path in ["missing.csv", "../checks.csv"] {
    assert_true(
      (try? compare_retained_csv(left, right, path, config, key_columns=[1]))
      is Err(_),
    )
  }
  @fs.write_file(
    config.scratch_root + "/after/checks.csv",
    "id,state\na,NOPE\n",
  )
  assert_true(
    (try? compare_retained_csv(left, right, "checks.csv", config, key_columns=[
      1,
    ]))
    is Err(_),
  )
}

///|
async test "keyed CSV comparison bounds amplified exports and full JSON reports" {
  let (config, _) = test_executor_config()
  let headers = [ for n in 1..<=64 => "h" + n.to_string() ].join(",") + "\n"
  let rows = StringBuilder()
  rows.write_string(headers)
  for n in 1..<=5 {
    rows.write_string(
      n.to_string() + "x".repeat(16_000) + ",".repeat(63) + "\n",
    )
  }
  let left = keyed_csv_fixture(config, "short", @utf8.encode(headers))
  let right = keyed_csv_fixture(config, "wide", @utf8.encode(rows.to_string()))
  let comparison = compare_retained_csv(left, right, "checks.csv", config, key_columns=[
    1,
  ])
  guard (try? comparison.to_csv()) is Err(Failure(message)) else {
    fail("expected amplified CSV size refusal")
  }
  assert_true(message.contains("CSV comparison export exceeds 4 MiB"))
  // Compact source cells expand to many explicit JSON entries and field indices.
  let header = [ for n in 1..<=32 => "h" + n.to_string() ].join(",") + "\n"
  let many = StringBuilder()
  many.write_string(header)
  for n in 1..<=20_000 {
    many.write_string(n.to_string() + ",".repeat(31) + "\n")
  }
  let empty = keyed_csv_fixture(config, "empty", @utf8.encode(header))
  let large = keyed_csv_fixture(config, "many", @utf8.encode(many.to_string()))
  assert_true(@utf8.encode(many.to_string()).length() <= 1_048_576)
  guard (try? compare_retained_csv(empty, large, "checks.csv", config, key_columns=[
      1,
    ]))
    is Err(Failure(message)) else {
    fail("expected JSON size refusal")
  }
  assert_true(message.contains("CSV comparison JSON report exceeds 4 MiB"))
  let long_headers = "a".repeat(2000) +
    "," +
    "b".repeat(2000) +
    "," +
    "c".repeat(2000) +
    "\nx,y,z\n"
  let contextual = keyed_csv_fixture(
    config,
    "contextual",
    @utf8.encode(long_headers),
  )
  let small = {
    ..config,
    limits: { ..config.limits, max_protocol_bytes: 4096, },
  }
  guard (try? compare_retained_csv(
      contextual,
      contextual,
      "checks.csv",
      small,
      key_columns=[1],
    ))
    is Err(Failure(message)) else {
    fail("expected context budget refusal")
  }
  assert_true(
    message.contains("CSV comparison context exceeds protocol budget"),
  )
}

///|
async test "compiled keyed CSV comparison ignores reordering and reopens JSON and CSV reports" {
  guard @env.get_env_var("MOONFORT_CSV_COMPARE_CLI") is Some(executable) else {
    fail("set MOONFORT_CSV_COMPARE_CLI for compiled journey")
  }
  let (config, _) = test_executor_config()
  let old = "id,platform,status,note\n01,linux,pass,steady\n01,mac,review,old\n02,linux,pass,retired\n"
  let new = "id,platform,status,note\n03,linux,review,new\n01,mac,pass,\"月🌙, quote \"\"ok\"\"\r\nline\"\n01,linux,pass,steady\n"
  let left = keyed_csv_fixture(config, "cli-before", @utf8.encode(old))
  let right = keyed_csv_fixture(config, "cli-after", @utf8.encode(new))
  let (config_path, _) = write_artifact_cli_inputs(config, left)
  let input : Json = {
    "baseline": left.to_json(),
    "candidate": right.to_json(),
  }
  let input_path = config.retention_root + "/comparison.json"
  @fs.write_file(
    input_path,
    input.stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = ["checks.csv", "--key-columns", "1,2"]
  let (code, output, errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_eq(code, 0)
  assert_eq(errors.binary(), b"")
  let result : RetentionCsvComparison = @json.from_json(
    @json.parse(output.text()),
  )
  assert_eq(
    (result.added, result.removed, result.changed, result.unchanged),
    (1, 1, 1, 1),
  )
  assert_eq(result.entries[0].key, ["01", "mac"])
  assert_eq(result.entries[0].changed_columns, [3, 4])
  let (csv_code, csv, context) = @process.collect_output(
    executable,
    args + ["--csv"],
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_eq(csv_code, 0)
  assert_eq(csv.text(), result.to_csv())
  assert_eq(@json.parse(context.text()), result.context())
  let reopen = config.scratch_root + "/review.csv"
  @fs.write_file(reopen, csv.binary(), create_mode=CreateNew)
  assert_eq(parse_retained_csv(@fs.read_file(reopen).text()).length(), 11)
  let (again, repeated, _) = @process.collect_output(
    executable,
    args + ["--json"],
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_eq(again, 0)
  assert_eq(repeated.binary(), output.binary())
  for
    bad in [
      ["checks.csv"],
      ["checks.csv", "--key-columns", ""],
      ["checks.csv", "--key-columns", "1,1"],
      args + ["--unknown"],
      args + ["--key-columns", "2"],
      args + ["--csv", "--json"],
      args + ["--csv", "--csv"],
    ] {
    let (failed, empty, diagnostic) = @process.collect_output(
      executable,
      bad,
      extra_env~,
      stdin=@process.redirect_from_file(input_path),
    )
    assert_true(failed != 0)
    assert_eq(empty.binary(), b"")
    assert_true(diagnostic.text().contains("CSV comparison unavailable"))
  }
  // A single key column is intentionally ambiguous in this example; no guessed pair.
  let (ambiguous, none, diagnostic) = @process.collect_output(
    executable,
    ["checks.csv", "--key-columns", "1"],
    extra_env~,
    stdin=@process.redirect_from_file(input_path),
  )
  assert_true(ambiguous != 0)
  assert_eq(none.binary(), b"")
  assert_true(
    diagnostic
    .text()
    .contains("baseline CSV data row 2 repeats the key of data row 1"),
  )
  if @env.get_env_var("MOONFORT_CSV_COMPARE_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("baseline.csv", @utf8.encode(old)),
        ("candidate.csv", @utf8.encode(new)),
        ("comparison-input.json", @utf8.encode(input.stringify() + "\n")),
        ("changes.json", output.binary()),
        ("changes.csv", csv.binary()),
        ("changes.context.json", context.binary()),
        ("ambiguous-key.stderr.txt", diagnostic.binary()),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  assert_eq(
    @fs.read_file(config.scratch_root + "/cli-before/checks.csv").text(),
    old,
  )
  assert_eq(
    @fs.read_file(config.scratch_root + "/cli-after/checks.csv").text(),
    new,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}
