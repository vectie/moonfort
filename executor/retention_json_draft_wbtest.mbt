///|
test "JSON draft edits ordinary objects arrays and escaped keys without aliasing" {
  let original = "{\"name\":\"Maple\",\"rows\":[{\"id\":9007199254740993,\"note\":\"draft\"},{\"id\":2}],\"a/b\":{\"~tag\":false},\"01\":0}"
  let root = parse_retained_json(original)
  let recipe = b"{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"/name\",\"value\":\"Maple reviewed\"},{\"op\":\"remove\",\"pointer\":\"/rows/0/note\"},{\"op\":\"set\",\"pointer\":\"/rows/-\",\"value\":{\"id\":3,\"latency\":1.2300e+4}},{\"op\":\"remove\",\"pointer\":\"/rows/1\"},{\"op\":\"set\",\"pointer\":\"/a~1b/~0tag\",\"value\":null},{\"op\":\"set\",\"pointer\":\"/01\",\"value\":-0},{\"op\":\"set\",\"pointer\":\"/\",\"value\":\"月🌙\"}]}"
  let edited = retained_apply_edits(root, retained_json_edits(recipe))
  assert_eq(root.stringify(), original)
  assert_eq(
    retained_json_at(edited, "/rows/0/id").stringify(),
    "9007199254740993",
  )
  assert_eq(
    retained_json_at(edited, "/rows/1/latency").stringify(),
    "1.2300e+4",
  )
  assert_eq(retained_json_at(edited, "/a~1b/~0tag"), (null : Json))
  assert_eq(retained_json_at(edited, "/01").stringify(), "-0")
  assert_eq(retained_json_at(edited, "/"), ToJson::to_json("月🌙"))
  try retained_json_at(edited, "/rows/0/note") |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try retained_json_at(edited, "/rows/2") |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let root_edit = retained_json_edits(
    b"{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"\",\"value\":[]},{\"op\":\"set\",\"pointer\":\"/-\",\"value\":null},{\"op\":\"set\",\"pointer\":\"/0\",\"value\":1e400}]}",
  )
  assert_eq(retained_apply_edits(root, root_edit).stringify(), "[1e400]")
  assert_eq(root.stringify(), original)
}

