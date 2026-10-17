///|
test "retained JSON preflight preserves the 64-container limit" {
  validate_retained_json_syntax("[".repeat(64) + "0" + "]".repeat(64))
  try
    validate_retained_json_syntax("[".repeat(65) + "0" + "]".repeat(65))
  catch {
    _ => ()
  } noraise {
    _ => fail("expected nesting refusal")
  }
  assert_eq(parse_retained_json("[\"[[[[[\\\"{}\"]"), (["[[[[[\"{}"] : Json))
}

///|
async fn json_fixture(
  config : ExecutorConfig,
  bytes : Bytes,
) -> RetentionArtifactBinding {
  let binding : RetentionArtifactBinding = {
    protocol_version: 1,
    retention_id: "json-results",
    workspace_id: "book",
    approval_digest: "b".repeat(64),
    command_digest: "c".repeat(64),
  }
  let scratch = config.scratch_root + "/json-results"
  @fs.mkdir(scratch, permission=0o700)
  @fs.write_file(
    scratch + "/report.json",
    bytes,
    create_mode=CreateNew,
    permission=0o600,
  )
  let entries = @sandbox.inventory_scratch(scratch, 32_000_000L).unwrap().entries.filter(entry => {
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
      entries,
      config,
    ),
  )
  binding
}

