///|
let sarif_example : String =
  #|{"version":"2.1.0","runs":[
  #| {"tool":{"driver":{"name":"Local analyzer","rules":[
  #|   {"id":"R1","name":"First rule","defaultConfiguration":{"level":"warning"}},
  #|   {"id":"R2","name":"Second rule","defaultConfiguration":{"level":"note"}}]}},
  #|  "artifacts":[{"location":{"uri":"src/checkout.mbt","uriBaseId":"%SRCROOT%"}}],
  #|  "results":[
  #|   {"ruleIndex":0,"level":"error","kind":"fail","baselineState":"new",
  #|    "message":{"text":"月🌙, \"total\"\nsecond line","markdown":"**total**"},
  #|    "suppressions":[{"kind":"inSource","status":"accepted","justification":"fixture only"}],
  #|    "locations":[
  #|     {"physicalLocation":{"artifactLocation":{"index":0},"region":{"startLine":12,"startColumn":3,"endLine":12,"endColumn":9}}},
  #|     {"physicalLocation":{"artifactLocation":{"uri":"src/other.mbt"},"region":{"startLine":7}}}],
  #|    "fixes":[{"description":{"text":"remains in original"}}]},
  #|   {"ruleId":"R2","message":{"markdown":"=A1"},"baselineState":"unchanged"}]},
  #| {"tool":{"driver":{"name":"Other analyzer","rules":[{"id":"OTHER","name":"Different run"}]}},
  #|  "artifacts":[{"location":{"uri":"file:///retained/other.mbt"}}],
  #|  "results":[{"ruleIndex":0,"ruleId":"OTHER","message":{"text":"same index, different rule"},
  #|   "locations":[{"physicalLocation":{"artifactLocation":{"index":0,"uri":"file:///retained/other.mbt"},"region":{"startLine":1}}}]}]}
  #|]}