///|
test "JSON draft recipe errors are explicit and no partial candidate escapes" {
  let original = "{\"rows\":[1,2],\"scalar\":null}"
  let root = parse_retained_json(original)
  for
    recipe in [
      "{}", "[]", "{\"version\":2,\"operations\":[]}", "{\"version\":1.00000000000000001,\"operations\":[{\"op\":\"set\",\"pointer\":\"\",\"value\":null}]}",
      "{\"version\":1,\"operations\":[]}", "{\"version\":1,\"operations\":[{\"op\":\"copy\",\"pointer\":\"/x\",\"value\":1}]}",
      "{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"/x\"}]}", "{\"version\":1,\"operations\":[{\"op\":\"remove\",\"pointer\":\"/x\",\"value\":null}]}",
      "{\"version\":1,\"operations\":[{\"op\":\"remove\",\"pointer\":\"\"}]}", "{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"/x\",\"value\":{\"a\":1,\"\\u0061\":2}}]}",
      "{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"/x\",\"value\":1,\"extra\":true}]}",
      "{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"/~2\",\"value\":1}]}",
    ] {
    try retained_json_edits(@utf8.encode(recipe)) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  for
    pointer in [
      "/absent/child", "/rows/01", "/rows/2", "/rows/-/id", "/scalar/a", "/rows/999999999999999999999",
    ] {
    let recipe : Json = {
      "version": 1,
      "operations": [
        { "op": "set", "pointer": "/temporary", "value": 1 },
        { "op": "set", "pointer": ToJson::to_json(pointer), "value": 2 },
      ],
    }
    let edits = retained_json_edits(@utf8.encode(recipe.stringify()))
    try retained_apply_edits(root, edits) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
    assert_eq(root.stringify(), original)
  }
  for pointer in ["/absent", "/rows/-", "/rows/2"] {
    let recipe : Json = {
      "version": 1,
      "operations": [{ "op": "remove", "pointer": ToJson::to_json(pointer) }],
    }
    try
      retained_apply_edits(
        root,
        retained_json_edits(@utf8.encode(recipe.stringify())),
      )
      |> ignore
    catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
}

///|
test "JSON draft bounds recipe operations and aggregate candidate" {
  try retained_json_edits(b"\xff") |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try retained_json_edits(Bytes::make(65_537, 32)) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let op : Json = { "op": "set", "pointer": "/-", "value": 1 }
  let too_many : Json = {
    "version": 1,
    "operations": Json::array(Array::make(101, op)),
  }
  try retained_json_edits(@utf8.encode(too_many.stringify())) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let append : Json = {
    "op": "set",
    "pointer": "/-",
    "value": ToJson::to_json("x".repeat(20_000)),
  }
  // An ordinary-size edit applied to a source under 1 MiB must still obey
  // the aggregate candidate budget.
  let one : Json = { "version": 1, "operations": [append] }
  let edits = retained_json_edits(@utf8.encode(one.stringify()))
  let large = Json::array(Array::make(52, ToJson::to_json("y".repeat(20_000))))
  assert_true(@utf8.encode(large.stringify()).length() < 1_048_576)
  try retained_apply_edits(large, edits) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let many = Json::array(Array::make(19_999, (0 : Json)))
  let append_one : Json = { "version": 1, "operations": [op] }
  try
    retained_apply_edits(
      many,
      retained_json_edits(@utf8.encode(append_one.stringify())),
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let nested : Json = {
    "version": 1,
    "operations": [
      {
        "op": "set",
        "pointer": ToJson::to_json("/a".repeat(62) + "/new"),
        "value": [[1]],
      },
    ],
  }
  let deep = parse_retained_json("{\"a\":".repeat(62) + "{}" + "}".repeat(62))
  try
    retained_apply_edits(
      deep,
      retained_json_edits(@utf8.encode(nested.stringify())),
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  let maximum : Json = {
    "version": 1,
    "operations": Json::array(Array::make(100, op)),
  }
  assert_eq(
    retained_apply_edits(
      Json::array([]),
      retained_json_edits(@utf8.encode(maximum.stringify())),
    ).stringify(),
    "[" + "1,".repeat(99) + "1]",
  )
}

///|
async test "retained JSON draft binds hashes and preserves original receipt and files" {
  let (config, _) = test_executor_config()
  let source = b"{\"status\":\"draft\",\"items\":[] }\n"
  let recipe = b"{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"/status\",\"value\":\"reviewed draft\"},{\"op\":\"set\",\"pointer\":\"/items/-\",\"value\":null}]}\n"
  let binding = json_fixture(config, source)
  let record_path = config.retention_root + "/json-results.json"
  let receipt = @fs.read_file(record_path).binary()
  let draft = draft_retained_json(binding, "report.json", config, recipe)
  let bytes = @utf8.encode(draft.value.stringify() + "\n")
  assert_eq(draft.binding, binding)
  assert_eq(draft.operation_count, 2)
  assert_eq(
    draft.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(source)),
  )
  assert_eq(
    draft.recipe_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(recipe)),
  )
  assert_eq(
    draft.candidate_fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
  )
  assert_eq(draft.candidate_size_bytes, bytes.length())
  assert_eq(
    retained_json_at(draft.context(), "/derived_candidate"),
    (true : Json),
  )
  assert_eq(@fs.read_file(record_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/json-results/report.json").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  try
    draft_retained_json(
      { ..binding, workspace_id: "wrong", },
      "report.json",
      config,
      recipe,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(config.scratch_root + "/json-results/report.json", b"{}")
  try
    draft_retained_json(binding, "report.json", config, recipe) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled JSON edit CLI integrates local recipe and reusable candidate" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI for the compiled JSON edit journey")
  }
  let (config, _) = test_executor_config()
  let source = "{\"release\":\"Maple\",\"rows\":[{\"id\":9007199254740993,\"status\":\"draft\",\"scratch_note\":\"remove before reuse\"},{\"id\":2,\"status\":\"pending\"}]}\n"
  let recipe = "{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"/rows/0/status\",\"value\":\"ready for review\"},{\"op\":\"remove\",\"pointer\":\"/rows/0/scratch_note\"},{\"op\":\"set\",\"pointer\":\"/rows/-\",\"value\":{\"id\":3,\"latency\":1.2300e+4,\"note\":\"月🌙 added locally\"}},{\"op\":\"set\",\"pointer\":\"/editor_note\",\"value\":\"Candidate only; review before accepting\"}]}\n"
  let binding = json_fixture(config, @utf8.encode(source))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let recipe_path = config.scratch_root + "/local-edits.json"
  @fs.write_file(recipe_path, recipe, create_mode=CreateNew)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let args = ["edit-json", "report.json", "--recipe", recipe_path]
  let receipt_path = config.retention_root + "/json-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let (code, output, errors) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  let candidate = parse_retained_json(output.text())
  let context = @json.parse(errors.text())
  assert_eq(
    retained_json_at(candidate, "/rows/0/id").stringify(),
    "9007199254740993",
  )
  assert_eq(
    retained_json_at(candidate, "/rows/0/status"),
    ToJson::to_json("ready for review"),
  )
  assert_eq(
    retained_json_at(candidate, "/rows/2/latency").stringify(),
    "1.2300e+4",
  )
  try retained_json_at(candidate, "/rows/0/scratch_note") |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  assert_eq(retained_json_at(context, "/binding"), binding.to_json())
  assert_eq(
    retained_json_at(context, "/source_file/fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(source))),
    ),
  )
  assert_eq(
    retained_json_at(context, "/recipe_fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(recipe))),
    ),
  )
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())),
    ),
  )
  assert_eq(
    retained_json_at(context, "/candidate_size_bytes"),
    ToJson::to_json(output.binary().length()),
  )
  let reopened = config.scratch_root + "/candidate.json"
  @fs.write_file(reopened, output.binary(), create_mode=CreateNew)
  assert_eq(
    parse_retained_json(@fs.read_file(reopened).text()).stringify(),
    candidate.stringify(),
  )
  let (again, second, _) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(second.binary(), output.binary())
  for
    bad_args in [
      ["edit-json", "report.json"],
      ["edit-json", "report.json", "--recipe", recipe_path, "--json"],
      [
        "edit-json", "report.json", "--recipe", recipe_path, "--recipe", recipe_path,
      ],
      [
        "edit-json", "report.json", "--recipe", recipe_path, "--pointer", "/rows",
      ],
      ["edit-json", "report.json", "--recipe", recipe_path + ".missing"],
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
  if @env.get_env_var("MOONFORT_JSON_DRAFT_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("original-report.json", @utf8.encode(source)),
        ("local-edits.json", @utf8.encode(recipe)),
        ("candidate.json", output.binary()),
        ("candidate.context.json", errors.binary()),
        (
          "receipt-binding.json",
          @utf8.encode(binding.to_json().stringify() + "\n"),
        ),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  // A later invalid operation emits no partial document and preserves evidence.
  @fs.write_file(
    recipe_path, "{\"version\":1,\"operations\":[{\"op\":\"set\",\"pointer\":\"/release\",\"value\":\"changed\"},{\"op\":\"remove\",\"pointer\":\"/missing\"}]}",
  )
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
