///|
let har_example : String =
  #|{"log":{"version":"1.2","creator":{"name":"Synthetic portable example","version":"1"},"entries":[
  #| {"pageref":"launch","startedDateTime":"2026-10-13T11:00:01.000Z","time":85,
  #|  "request":{"method":"GET","url":"https://example.test/summary?q=moon","httpVersion":"HTTP/1.1","headersSize":-1,"bodySize":0,"queryString":[{"name":"q","value":"moon"}],"headers":[{"name":"Authorization","value":"private-header-marker"}],"cookies":[{"name":"session","value":"private-cookie-marker"}]},
  #|  "response":{"status":200,"statusText":"OK","httpVersion":"HTTP/1.1","headers":[],"cookies":[],"redirectURL":"","headersSize":-1,"bodySize":120,"content":{"size":240,"mimeType":"application/json","text":"private-response-marker"}},"cache":{},
  #|  "timings":{"blocked":0,"dns":0,"connect":20,"send":1,"wait":60,"receive":4,"ssl":10}},
  #| {"startedDateTime":"2026-10-13T13:00:00.000+02:00","time":170,
  #|  "request":{"method":"POST","url":"https://example.test/search?q=月,\"moon\"","httpVersion":"HTTP/1.1","headersSize":-1,"headers":[],"cookies":[],"queryString":[],"bodySize":-1,"postData":{"mimeType":"text/plain","text":"private-post-marker"}},
  #|  "response":{"status":503,"statusText":"Service Unavailable","httpVersion":"HTTP/1.1","headers":[],"cookies":[],"redirectURL":"","headersSize":-1,"bodySize":-1,"content":{"size":0,"mimeType":"text/plain"}},"cache":{},
  #|  "timings":{"dns":-1,"connect":-1,"send":5,"wait":150,"receive":5,"ssl":-1}},
  #| {"startedDateTime":"2026-10-13T11:00:02Z","time":0,
  #|  "request":{"method":"GET","url":"https://example.test/cached","httpVersion":"HTTP/1.1","headersSize":-1,"headers":[],"cookies":[],"queryString":[],"bodySize":0},
  #|  "response":{"status":304,"statusText":"Not Modified","httpVersion":"HTTP/1.1","headers":[],"cookies":[],"redirectURL":"","headersSize":-1,"bodySize":0,"content":{"size":240,"mimeType":"application/json"}},"cache":{},
  #|  "timings":{"send":0,"wait":0,"receive":0}}
  #|]}}

///|
test "HAR exact integer lexemes refuse fractions hidden by binary64 rounding" {
  for
    old in [
      "\"bodySize\":0", "\"bodySize\":120", "\"size\":240", "\"status\":200",
    ] {
    let key = old.split(":").collect()[0].to_owned()
    for
      literal in [
        "1.00000000000000001", "200.000000000000001", "1e-9999", "-1e-9999", "9007199254740991.1",
        "9007199254740992",
      ] {
      let input = har_example.replace_all(old~, new=key + ":" + literal)
      assert_true(
        (try? retained_har_csv(parse_retained_json(input), method="excluded"))
        is Err(_),
        msg=key + ":" + literal,
      )
    }
  }
  for literal in ["-1.00000000000000001", "-0.99999999999999999", "-1e-9999"] {
    for
      (old, key) in [
        ("\"bodySize\":-1", "bodySize"),
        ("\"dns\":-1", "dns"),
        ("\"ssl\":-1", "ssl"),
      ] {
      let input = har_example.replace_all(
        old~,
        new="\"" + key + "\":" + literal,
      )
      assert_true(
        (try? retained_har_csv(parse_retained_json(input))) is Err(_),
        msg=key + ":" + literal,
      )
    }
  }
  for
    (literal, expected) in [
      ("0", Some(0L)),
      ("-0.000e-9999", Some(0L)),
      ("100e-2", Some(1L)),
      ("1.2300e2", Some(123L)),
      ("1E+3", Some(1000L)),
      ("0.001e3", Some(1L)),
      ("9007199254740991.000", Some(9007199254740991L)),
      ("900719925474099100e-2", Some(9007199254740991L)),
      ("-100e-2", Some(-1L)),
      ("0.000e999999999999999999999", Some(0L)),
      ("1e999999999999999999999", None),
      ("1e-999999999999999999999", None),
      ("9007199254740991.1", None),
      ("1.00000000000000001", None),
    ] {
    assert_eq(har_exact_integer(literal), expected, msg=literal)
  }
  let input = har_example
    .replace_all(
      old="\"bodySize\":120",
      new="\"bodySize\":900719925474099100e-2",
    )
    .replace_all(old="\"status\":200", new="\"status\":2.000e2")
    .replace_all(old="\"dns\":-1", new="\"dns\":-100e-2")
  let rows = parse_retained_csv(
    retained_har_csv(parse_retained_json(input), status=200).0,
  )
  assert_eq(rows[1][5], "2.000e2")
  assert_eq(rows[1][19], "900719925474099100e-2")
}

