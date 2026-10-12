///|
test "CSV enrichment preserves source order exact keys and quoted lookup values" {
  let source = parse_retained_csv(
    "id,status\n01,open\n1,open\n01,recheck\n,unknown\nA,case\na,case\n x,space\n",
  )
  let lookup = parse_retained_csv(
    "id,owner,note\n01,月🌙,\"comma, quote \"\"ok\"\"\r\nsecond line\"\na,team,\nunused,nobody,\nx,trimmed,\n",
  )
  let (csv, columns, matched, unused) = enrich_csv_records(
    source,
    lookup,
    1,
    1,
    [3, 2],
    "ref_",
  )
  assert_eq(columns, [3, 2])
  assert_eq(matched, 3)
  assert_eq(unused, 2)
  let rows = parse_retained_csv(csv)
  assert_eq(rows[0], ["id", "status", "ref_note", "ref_owner"])
  assert_eq(rows[1], [
    "01", "open", "comma, quote \"ok\"\r\nsecond line", "月🌙",
  ])
  assert_eq(rows[2], ["1", "open", "", ""])
  assert_eq(rows[3], [
    "01", "recheck", "comma, quote \"ok\"\r\nsecond line", "月🌙",
  ])
  assert_eq(rows[4], ["", "unknown", "", ""])
  assert_eq(rows[5], ["A", "case", "", ""])
  assert_eq(rows[6], ["a", "case", "", "team"])
  assert_eq(rows[7], [" x", "space", "", ""])
  assert_eq(source[0], ["id", "status"])
  assert_eq(source[1], ["01", "open"])
  assert_eq(lookup[0], ["id", "owner", "note"])
}

///|
test "CSV enrichment supports header-only tables default columns and exact cells" {
  let source = parse_retained_csv("id,id\n9007199254740993,1.2300e+4\n")
  let lookup = parse_retained_csv("owner,key\n=SUM(A1:A2),9007199254740993\n")
  let (csv, columns, matched, unused) = enrich_csv_records(
    source,
    lookup,
    1,
    2,
    [],
    "",
  )
  assert_eq(columns, [1])
  assert_eq(matched, 1)
  assert_eq(unused, 0)
  assert_eq(parse_retained_csv(csv), [
    ["id", "id", "owner"],
    ["9007199254740993", "1.2300e+4", "=SUM(A1:A2)"],
  ])
  let (empty, _, empty_matches, empty_unused) = enrich_csv_records(
    parse_retained_csv("id\n"),
    lookup,
    1,
    2,
    [],
    "lookup_",
  )
  assert_eq(parse_retained_csv(empty), [["id", "lookup_owner"]])
  assert_eq(empty_matches, 0)
  assert_eq(empty_unused, 1)
  let (missing, _, _, _) = enrich_csv_records(
    source,
    parse_retained_csv("id,owner\n"),
    1,
    1,
    [],
    "lookup_",
  )
  assert_eq(parse_retained_csv(missing)[1], [
    "9007199254740993", "1.2300e+4", "",
  ])
}

///|
test "CSV enrichment rejects ambiguous lookup keys and unrepresentable selections" {
  let source = parse_retained_csv("id,name\n01,A\n")
  let lookup = parse_retained_csv("id,owner\n01,B\n")
  for text in ["id,owner\n01,A\n01,B\n", "id,owner\n,A\n"] {
    assert_true(
      (try? enrich_csv_records(
        source,
        parse_retained_csv(text),
        1,
        1,
        [],
        "lookup_",
      ))
      is Err(_),
    )
  }
  for
    (source_key, lookup_key, columns) in [
      (0, 1, []),
      (3, 1, []),
      (1, 0, []),
      (1, 3, []),
      (1, 1, [0]),
      (1, 1, [3]),
      (1, 1, [2, 2]),
    ] {
    assert_true(
      (try? enrich_csv_records(
        source, lookup, source_key, lookup_key, columns, "lookup_",
      ))
      is Err(_),
    )
  }
  assert_true(
    (try? enrich_csv_records(source, [["id"], ["01"]], 1, 1, [], "lookup_"))
    is Err(_),
  )
  assert_true(
    (try? enrich_csv_records(
      [Array::make(64, "h")],
      lookup,
      1,
      1,
      [],
      "lookup_",
    ))
    is Err(_),
  )
  for prefix in ["x".repeat(129), "\u{0}"] {
    assert_true(
      (try? enrich_csv_records(source, lookup, 1, 1, [], prefix)) is Err(_),
    )
  }
  // All inputs parse within their own bounds; the joined result can exceed its cap.
  let many = parse_retained_csv("id\n" + "01\n".repeat(100))
  let wide = parse_retained_csv("id,note\n01," + "x".repeat(16_000))
  assert_true(
    (try? enrich_csv_records(many, wide, 1, 1, [], "lookup_")) is Err(_),
  )
  let large_header = parse_retained_csv("id," + "x".repeat(16_384) + "\n")
  assert_true(
    (try? enrich_csv_records(source, large_header, 1, 1, [], "x")) is Err(_),
  )
}