///|
test "retained JSON exact pointers and number spellings" {
  let source = "{\"\":{\"a/b\":{\"~key\":[null,true,false,9007199254740993,1.2300e+4,-0,1e400]}}}"
  let root = parse_retained_json(source)
  assert_eq(
    retained_json_at(root, "//a~1b/~0key/3").stringify(),
    "9007199254740993",
  )
  assert_eq(retained_json_at(root, "//a~1b/~0key/4").stringify(), "1.2300e+4")
  assert_eq(retained_json_at(root, "//a~1b/~0key/5").stringify(), "-0")
  assert_eq(retained_json_at(root, "//a~1b/~0key/6").stringify(), "1e400")
  assert_eq(retained_json_at(root, "//a~1b/~0key/0"), (null : Json))
  assert_eq(retained_json_child_pointer("", "a/~b"), "/a~1~0b")
  assert_eq(
    retained_json_at(parse_retained_json("{\"~1\":7,\"01\":8}"), "/~01"),
    (7 : Json),
  )
  assert_eq(
    retained_json_at(parse_retained_json("{\"01\":8}"), "/01"),
    (8 : Json),
  )
  for
    pointer in [
      "a",
      "#",
      "/~",
      "/~2",
      "//missing",
      "//a~1b/~0key/-",
      "//a~1b/~0key/01",
      "//a~1b/~0key/7",
      "//a~1b/~0key/0/x",
      "/" + "a".repeat(4096),
    ] {
    try retained_json_at(root, pointer) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
}

///|
test "retained JSON rejects duplicate escaped-equivalent keys at every level" {
  for
    source in [
      "{\"x\":1,\"x\":2}",
      "{\"x\":1,\"\\u0078\":2}",
      "[{\"a/b\":0,\"a\\/b\":1}]",
      "{\"a\":[{\"🌙\":0,\"\\ud83c\\udf19\":1}]}",
      "{\"x\":{\"\":1,\"\":2}}",
      "{\"x\":1,}",
      "[",
      "null trailing",
      "[".repeat(65) + "0" + "]".repeat(65),
      "[" + "0,".repeat(40_001) + "0]",
    ] {
    try parse_retained_json(source) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  assert_eq(
    parse_retained_json("[{\"x\":1},{\"x\":2}]").stringify(),
    "[{\"x\":1},{\"x\":2}]",
  )
  assert_eq(
    parse_retained_json("{\"x\":\"{,\\\"x\\\":1}\",\"y\":[{},[]]}").stringify(),
    "{\"x\":\"{,\\\"x\\\":1}\",\"y\":[{},[]]}",
  )
}

///|
async test "retained JSON pages children and extracts typed values without writes" {
  let (config, _) = test_executor_config()
  let source = b"{\"z\":[],\"a/b\":[{\"note\":\"moon\",\"id\":9007199254740993},null],\"\":{},\"boolean\":false}"
  let binding = json_fixture(config, source)
  let before = @fs.read_file(config.retention_root + "/json-results.json").binary()
  let first = browse_retained_json(binding, "report.json", config, limit=2)
  assert_eq(first.selected.kind, "object")
  assert_eq(first.selected.child_count, 4)
  assert_eq(first.children.map(child => child.pointer), ["/", "/a~1b"])
  assert_eq(first.next_after_child, 2)
  assert_true(first.has_more)
  let rest = browse_retained_json(binding, "report.json", config, after_child=2)
  assert_eq(rest.children.map(child => child.pointer), ["/boolean", "/z"])
  assert_false(rest.has_more)
  let array = browse_retained_json(
    binding,
    "report.json",
    config,
    pointer="/a~1b",
    limit=1,
  )
  assert_eq(array.children[0].pointer, "/a~1b/0")
  assert_eq(array.children[0].kind, "object")
  assert_true(array.has_more)
  let scalar = browse_retained_json(
    binding,
    "report.json",
    config,
    pointer="/a~1b/1",
  )
  assert_eq(scalar.selected.kind, "null")
  assert_eq(scalar.selected.preview, "null")
  assert_eq(scalar.children, [])
  assert_false(scalar.has_more)
  for pointer in ["/", "/z"] {
    let empty = browse_retained_json(binding, "report.json", config, pointer~)
    assert_eq(empty.selected.child_count, 0)
    assert_false(empty.has_more)
  }
  let selected = extract_retained_json(
    binding,
    "report.json",
    config,
    pointer="/a~1b/0",
  )
  assert_eq(selected.binding, binding)
  assert_eq(selected.pointer, "/a~1b/0")
  assert_eq(
    retained_json_at(parse_retained_json(selected.value.stringify()), "/id").stringify(),
    "9007199254740993",
  )
  assert_eq(
    @fs.read_file(config.retention_root + "/json-results.json").binary(),
    before,
  )
  assert_eq(
    @fs.read_file(config.scratch_root + "/json-results/report.json").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}

///|
async test "retained JSON protocol pages advance and large selections remain explicit" {
  let (base, _) = test_executor_config()
  let config = { ..base, limits: { ..base.limits, max_protocol_bytes: 4096, }, }
  let source = Json::array(
    [
      for index in 0..<60 => {
        ToJson::to_json("月🌙".repeat(100) + index.to_string())
      }
    ],
  ).stringify()
  let binding = json_fixture(config, @utf8.encode(source))
  let mut cursor = 0
  let mut count = 0
  while cursor < 60 {
    let page = browse_retained_json(
      binding,
      "report.json",
      config,
      after_child=cursor,
      limit=100,
    )
    assert_true(@utf8.encode(page.to_json().stringify()).length() <= 4096)
    assert_true(page.children.length() > 0)
    assert_eq(page.children[0].pointer, "/" + cursor.to_string())
    assert_true(page.children[0].preview_truncated)
    count += page.children.length()
    assert_true(page.next_after_child > cursor)
    cursor = page.next_after_child
  }
  assert_eq(count, 60)
  try extract_retained_json(binding, "report.json", config) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  ignore(extract_retained_json(binding, "report.json", config, pointer="/0"))
  try
    browse_retained_json(binding, "report.json", config, after_child=61)
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    browse_retained_json(binding, "report.json", config, limit=0) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    browse_retained_json(binding, "report.json", config, limit=101) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    browse_retained_json(binding, "report.json", config, after_child=-1)
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "retained JSON keeps binding fingerprint expiry and input limits" {
  let (config, _) = test_executor_config()
  let binding = json_fixture(config, b"{\"x\":1}")
  try
    browse_retained_json(
      { ..binding, workspace_id: "other", },
      "report.json",
      config,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try browse_retained_json(binding, "missing", config) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(
    config.scratch_root + "/json-results/report.json",
    b"{\"x\":2}",
  )
  try extract_retained_json(binding, "report.json", config) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  @fs.write_file(
    config.scratch_root + "/json-results/report.json",
    b"{\"x\":1}",
  )
  let record = load_retention_record(binding.retention_id, config)
  @fs.write_file(
    config.retention_root + "/json-results.json",
    { ..record, expires_at_ms: 1L, }.to_json().stringify(),
  )
  try browse_retained_json(binding, "report.json", config) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  for bytes in [b"\xff", b"{\"x\":1,\"\\u0078\":2}", Bytes::make(1_048_577, 32)] {
    let (other, _) = test_executor_config()
    let selected = json_fixture(other, bytes)
    try extract_retained_json(selected, "report.json", other) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
}

///|
async test "compiled retained JSON CLI browses extracts and reopens with provenance" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI for the compiled JSON journey")
  }
  let (config, _) = test_executor_config()
  let source = "{\"release\":\"Maple\",\"checks\":[{\"id\":9007199254740993,\"status\":\"follow-up\",\"note\":\"月🌙 quickstart\",\"latency\":1.2300e+4},{\"id\":2,\"status\":\"pass\",\"note\":null}],\"a/b\":{\"~tag\":\"kept\"}}\n"
  let binding = json_fixture(config, @utf8.encode(source))
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  for
    (label, args) in [
      (
        "children.txt",
        ["json", "report.json", "--pointer", "/checks", "--limit", "1"],
      ),
      (
        "continued.json",
        [
          "json", "report.json", "--pointer", "/checks", "--after-child", "1", "--json",
        ],
      ),
      (
        "selected.json",
        ["json", "report.json", "--pointer", "/checks/0", "--value"],
      ),
      (
        "escaped-key.json",
        ["json", "report.json", "--pointer", "/a~1b/~0tag", "--value"],
      ),
      (
        "null.json",
        ["json", "report.json", "--pointer", "/checks/1/note", "--value"],
      ),
    ] {
    let (code, out, errors) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_eq(code, 0)
    if label == "children.txt" {
      assert_true(out.text().contains("/checks/0"))
      assert_true(out.text().contains("[More: --after-child 1"))
      assert_eq(errors.binary(), b"")
    } else if label == "continued.json" {
      let page : RetentionJsonPage = @json.from_json(@json.parse(out.text()))
      assert_eq(page.binding, binding)
      assert_eq(page.children[0].pointer, "/checks/1")
      assert_false(page.has_more)
      assert_eq(errors.binary(), b"")
    } else {
      let context = @json.parse(errors.text())
      assert_eq(retained_json_at(context, "/binding"), binding.to_json())
      assert_eq(
        retained_json_at(context, "/file/relative_path"),
        ToJson::to_json("report.json"),
      )
      let reopened = parse_retained_json(out.text())
      if label == "selected.json" {
        assert_eq(
          retained_json_at(reopened, "/id").stringify(),
          "9007199254740993",
        )
        assert_eq(
          retained_json_at(reopened, "/latency").stringify(),
          "1.2300e+4",
        )
      } else if label == "null.json" {
        assert_eq(reopened, (null : Json))
      } else {
        assert_eq(reopened, ToJson::to_json("kept"))
      }
    }
    if @env.get_env_var("MOONFORT_JSON_EVIDENCE") is Some(root) {
      @fs.write_file(
        root + "/" + label,
        out.binary(),
        create_mode=CreateOrTruncate,
      )
      if !errors.binary().is_empty() {
        @fs.write_file(
          root + "/" + label + ".context.json",
          errors.binary(),
          create_mode=CreateOrTruncate,
        )
      }
    }
  }
  for
    args in [
      ["json", "report.json", "--pointer", "/missing"],
      ["json", "report.json", "--pointer", "/checks/01"],
      ["json", "report.json", "--value", "--limit", "1"],
      ["json", "report.json", "--json", "--value"],
      ["json", "report.json", "--value", "--value"],
      ["json", "report.json", "--csv"],
      ["json", "report.json", "--after-child", "-1"],
      ["json", "report.json", "--pointer", "/~2"],
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
  assert_eq(
    @fs.read_file(config.scratch_root + "/json-results/report.json").text(),
    source,
  )
  if @env.get_env_var("MOONFORT_JSON_EVIDENCE") is Some(root) {
    @fs.write_file(root + "/report.json", source, create_mode=CreateOrTruncate)
    @fs.write_file(
      root + "/receipt-binding.json",
      binding.to_json().stringify(),
      create_mode=CreateOrTruncate,
    )
  }
}
