///|
fn text_draft_recipe(source : Bytes, operations : Array[Json]) -> Bytes {
  @utf8.encode(
    (
      {
        "version": 1,
        "source_fingerprint": @crypto.bytes_to_hex_string(
          @crypto.sha256(source),
        ).to_json(),
        "operations": operations.to_json(),
      } : Json).stringify() +
    "\n",
  )
}

///|
fn apply_text_recipe(source : String, operations : Array[Json]) -> String raise {
  let (_, edits) = retained_text_edits(
    text_draft_recipe(@utf8.encode(source), operations),
  )
  let (text, _, _) = apply_retained_text_edits(source, edits)
  text
}

///|
test "text draft original ranges replace insert delete and EOF without normalization" {
  let source = "\u{feff}keep\r\nold\nremove\r\n月🌙"
  let edits : Array[Json] = [
    { "start_line": 5, "end_line": 5, "expected": "", "replacement": "\nlast" },
    {
      "start_line": 3,
      "end_line": 4,
      "expected": "remove\r\n",
      "replacement": "",
    },
    {
      "start_line": 2,
      "end_line": 3,
      "expected": "old\n",
      "replacement": "new\r\n",
    },
    { "start_line": 1, "end_line": 1, "expected": "", "replacement": "first\n" },
  ]
  assert_eq(
    apply_text_recipe(source, edits),
    "\u{feff}first\nkeep\r\nnew\r\n月🌙\nlast",
  )
  assert_eq(
    apply_text_recipe("", [
      { "start_line": 1, "end_line": 1, "expected": "", "replacement": "one" },
    ]),
    "one",
  )
  assert_eq(
    apply_text_recipe("\u{feff}", [
      {
        "start_line": 1,
        "end_line": 1,
        "expected": "",
        "replacement": "one\r\n",
      },
    ]),
    "\u{feff}one\r\n",
  )
  assert_eq(
    apply_text_recipe("one\n", [
      { "start_line": 1, "end_line": 2, "expected": "one\n", "replacement": "" },
    ]),
    "",
  )
  assert_eq(
    apply_text_recipe("one", [
      {
        "start_line": 1,
        "end_line": 2,
        "expected": "one",
        "replacement": "one\n",
      },
    ]),
    "one\n",
  )
  assert_eq(
    apply_text_recipe("one\n", [
      { "start_line": 2, "end_line": 2, "expected": "", "replacement": "two\n" },
    ]),
    "one\ntwo\n",
  )
}

///|
test "text draft refuses stale ranges overlaps duplicate anchors and malformed recipes" {
  let source = b"a\nb\nc\n"
  let valid = @utf8.decode(
    text_draft_recipe(source, [
      {
        "start_line": 1,
        "end_line": 2,
        "expected": "a\n",
        "replacement": "x\n",
      },
    ]),
  )
  for
    invalid in [
      "{}",
      "[]",
      valid.replace_all(old="\"version\":1", new="\"version\":1.0"),
      valid.replace_all(old="\"start_line\":1", new="\"start_line\":1e0"),
      valid.replace_all(old="\"start_line\":1", new="\"start_line\":0"),
      valid.replace_all(old="\"start_line\":1", new="\"start_line\":-1"),
      valid.replace_all(old="\"start_line\":1", new="\"start_line\":2002"),
      valid.replace_all(
        old="\"start_line\":1",
        new="\"start_line\":1,\"start_line\":1",
      ),
      valid.replace_all(
        old="\"replacement\":\"x\\n\"",
        new="\"replacement\":null",
      ),
    ] {
    assert_true(
      (try? retained_text_edits(@utf8.encode(invalid))) is Err(_),
      msg=invalid,
    )
  }
  let invalid_operations : Array[Array[Json]] = [
    [{ "start_line": 2, "end_line": 1, "expected": "", "replacement": "" }],
    [
      {
        "start_line": 1,
        "end_line": 3,
        "expected": "a\nb\n",
        "replacement": "",
      },
      {
        "start_line": 2,
        "end_line": 4,
        "expected": "b\nc\n",
        "replacement": "",
      },
    ],
    [
      { "start_line": 2, "end_line": 2, "expected": "", "replacement": "x" },
      { "start_line": 2, "end_line": 2, "expected": "", "replacement": "y" },
    ],
    [
      {
        "start_line": 1,
        "end_line": 2,
        "expected": "a\n",
        "replacement": "x\n",
      },
      {
        "start_line": 3,
        "end_line": 4,
        "expected": "stale\n",
        "replacement": "",
      },
    ],
    [{ "start_line": 5, "end_line": 5, "expected": "", "replacement": "x" }],
    [{ "start_line": 1, "end_line": 1, "expected": "a", "replacement": "x" }],
    [
      {
        "start_line": 1,
        "end_line": 2,
        "expected": "a\n",
        "replacement": "\u{0}",
      },
    ],
  ]
  for operations in invalid_operations {
    assert_true(
      (try? apply_text_recipe(@utf8.decode(source), operations)) is Err(_),
    )
  }
  assert_true(
    (try? retained_text_edits(text_draft_recipe(source, []))) is Err(_),
  )
  assert_true((try? retained_text_edits(Bytes::make(65537, 32))) is Err(_))
  assert_true((try? retained_text_edits(b"\xff")) is Err(_))
  assert_true((try? text_draft_lines("a\n".repeat(2001))) is Err(_))
  assert_true((try? text_draft_lines("a".repeat(262145))) is Err(_))
  assert_true(
    (try? apply_text_recipe("a".repeat(250000), [
      {
        "start_line": 2,
        "end_line": 2,
        "expected": "",
        "replacement": "b".repeat(13000).to_json(),
      },
    ]))
    is Err(_),
  )
}

