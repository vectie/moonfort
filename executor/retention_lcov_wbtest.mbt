///|
let lcov_example : String =
  #|TN:checkout
  #|SF:src/月,"checkout".mbt
  #|FN:1,main
  #|FNDA:3,main
  #|DA:1,3,abc
  #|DA:7,0
  #|LF:2
  #|LH:1
  #|BRDA:7,0,0,-
  #|end_of_record
  #|TN:checkout
  #|SF:src/月,"checkout".mbt
  #|DA:7,2
  #|end_of_record
  #|SF:C:\source\empty.mbt
  #|LF:0
  #|LH:0
  #|end_of_record
  #|

///|
async fn lcov_fixture(
  config : ExecutorConfig,
  source : Bytes,
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "lcov-results",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/lcov-results"
  @fs.mkdir(scratch, permission=0o700)
  @fs.write_file(
    scratch + "/coverage.info",
    source,
    create_mode=CreateNew,
    permission=0o600,
  )
  let files = @sandbox.inventory_scratch(scratch, 32000000L).unwrap().entries.filter(entry => {
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
      files,
      config,
    ),
  )
  binding
}

///|
test "LCOV line observations preserve repeated records and uncovered drillback" {
  let (csv, records, total, covered, rows) = retained_lcov_csv(
    lcov_example, false,
  )
  assert_eq((records, total, covered, rows), (3, 3, 2, 3))
  let table = parse_retained_csv(csv)
  assert_eq(table[1], [
    "1", "5", "checkout", "src/月,\"checkout\".mbt", "1", "3", "abc",
  ])
  assert_eq(table[2][1], "6")
  assert_eq(table[3][0], "2")
  assert_eq(table[3][4], "7")
  assert_eq(table[3][5], "2")
  let (filtered, r, t, c, n) = retained_lcov_csv(lcov_example, true)
  assert_eq((r, t, c, n), (3, 3, 2, 1))
  assert_eq(parse_retained_csv(filtered)[1], table[2])
  assert_eq(
    retained_lcov_csv(lcov_example.replace_all(old="\n", new="\r\n"), false),
    (csv, records, total, covered, rows),
  )
}

///|
test "LCOV refuses incomplete, contradictory and ambiguous coverage" {
  for
    bad in [
      "", "DA:1,0\n", "TN:orphan\n", "SF:a\nDA:1,0\n", "SF:a\nDA:1,0\nDA:01,2\nend_of_record\n",
      "SF:a\nDA:0,0\nend_of_record\n", "SF:a\nDA:1,-1\nend_of_record\n", "SF:a\nDA:1,2147483648\nend_of_record\n",
      "SF:a\nDA:1,0\nLF:2\nend_of_record\n", "SF:a\nDA:1,0\nLH:1\nend_of_record\n",
      "SF:a\nSF:b\nend_of_record\n", "SF:a\nUNKNOWN:value\nend_of_record\n", "SF:a\nTN:wrong\nend_of_record\n",
    ] {
    try retained_lcov_csv(bad, true) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  try retained_lcov_csv("SF:a\n" + "x".repeat(1048576), false) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let (_, _, _, _, zero) = retained_lcov_csv(
    "SF:a\nDA:1,1\nend_of_record", true,
  )
  assert_eq(zero, 0)
}

///|
async test "LCOV API binds exact source and output without touching retained evidence" {
  let (config, _) = test_executor_config()
  let source = @utf8.encode(lcov_example)
  let binding = lcov_fixture(config, source)
  let receipt_path = config.retention_root + "/lcov-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let result = tabulate_retained_lcov(
    binding,
    "coverage.info",
    config,
    uncovered_only=true,
  )
  assert_eq(
    (
      result.record_count,
      result.line_count,
      result.covered_count,
      result.row_count,
    ),
    (3, 3, 2, 1),
  )
  assert_eq(
    result.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(source)),
  )
  assert_eq(
    result.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(result.csv))),
  )
  assert_eq(result.candidate_size_bytes, @utf8.encode(result.csv).length())
  assert_eq(retained_json_at(result.context(), "/binding"), binding.to_json())
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/lcov-results/coverage.info").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  try
    tabulate_retained_lcov(
      { ..binding, command_digest: "d".repeat(64), },
      "coverage.info",
      config,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled LCOV command filters uncovered observations with atomic refusal" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI")
  }
  let (config, _) = test_executor_config()
  let binding = lcov_fixture(config, @utf8.encode(lcov_example))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let (code, output, errors) = @process.collect_output(
    executable,
    ["lcov-csv", "coverage.info", "--uncovered"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let table = parse_retained_csv(output.text())
  assert_eq(table.length(), 2)
  assert_eq(table[1][1], "6")
  assert_eq(table[1][5], "0")
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/line_count"), (3 : Json))
  assert_eq(retained_json_at(context, "/row_count"), (1 : Json))
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())),
    ),
  )
  let (all_code, all_output, all_context) = @process.collect_output(
    executable,
    ["lcov-csv", "coverage.info"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(all_code, 0)
  assert_eq(parse_retained_csv(all_output.text()).length(), 4)
  let (again, repeated, repeated_context) = @process.collect_output(
    executable,
    ["lcov-csv", "coverage.info", "--uncovered"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(repeated.binary(), output.binary())
  assert_eq(repeated_context.binary(), errors.binary())
  for
    args in [
      ["lcov-csv"],
      ["lcov-csv", "coverage.info", "--uncovered", "--uncovered"],
      ["lcov-csv", "missing.info"],
    ] {
    let (failed, empty, _) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(failed != 0)
    assert_eq(empty.binary(), b"")
  }
  let bad = lcov_example + "SF:bad\nDA:1,-1\nend_of_record\n"
  let (bad_config, _) = test_executor_config()
  let bad_binding = lcov_fixture(bad_config, @utf8.encode(bad))
  let (bad_config_path, bad_binding_path) = write_artifact_cli_inputs(
    bad_config, bad_binding,
  )
  let (failed, empty, refusal) = @process.collect_output(
    executable,
    ["lcov-csv", "coverage.info"],
    extra_env={ "MOONFORT_EXECUTOR_CONFIG": bad_config_path },
    stdin=@process.redirect_from_file(bad_binding_path),
  )
  assert_true(failed != 0)
  assert_eq(empty.binary(), b"")
  if @env.get_env_var("MOONFORT_LCOV_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("coverage.info", @utf8.encode(lcov_example)),
        ("all.csv", all_output.binary()),
        ("all.context.json", all_context.binary()),
        ("uncovered.csv", output.binary()),
        ("uncovered.context.json", errors.binary()),
        ("binding.json", @utf8.encode(binding.to_json().stringify())),
        ("invalid-later.info", @utf8.encode(bad)),
        ("invalid-later.stdout", empty.binary()),
        ("invalid-later.stderr", refusal.binary()),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateNew)
    }
  }
}