///|
test "HAR preserves source locators raw labels unknowns and TLS subset semantics" {
  let document = parse_retained_json(har_example)
  let before = document.stringify()
  let (csv, total, rows) = retained_har_csv(document)
  assert_eq((total, rows), (3, 3))
  let table = parse_retained_csv(csv)
  assert_eq(table[1], [
    "/log/entries/0", "launch", "2026-10-13T11:00:01.000Z", "GET", "https://example.test/summary?q=moon",
    "200", "application/json", "85", "0", "0", "20", "1", "60", "4", "10", "85",
    "0", "0", "0", "120", "240",
  ])
  assert_eq(table[2], [
    "/log/entries/1", "", "2026-10-13T13:00:00.000+02:00", "POST", "https://example.test/search?q=月,\"moon\"",
    "503", "text/plain", "170", "", "", "", "5", "150", "5", "", "160", "10", "3",
    "", "", "0",
  ])
  assert_eq(table[3][8], "")
  assert_eq(table[3][11], "0")
  assert_eq(table[3][17], "3")
  assert_false(csv.contains("private-"))
  for row in table[1:] {
    assert_true(retained_json_at(document, row[0]) is Object(_))
  }
  assert_eq(document.stringify(), before)
}

///|
test "HAR exact filters combine inclusively and empty results retain a header" {
  let document = parse_retained_json(har_example)
  let (csv, total, count) = retained_har_csv(
    document,
    method="POST",
    status=503,
    minimum_ms=170.0,
  )
  assert_eq((total, count), (3, 1))
  assert_eq(parse_retained_csv(csv)[1][0], "/log/entries/1")
  assert_eq(retained_har_csv(document, method="post").2, 0)
  assert_eq(retained_har_csv(document, minimum_ms=170.001).2, 0)
  assert_eq(retained_har_csv(document, method="GET").2, 2)
  assert_eq(
    parse_retained_csv(retained_har_csv(document, status=404).0).length(),
    1,
  )
  let empty = parse_retained_json(
    "{\"log\":{\"version\":\"1.2\",\"entries\":[]}}",
  )
  assert_eq(retained_har_csv(empty).1, 0)
  for threshold in [-1.0, 1.0 / 0.0, 0.0 / 0.0] {
    assert_true(
      (try? retained_har_csv(document, minimum_ms=threshold)) is Err(_),
    )
  }
  for status in [-1, 1000] {
    assert_true((try? retained_har_csv(document, status~)) is Err(_))
  }
  let zero_status = parse_retained_json(
    har_example.replace_all(old="\"status\":304", new="\"status\":0"),
  )
  assert_eq(retained_har_csv(zero_status, status=0).2, 1)
}