///|
async test "native text draft exports reusable candidate context and refuses without partial output" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI for native text editing journey")
  }
  let (config, roots) = test_executor_config()
  let source = @utf8.encode(
    "\u{feff}Review notes\r\nstatus: draft\r\nremove this\nkeep 月🌙",
  )
  let binding = csv_fixture(config, source)
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  let recipe = text_draft_recipe(source, [
    {
      "start_line": 2,
      "end_line": 3,
      "expected": "status: draft\r\n",
      "replacement": "status: reviewed locally\r\n",
    },
    {
      "start_line": 3,
      "end_line": 4,
      "expected": "remove this\n",
      "replacement": "",
    },
    {
      "start_line": 5,
      "end_line": 5,
      "expected": "",
      "replacement": "\nnext: separate review\n",
    },
  ])
  let receipt_path = config.retention_root + "/table-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let recipe_path = config.scratch_root + "/text-edits.json"
  @fs.write_file(recipe_path, recipe, create_mode=CreateNew)
  let args = ["edit-text", "checks.csv", "--recipe", recipe_path]
  let (code, out, err) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(code, 0)
  assert_eq(
    out.text(),
    "\u{feff}Review notes\r\nstatus: reviewed locally\r\nkeep 月🌙\nnext: separate review\n",
  )
  let context = @json.parse(err.text())
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(out.binary())).to_json(),
  )
  assert_eq(
    retained_json_at(context, "/recipe_fingerprint"),
    @crypto.bytes_to_hex_string(@crypto.sha256(recipe)).to_json(),
  )
  assert_eq(retained_json_at(context, "/binding"), binding.to_json())
  assert_eq(retained_json_at(context, "/source_lines"), 4)
  let candidate = config.scratch_root + "/candidate.txt"
  @fs.write_file(candidate, out.binary(), create_mode=CreateNew)
  let reopened = @fs.read_file(candidate).text()
  let diff = @text_diff.unified(
    @utf8.decode(source),
    reopened,
    "a/notes.txt",
    "b/notes.txt",
  )
  assert_true(diff.patch.contains("+status: reviewed locally\r\n"))
  let patch_path = config.scratch_root + "/candidate.diff"
  let reconstructed = config.scratch_root + "/reconstructed.txt"
  @fs.write_file(patch_path, diff.patch, create_mode=CreateNew)
  @fs.write_file(reconstructed, source, create_mode=CreateNew)
  let (patch_code, _, _) = @process.collect_output("/usr/bin/patch", [
    "--batch", "--binary", reconstructed, patch_path,
  ])
  assert_eq(patch_code, 0)
  assert_eq(@fs.read_file(reconstructed).binary(), out.binary())
  let (again, again_out, again_err) = @process.collect_output(
    executable,
    args,
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(again, 0)
  assert_eq(again_out.binary(), out.binary())
  assert_eq(again_err.binary(), err.binary())
  if @env.get_env_var("MOONFORT_TEXT_DRAFT_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("original.txt", source),
        ("recipe.json", recipe),
        ("candidate.txt", out.binary()),
        ("context.json", err.binary()),
        ("candidate.diff", @utf8.encode(diff.patch)),
        ("reconstructed.txt", @fs.read_file(reconstructed).binary()),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  for
    bad_args in [
      ["edit-text", "checks.csv"],
      args + ["--json"],
      args + ["--recipe", recipe_path],
      ["edit-text", "checks.csv", "--recipe", recipe_path + ".missing"],
    ] {
    let (status, empty, _) = @process.collect_output(
      executable,
      bad_args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(status != 0)
    assert_eq(empty.binary(), b"")
  }
  for
    invalid in [
      b"{}",
      text_draft_recipe(b"stale", [
        { "start_line": 1, "end_line": 1, "expected": "", "replacement": "x" },
      ]),
      text_draft_recipe(source, [
        {
          "start_line": 1,
          "end_line": 1,
          "expected": "",
          "replacement": "partial",
        },
        {
          "start_line": 3,
          "end_line": 4,
          "expected": "stale",
          "replacement": "",
        },
      ]),
    ] {
    @fs.write_file(recipe_path, invalid)
    let (status, empty, _) = @process.collect_output(
      executable,
      args,
      extra_env~,
      stdin=@process.redirect_from_file(binding_path),
    )
    assert_true(status != 0)
    assert_eq(empty.binary(), b"")
  }
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(export_retained_artifact(binding, "checks.csv", config), source)
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  @fs.write_file(config.scratch_root + "/table-results/checks.csv", b"tampered")
  assert_true(
    (try? draft_retained_text(binding, "checks.csv", config, recipe)) is Err(_),
  )
  cleanup_test_roots(roots)
}