///|
async fn sarif_fixture(
  config : ExecutorConfig,
  source : Bytes,
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "sarif-results",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/sarif-results"
  @fs.mkdir(scratch, permission=0o700)
  @fs.write_file(
    scratch + "/findings.sarif",
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
test "SARIF resolves run-local rule and artifact indexes and keeps every primary location" {
  let document = parse_retained_json(sarif_example)
  let before = document.stringify()
  let (csv, runs, results, rows) = retained_sarif_csv(document)
  assert_eq((runs, results, rows), (2, 3, 4))
  let table = parse_retained_csv(csv)
  assert_eq(table.length(), 5)
  assert_eq(table[1], [
    "/runs/0/results/0", "/runs/0/results/0/locations/0", "Local analyzer", "R1",
    "First rule", "error", "warning", "fail", "new", "月🌙, \"total\"\nsecond line",
    "**total**", "[{\"kind\":\"inSource\",\"status\":\"accepted\",\"justification\":\"fixture only\"}]",
    "src/checkout.mbt", "%SRCROOT%", "12", "3", "12", "9",
  ])
  assert_eq(table[2][1], "/runs/0/results/0/locations/1")
  assert_eq(table[2][12], "src/other.mbt")
  assert_eq(table[3][1], "")
  assert_eq(table[3][3], "R2")
  assert_eq(table[3][5], "")
  assert_eq(table[3][6], "note")
  assert_eq(table[3][10], "=A1")
  assert_eq(table[4][3], "OTHER")
  assert_eq(table[4][12], "file:///retained/other.mbt")
  for row in table[1:] {
    let original = retained_json_at(document, row[0])
    assert_true(original is Object(_))
    if !row[1].is_empty() {
      assert_true(retained_json_at(document, row[1]) is Object(_))
    }
  }
  assert_eq(document.stringify(), before)
  let (_, empty_runs, empty_results, empty_rows) = retained_sarif_csv(
    parse_retained_json("{\"version\":\"2.1.0\",\"runs\":[]}"),
  )
  assert_eq((empty_runs, empty_results, empty_rows), (0, 0, 0))
}

///|
test "SARIF reports unsupported or unresolved evidence and bounds repeated rows" {
  let wrap = fn(result : String) -> Json raise {
    parse_retained_json(
      "{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"test\",\"rules\":[{\"id\":\"R1\"}]}},\"results\":[" +
      result +
      "]}]}",
    )
  }
  for
    result in [
      "{\"ruleIndex\":1,\"message\":{\"text\":\"bad index\"}}", "{\"ruleIndex\":0,\"ruleId\":\"R2\",\"message\":{\"text\":\"mismatch\"}}",
      "{\"rule\":{},\"message\":{\"text\":\"extension\"}}", "{\"message\":{\"id\":\"external-message\"}}",
      "{\"message\":{\"text\":\"bad artifact\"},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"index\":0}}}]}",
    ] {
    try retained_sarif_csv(wrap(result)) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  for
    document in [
      "{\"version\":\"2.0.0\",\"runs\":[]}", "{\"version\":\"2.1.0\",\"runs\":null}",
      "{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"test\"}}}]}",
    ] {
    try retained_sarif_csv(parse_retained_json(document)) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let oversized : Json = {
    "version": "2.1.0",
    "runs": [
      {
        "tool": { "driver": { "name": "test" } },
        "results": [
          {
            "message": { "text": "x".repeat(16000).to_json() },
            "locations": Array::make(70, ({} : Json)).to_json(),
          },
        ],
      },
    ],
  }
  try retained_sarif_csv(oversized) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "SARIF API binds CSV and original receipt while leaving artifacts untouched" {
  let (config, _) = test_executor_config()
  let source = @utf8.encode(sarif_example)
  let binding = sarif_fixture(config, source)
  let receipt_path = config.retention_root + "/sarif-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let table = tabulate_retained_sarif(binding, "findings.sarif", config)
  assert_eq((table.run_count, table.result_count, table.row_count), (2, 3, 4))
  assert_eq(
    table.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(source)),
  )
  assert_eq(
    table.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(table.csv))),
  )
  assert_eq(table.candidate_size_bytes, @utf8.encode(table.csv).length())
  assert_eq(retained_json_at(table.context(), "/binding"), binding.to_json())
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/sarif-results/findings.sarif").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  try
    tabulate_retained_sarif(
      { ..binding, command_digest: "d".repeat(64), },
      "findings.sarif",
      config,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(config.scratch_root + "/sarif-results/findings.sarif", b"{}")
  try
    tabulate_retained_sarif(binding, "findings.sarif", config) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled SARIF browser exports repeatably and reopens result through source pointer" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI")
  }
  let (config, _) = test_executor_config()
  let binding = sarif_fixture(config, @utf8.encode(sarif_example))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let (code, output, errors) = @process.collect_output(
    executable,
    ["sarif-csv", "findings.sarif"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let table = parse_retained_csv(output.text())
  assert_eq(table.length(), 5)
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/result_count"), (3 : Json))
  assert_eq(retained_json_at(context, "/row_count"), (4 : Json))
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())).to_json(),
  )
  let (again, repeated, repeated_context) = @process.collect_output(
    executable,
    ["sarif-csv", "findings.sarif"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(repeated.binary(), output.binary())
  assert_eq(repeated_context.binary(), errors.binary())
  let (found, drillback, _) = @process.collect_output(
    executable,
    ["json", "findings.sarif", "--pointer", table[4][0], "--value"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(found, 0)
  assert_eq(
    @json.parse(drillback.text()),
    retained_json_at(parse_retained_json(sarif_example), table[4][0]),
  )
  for
    args in [
      ["sarif-csv"],
      ["sarif-csv", "findings.sarif", "--json"],
      ["sarif-csv", "missing.sarif"],
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
  let bad = sarif_example.replace(
    old="\"ruleId\":\"OTHER\"",
    new="\"ruleId\":\"CONFLICT\"",
  )
  let (bad_config, _) = test_executor_config()
  let bad_binding = sarif_fixture(bad_config, @utf8.encode(bad))
  let (bad_config_path, bad_binding_path) = write_artifact_cli_inputs(
    bad_config, bad_binding,
  )
  let (failed, empty, refusal) = @process.collect_output(
    executable,
    ["sarif-csv", "findings.sarif"],
    extra_env={ "MOONFORT_EXECUTOR_CONFIG": bad_config_path },
    stdin=@process.redirect_from_file(bad_binding_path),
  )
  assert_true(failed != 0)
  assert_eq(empty.binary(), b"")
  assert_true(refusal.text().contains("Artifact browse refused"))
  if @env.get_env_var("MOONFORT_SARIF_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("findings.sarif", @utf8.encode(sarif_example)),
        ("findings.csv", output.binary()),
        ("findings.context.json", errors.binary()),
        ("drilled-result.json", drillback.binary()),
        (
          "receipt-binding.json",
          @utf8.encode(binding.to_json().stringify() + "\n"),
        ),
        ("invalid-later.sarif", @utf8.encode(bad)),
        ("invalid-later.stdout", empty.binary()),
        ("invalid-later.stderr", refusal.binary()),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
}