///|
test "HAR validates excluded entries and refuses malformed or unbounded metrics" {
  for
    (old, replacement) in [
      ("\"version\":\"1.2\"", "\"version\":\"1.1\""),
      ("\"time\":0", "\"time\":-1"),
      ("\"send\":0", "\"send\":-1"),
      ("\"send\":0", "\"send\":null"),
      ("\"send\":0", "\"missing_send\":0"),
      ("\"dns\":-1", "\"dns\":-2"),
      ("\"status\":304", "\"status\":304.5"),
      ("\"status\":304", "\"status\":1000"),
      ("\"size\":240", "\"size\":-1"),
      ("\"bodySize\":120", "\"bodySize\":9007199254740992"),
      ("\"bodySize\":120", "\"bodySize\":1.5"),
      ("\"wait\":150", "\"wait\":1e999"),
      ("\"mimeType\":\"text/plain\"", "\"mimeType\":null"),
      ("\"url\":\"https://example.test/cached\"", "\"url\":\"\""),
    ] {
    let input = har_example.replace_all(old~, new=replacement)
    assert_true(
      (try? retained_har_csv(parse_retained_json(input), method="absent"))
      is Err(_),
      msg=replacement,
    )
  }
  assert_true(
    (try? parse_retained_json(
      har_example.replace_all(old="\"time\":85", new="\"time\":85,\"time\":85"),
    ))
    is Err(_),
  )
  let entry = retained_json_at(
    parse_retained_json(har_example),
    "/log/entries/0",
  )
  let wrap = fn(entries : Array[Json]) -> Json {
    { "log": { "version": "1.2", "entries": entries.to_json() } }
  }
  assert_true((try? retained_har_csv(wrap(Array::make(5001, entry)))) is Err(_))
  let large = parse_retained_json(
    har_example.replace_all(
      old="https://example.test/summary?q=moon",
      new="x".repeat(16384),
    ),
  )
  let large_entry = retained_json_at(large, "/log/entries/0")
  assert_true(
    (try? retained_har_csv(wrap(Array::make(70, large_entry)))) is Err(_),
  )
  let overflow = har_example
    .replace_all(old="\"connect\":20", new="\"connect\":1e308")
    .replace_all(old="\"wait\":60", new="\"wait\":1e308")
  assert_true((try? retained_har_csv(parse_retained_json(overflow))) is Err(_))
}

///|
async test "HAR retained API binds exact bytes and selection without changing authority or source" {
  let (config, _) = test_executor_config()
  let source = @utf8.encode("\u{feff}" + har_example + "\n")
  let binding = run_search_fixture(config, [("logs/session.har", source)])
  let receipt_path = config.retention_root + "/run-search.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let result = tabulate_retained_har(
    binding,
    "logs/session.har",
    config,
    status=503,
  )
  assert_eq((result.entry_count, result.row_count), (3, 1))
  assert_eq(
    result.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(source)),
  )
  assert_eq(
    result.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(result.csv))),
  )
  assert_eq(result.candidate_size_bytes, @utf8.encode(result.csv).length())
  assert_eq(
    tabulate_retained_har(binding, "logs/session.har", config, status=503).context(),
    result.context(),
  )
  assert_false(result.context().stringify().contains("example.test"))
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/run-search/logs/session.har").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  assert_true(
    (try? tabulate_retained_har(
      { ..binding, command_digest: "d".repeat(64), },
      "logs/session.har",
      config,
    ))
    is Err(_),
  )
  assert_true(
    (try? tabulate_retained_har(binding, "missing.har", config)) is Err(_),
  )
  assert_true(
    (try? tabulate_retained_har(binding, "../session.har", config)) is Err(_),
  )
  @fs.write_file(config.scratch_root + "/run-search/logs/session.har", b"{}")
  assert_true(
    (try? tabulate_retained_har(binding, "logs/session.har", config)) is Err(_),
  )
}

