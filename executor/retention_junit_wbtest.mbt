///|
let junit_example : String =
  #|<?xml version="1.0" encoding="UTF-8"?>
  #|<testsuites tests="99" failures="99">
  #|  <testsuite name="checkout &amp; billing" tests="99">
  #|    <properties><property name="revision" value="local-fixture"/></properties>
  #|    <testcase name="creates order" classname="Checkout" time="0.0100" file="tests/checkout.mbt" line="007"/>
  #|    <testcase name="月🌙, &quot;total&quot;" classname="Checkout" time="1.234567890123456789">
  #|      <failure type="Assertion" message="expected &lt;10&gt;&#10;retry"><![CDATA[assert expected <10> & got "11"
  #|second diagnostic line]]></failure>
  #|      <failure message="second check">value &#x1F319; &amp; tax</failure>
  #|    </testcase>
  #|    <testsuite name="network">
  #|      <testcase name="provider" time="1e-9"><error type="ConnectError" message="offline">local fixture only</error></testcase>
  #|      <testcase name="later"><skipped message="waiting"/></testcase>
  #|      <testcase name="disabled" status="notrun" result="suppressed"/>
  #|    </testsuite>
  #|    <testcase name="=A1"/>
  #|    <system-out>original output remains in XML</system-out>
  #|  </testsuite>
  #|</testsuites>