///|
async test "CSV enrichment binds local reference and candidate hashes without writes" {
  let (config, _) = test_executor_config()
  let source = b"id,status\n01,open\n02,review\n"
  let lookup = b"id,owner\n01,Team A\n03,Team C\n"
  let binding = csv_fixture(config, source)
  let receipt_path = config.retention_root + "/table-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let result = enrich_retained_csv(
    binding,
    "checks.csv",
    config,
    lookup,
    source_key=1,
    lookup_key=1,
  )
  assert_eq(result.binding, binding)
  assert_eq(
    result.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(source)),
  )
  assert_eq(
    result.lookup_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(lookup)),
  )
  assert_eq(result.lookup_size_bytes, lookup.length())
  assert_eq(
    result.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(result.csv))),
  )
  assert_eq(result.candidate_size_bytes, @utf8.encode(result.csv).length())
  assert_eq(result.source_rows, 2)
  assert_eq(result.lookup_rows, 2)
  assert_eq(result.matched_rows, 1)
  assert_eq(result.unused_lookup_rows, 1)
  assert_eq(retained_json_at(result.context(), "/unmatched_rows"), (1 : Json))
  assert_eq(
    retained_json_at(result.context(), "/derived_candidate"),
    (true : Json),
  )
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/table-results/checks.csv").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  for
    invalid in [
      b"id,owner\n01\n",
      b"id,owner\n01,\xff\n",
      Bytes::make(1_048_577, 65),
    ] {
    assert_true(
      (try? enrich_retained_csv(
        binding,
        "checks.csv",
        config,
        invalid,
        source_key=1,
        lookup_key=1,
      ))
      is Err(_),
    )
  }
  assert_true(
    (try? enrich_retained_csv(
      { ..binding, command_digest: "d".repeat(64), },
      "checks.csv",
      config,
      lookup,
      source_key=1,
      lookup_key=1,
    ))
    is Err(_),
  )
  @fs.write_file(
    config.scratch_root + "/table-results/checks.csv",
    b"id,status\n01,NOPE\n02,review\n",
  )
  assert_true(
    (try? enrich_retained_csv(
      binding,
      "checks.csv",
      config,
      lookup,
      source_key=1,
      lookup_key=1,
    ))
    is Err(_),
  )
}

///|
async test "compiled CSV enrichment joins local ownership data and reopens reusable output" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI for compiled enrichment journey")
  }
  let (config, _) = test_executor_config()
  let source = "id,area,status\r\n01,docs,follow-up\r\n02,core,pass\r\n03,docs,follow-up\r\n04,ui,review\r\n"
  let lookup = "area,owner,note\r\ndocs,月🌙,\"quickstart, example\r\nthen review\"\r\ncore,Team Maple,\"confirm \"\"ready\"\"\"\r\nunused,Team Other,\r\n"
  let binding = csv_fixture(config, @utf8.encode(source))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let lookup_path = config.scratch_root + "/owners.csv"
  @fs.write_file(lookup_path, lookup, create_mode=CreateNew)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = [
    "enrich-csv", "checks.csv", "--lookup", lookup_path, "--source-key", "2", "--lookup-key",
    "1", "--lookup-columns", "2,3", "--prefix", "ref_",
  ]
  let receipt_path = config.retention_root + "/table-results.json"
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
    ["id", "area", "status", "ref_owner", "ref_note"],
    ["01", "docs", "follow-up", "月🌙", "quickstart, example\r\nthen review"],
    ["02", "core", "pass", "Team Maple", "confirm \"ready\""],
    ["03", "docs", "follow-up", "月🌙", "quickstart, example\r\nthen review"],
    ["04", "ui", "review", "", ""],
  ])
  let context = @json.parse(errors.text())
  assert_eq(retained_json_at(context, "/binding"), binding.to_json())
  assert_eq(
    retained_json_at(context, "/source_file/fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(source))).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/lookup_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(lookup))).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/candidate_size_bytes"),
    output.binary().length().to_json(),
  )
  assert_eq(retained_json_at(context, "/matched_rows"), (3 : Json))
  assert_eq(retained_json_at(context, "/unmatched_rows"), (1 : Json))
  assert_eq(retained_json_at(context, "/unused_lookup_rows"), (1 : Json))
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
      ["enrich-csv", "checks.csv"],
      ["enrich-csv", "checks.csv", "--lookup", lookup_path, "--source-key", "2"],
      args + ["--json"],
      args + ["--prefix", "duplicate_"],
      [
        "enrich-csv",
        "checks.csv",
        "--lookup",
        lookup_path + ".missing",
        "--source-key",
        "2",
        "--lookup-key",
        "1",
      ],
      [
        "enrich-csv",
        "checks.csv",
        "--lookup",
        config.scratch_root,
        "--source-key",
        "2",
        "--lookup-key",
        "1",
      ],
      [
        "enrich-csv", "checks.csv", "--lookup", lookup_path, "--source-key", "2",
        "--lookup-key", "1", "--lookup-columns", "",
      ],
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
  if @env.get_env_var("MOONFORT_CSV_ENRICHMENT_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("retained-checks.csv", @utf8.encode(source)),
        ("local-owners.csv", @utf8.encode(lookup)),
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
  @fs.write_file(lookup_path, "area,owner,note\ndocs,A,first\ndocs,B,second\n")
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
    @fs.read_file(config.scratch_root + "/table-results/checks.csv").text(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}