///|
async test "compiled HAR journey connects inventory selection CSV reopen and original JSON drillback" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("compiled HAR reader required")
  }
  let (config, _) = test_executor_config()
  let source = @utf8.encode(har_example + "\n")
  let binding = run_search_fixture(config, [("logs/session.har", source)])
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let call = async fn(args : Array[String]) {
    @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
  }
  let (listed, inventory, _) = call(["list", "--contains", ".har", "--json"])
  assert_eq(listed, 0)
  let files : RetentionArtifactList = @json.from_json(
    @json.parse(inventory.text()),
  )
  assert_eq(files.files.length(), 1)
  let path = files.files[0].relative_path
  let (status, csv, context) = call([
    "har-csv", path, "--status", "503", "--minimum-ms", "100",
  ])
  assert_eq(status, 0)
  let metadata = @json.parse(context.text())
  assert_eq(
    retained_json_at(metadata, "/candidate_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(csv.binary())).to_json(),
  )
  let saved = config.scratch_root + "/requests.csv"
  @fs.write_file(saved, csv.binary(), create_mode=CreateNew)
  let rows = parse_retained_csv(@fs.read_file(saved).text())
  assert_eq(rows.length(), 2)
  assert_eq(rows[1][0], "/log/entries/1")
  let (drill_code, drillback, _) = call([
    "json",
    path,
    "--pointer",
    rows[1][0] + "/response/status",
    "--value",
  ])
  assert_eq(drill_code, 0)
  assert_eq(@json.parse(drillback.text()), 503)
  let (revised_code, revised, revised_context) = call([
    "har-csv", path, "--method", "GET",
  ])
  assert_eq(revised_code, 0)
  assert_eq(parse_retained_csv(revised.text()).length(), 3)
  let (again, repeated, repeated_context) = call([
    "har-csv", path, "--status", "503", "--minimum-ms", "100",
  ])
  assert_eq(again, 0)
  assert_eq(repeated.binary(), csv.binary())
  assert_eq(repeated_context.binary(), context.binary())
  for
    args in [
      ["har-csv"],
      ["har-csv", path, "--json"],
      ["har-csv", path, "--minimum-ms", "NaN"],
      ["har-csv", path, "--minimum-ms", "-1"],
      ["har-csv", path, "--status", "1000"],
      ["har-csv", path, "--method", "GET", "--method", "GET"],
    ] {
    let (code, output, _) = call(args)
    assert_true(code != 0)
    assert_eq(output.binary(), b"")
  }
  if @env.get_env_var("MOONFORT_HAR_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("session.har", source),
        ("inventory.json", inventory.binary()),
        ("slow-errors.csv", csv.binary()),
        ("slow-errors.context.json", context.binary()),
        ("revised-get.csv", revised.binary()),
        ("revised-get.context.json", revised_context.binary()),
        ("drillback.json", drillback.binary()),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  assert_eq(
    @fs.read_file(config.scratch_root + "/run-search/" + path).binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "compiled HAR late invalid excluded entry refuses with no partial artifact bytes" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("compiled HAR reader required")
  }
  let (config, _) = test_executor_config()
  let source = @utf8.encode(
    har_example.replace_all(old="\"send\":0", new="\"send\":-1"),
  )
  let binding = run_search_fixture(config, [("bad.har", source)])
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let (code, output, _) = @process.collect_output(
    executable,
    ["har-csv", "bad.har", "--status", "503"],
    extra_env={ "MOONFORT_EXECUTOR_CONFIG": config_path },
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_true(code != 0)
  assert_eq(output.binary(), b"")
}

///|
async test "HAR retained reader refuses oversized input and provenance context" {
  let (config, _) = test_executor_config()
  let binding = run_search_fixture(config, [
    ("large.har", Bytes::make(1_048_577, 32)),
    ("small.har", @utf8.encode(har_example)),
  ])
  assert_true(
    (try? tabulate_retained_har(binding, "large.har", config)) is Err(_),
  )
  let limited = {
    ..config,
    limits: { ..config.limits, max_protocol_bytes: 4096, },
  }
  try
    tabulate_retained_har(
      binding,
      "small.har",
      limited,
      method="x".repeat(4000),
    )
  catch {
    error =>
      assert_true(error.to_string().contains("context exceeds protocol budget"))
  } noraise {
    _ => fail("expected full context refusal")
  }
}

///|
async test "compiled HAR rejects rounded integer and sentinel lexemes before emitting CSV" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("compiled HAR reader required")
  }
  for
    (old, replacement) in [
      ("\"bodySize\":120", "\"bodySize\":1.00000000000000001"),
      ("\"bodySize\":120", "\"bodySize\":9007199254740991.1"),
      ("\"status\":200", "\"status\":200.000000000000001"),
      ("\"size\":240", "\"size\":1e-9999"),
      ("\"bodySize\":-1", "\"bodySize\":-1.00000000000000001"),
      ("\"send\":1", "\"send\":-1e-9999"),
    ] {
    let (config, _) = test_executor_config()
    let bytes = @utf8.encode(har_example.replace_all(old~, new=replacement))
    let binding = run_search_fixture(config, [("rounded.har", bytes)])
    let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
    let (code, output, _) = @process.collect_output(
      executable,
      ["har-csv", "rounded.har"],
      extra_env={ "MOONFORT_EXECUTOR_CONFIG": config_path },
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(code != 0, msg=replacement)
    assert_eq(output.binary(), b"")
  }
}