///|
async fn junit_fixture(
  config : ExecutorConfig,
  source : Bytes,
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "junit-results",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/junit-results"
  @fs.mkdir(scratch, permission=0o700)
  @fs.write_file(
    scratch + "/tests.xml",
    source,
    create_mode=CreateNew,
    permission=0o600,
  )
  let files = @sandbox.inventory_scratch(scratch, 32_000_000L).unwrap().entries.filter(entry => {
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
async test "JUnit API projects observed tests and binds source candidate and unchanged originals" {
  let (config, _) = test_executor_config()
  let source = @utf8.encode(junit_example)
  let binding = junit_fixture(config, source)
  let receipt_path = config.retention_root + "/junit-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let table = tabulate_retained_junit(binding, "tests.xml", config)
  assert_eq(
    (table.row_count, table.passed, table.failed, table.errors, table.skipped),
    (6, 2, 1, 1, 2),
  )
  let rows = parse_retained_csv(table.csv)
  assert_eq(rows[1], [
    "5", "checkout & billing", "Checkout", "creates order", "passed", "0.0100", "tests/checkout.mbt",
    "007", "", "", "0", "0", "0",
  ])
  assert_eq(rows[2][3], "月🌙, \"total\"")
  assert_eq(rows[2][5], "1.234567890123456789")
  assert_eq(rows[2][8], "expected <10>\nretry\nsecond check")
  assert_eq(rows[3][1], "checkout & billing / network")
  assert_eq(rows[6][3], "=A1")
  assert_eq(
    table.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(source)),
  )
  assert_eq(
    table.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(table.csv))),
  )
  assert_eq(table.candidate_size_bytes, @utf8.encode(table.csv).length())
  assert_eq(retained_json_at(table.context(), "/row_count"), (6 : Json))
  assert_eq(retained_json_at(table.context(), "/binding"), binding.to_json())
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/junit-results/tests.xml").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  try tabulate_retained_junit(binding, "missing.xml", config) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    tabulate_retained_junit(
      { ..binding, command_digest: "d".repeat(64), },
      "tests.xml",
      config,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(
    config.scratch_root + "/junit-results/tests.xml",
    b"<testsuite/>",
  )
  try tabulate_retained_junit(binding, "tests.xml", config) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "JUnit API refuses invalid later XML encoding oversize output and expired bindings" {
  let large = "<testsuite name='" +
    "s".repeat(16_000) +
    "'>" +
    "<testcase name='x'/>".repeat(70) +
    "</testsuite>"
  for
    source in [
      b"<testsuite>\xff</testsuite>",
      Bytes::make(1_048_577, 32),
      b"<testsuite><testcase name='ok'/><testcase name='broken'></testsuite>",
      @utf8.encode(large),
    ] {
    let (config, _) = test_executor_config()
    let binding = junit_fixture(config, source)
    try tabulate_retained_junit(binding, "tests.xml", config) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  let (config, _) = test_executor_config()
  let binding = junit_fixture(config, b"<testsuite/>")
  let empty = tabulate_retained_junit(binding, "tests.xml", config)
  assert_eq(empty.row_count, 0)
  assert_eq(parse_retained_csv(empty.csv).length(), 1)
  let path = config.retention_root + "/junit-results.json"
  let saved = load_retention_record(binding.retention_id, config)
  @fs.write_file(path, { ..saved, expires_at_ms: 1L, }.to_json().stringify())
  try tabulate_retained_junit(binding, "tests.xml", config) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled JUnit browser exports repeatable CSV and drills into original XML" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI")
  }
  let (config, _) = test_executor_config()
  let binding = junit_fixture(config, @utf8.encode(junit_example))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let receipt_path = config.retention_root + "/junit-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let (code, output, errors) = @process.collect_output(
    executable,
    ["junit-csv", "tests.xml"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let table = parse_retained_csv(output.text())
  assert_eq(table.length(), 7)
  assert_eq(table[2][0], "6")
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/row_count"), (6 : Json))
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())),
    ),
  )
  assert_eq(
    retained_json_at(context, "/source_file/fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(junit_example))),
    ),
  )
  let (again, repeated, repeated_context) = @process.collect_output(
    executable,
    ["junit-csv", "tests.xml"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(repeated.binary(), output.binary())
  assert_eq(repeated_context.binary(), errors.binary())
  let (found, drillback, _) = @process.collect_output(
    executable,
    [
      "search", "tests.xml", "--query", "月🌙", "--after-line", "5", "--limit",
      "1", "--json",
    ],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(found, 0)
  let detail = @json.parse(drillback.text())
  assert_eq(retained_json_at(detail, "/matches/0/line"), (6 : Json))
  assert_eq(
    retained_json_at(detail, "/file/fingerprint"),
    retained_json_at(context, "/source_file/fingerprint"),
  )
  let reopened = config.scratch_root + "/test-results.csv"
  @fs.write_file(reopened, output.binary(), create_mode=CreateNew)
  assert_eq(parse_retained_csv(@fs.read_file(reopened).text()), table)
  for
    args in [
      ["junit-csv"],
      ["junit-csv", "tests.xml", "--json"],
      ["junit-csv", "tests.xml", "--mapping", "unused"],
      ["junit-csv", "tests.xml", "extra"],
      ["junit-csv", "missing.xml"],
    ] {
    let (failed, empty, refusal) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(failed != 0)
    assert_eq(empty.binary(), b"")
    assert_true(refusal.text().contains("Artifact browse refused"))
  }
  if @env.get_env_var("MOONFORT_JUNIT_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("tests.xml", @utf8.encode(junit_example)),
        ("test-results.csv", output.binary()),
        ("test-results.context.json", errors.binary()),
        ("drilled-source-line.json", drillback.binary()),
        (
          "receipt-binding.json",
          @utf8.encode(binding.to_json().stringify() + "\n"),
        ),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/junit-results/tests.xml").text(),
    junit_example,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  let (bad_config, _) = test_executor_config()
  let bad_binding = junit_fixture(
    bad_config, b"<testsuite><testcase name='ok'/><testcase name='bad'></testsuite>",
  )
  let (bad_config_path, bad_binding_path) = write_artifact_cli_inputs(
    bad_config, bad_binding,
  )
  let (failed, empty, refusal) = @process.collect_output(
    executable,
    ["junit-csv", "tests.xml"],
    extra_env={ "MOONFORT_EXECUTOR_CONFIG": bad_config_path },
    stdin=@process.redirect_from_file(bad_binding_path),
  )
  assert_true(failed != 0)
  assert_eq(empty.binary(), b"")
  assert_true(refusal.text().contains("Artifact browse refused"))
  if @env.get_env_var("MOONFORT_JUNIT_EVIDENCE") is Some(root) {
    @fs.write_file(
      root + "/malformed.stdout",
      empty.binary(),
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      root + "/malformed.stderr",
      refusal.binary(),
      create_mode=CreateOrTruncate,
    )
  }
}
