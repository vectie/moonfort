///|
fn csv_draft_recipe(source : Bytes, operations : Array[Json]) -> Bytes {
  let recipe : Json = {
    "version": 1,
    "source_fingerprint": ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(source)),
    ),
    "operations": ToJson::to_json(operations),
  }
  @utf8.encode(recipe.stringify() + "\n")
}

///|
test "CSV draft preserves headers and exact cells while editing current row positions" {
  let bytes = @utf8.encode(
    "\u{feff}id,,note,note\r\n01,1.2300e+4,\"comma, quote \"\"yes\"\"\r\nsecond\",=SUM(A1:A2)\r\n02,-0,drop,\r\n03,9007199254740993,old,\r\n",
  )
  let source = parse_retained_csv(@utf8.decode(bytes))
  let original = source.map(row => row.copy())
  let operations : Array[Json] = [
    { "op": "set-cell", "row": 1, "column": 4, "value": "月🌙" },
    { "op": "remove-row", "row": 2 },
    { "op": "set-cell", "row": 2, "column": 3, "value": "corrected" },
    { "op": "append-row", "cells": ["04", "", "new\r\nrow", "=1+1"] },
    { "op": "set-cell", "row": 3, "column": 2, "value": "001" },
  ]
  let (_, edits) = retained_csv_edits(csv_draft_recipe(bytes, operations))
  let (csv, count) = apply_retained_csv_edits(source, edits)
  assert_eq(count, 3)
  assert_eq(source, original)
  assert_eq(parse_retained_csv(csv), [
    ["id", "", "note", "note"],
    ["01", "1.2300e+4", "comma, quote \"yes\"\r\nsecond", "月🌙"],
    ["03", "9007199254740993", "corrected", ""],
    ["04", "001", "new\r\nrow", "=1+1"],
  ])
  assert_true(csv.has_suffix("\r\n"))
  // Reopen the actual candidate with the existing CSV comparison engine.
  let (_, added, removed, changed, unchanged) = compare_retained_csv_records(
    source,
    parse_retained_csv(csv),
    [1],
  )
  assert_eq((added, removed, changed, unchanged), (1, 1, 2, 0))
}

///|
test "CSV draft can remove all data or append to a header-only table" {
  let source = parse_retained_csv("header\nvalue\n")
  let (empty, count) = apply_retained_csv_edits(source, [RemoveRow(1)])
  assert_eq(count, 0)
  assert_eq(parse_retained_csv(empty), [["header"]])
  let (one, count) = apply_retained_csv_edits(parse_retained_csv(empty), [
    AppendRow([""]),
  ])
  assert_eq(count, 1)
  assert_eq(parse_retained_csv(one), [["header"], [""]])
}

///|
test "CSV draft rejects malformed recipes and non-string or ambiguous coordinates" {
  let source = b"id,status\n01,open\n"
  let valid = @utf8.decode(
    csv_draft_recipe(source, [
      { "op": "set-cell", "row": 1, "column": 2, "value": "ready" },
    ]),
  )
  for
    invalid in [
      "{}",
      "[]",
      valid.replace_all(old="\"version\":1", new="\"version\":1.0"),
      valid.replace_all(old="\"row\":1", new="\"row\":1e0"),
      valid.replace_all(old="\"row\":1", new="\"row\":1.0"),
      valid.replace_all(old="\"row\":1", new="\"row\":-1"),
      valid.replace_all(old="\"row\":1", new="\"row\":0"),
      valid.replace_all(old="\"row\":1", new="\"row\":\"1\""),
      valid.replace_all(old="\"row\":1", new="\"row\":20002"),
      valid.replace_all(old="\"row\":1", new="\"row\":1,\"row\":1"),
      valid.replace_all(old="\"row\":1", new="\"row\":1,\"extra\":1"),
      valid.replace_all(old="\"value\":\"ready\"", new="\"value\":1"),
      valid.replace_all(old="\"value\":\"ready\"", new="\"value\":null"),
      valid.replace_all(old="set-cell", new="rename-column"),
      valid.replace_all(old="source_fingerprint", new="wrong_field"),
    ] {
    try retained_csv_edits(@utf8.encode(invalid)) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail(invalid)
    }
  }
  let invalid_operations : Array[Array[Json]] = [
    [],
    [{ "op": "append-row", "cells": [1] }],
    [{ "op": "append-row", "cells": [] }],
    [{ "op": "append-row", "cells": ["\u{0}"] }],
    [{ "op": "append-row", "cells": [ToJson::to_json("x".repeat(16_385))] }],
    [
      {
        "op": "append-row",
        "cells": ToJson::to_json(Array::make(65, Json::string(""))),
      },
    ],
    Array::make(101, Json::object({ "op": "remove-row", "row": 1 })),
  ]
  for operations in invalid_operations {
    try
      retained_csv_edits(csv_draft_recipe(source, operations)) |> ignore
    catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
  }
  try retained_csv_edits(Bytes::make(65_537, 32)) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try retained_csv_edits(b"\xff") |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
test "CSV draft refuses invalid sequential edits without mutating source" {
  let source = parse_retained_csv("id,status\n01,open\n")
  for
    edits in [
      [SetCell(1, 2, "changed"), RemoveRow(2)],
      [RemoveRow(1), SetCell(1, 2, "changed")],
      [SetCell(1, 3, "changed")],
      [SetCell(0, 1, "header")],
      [RemoveRow(0)],
      [AppendRow(["too", "many", "cells"])],
    ] {
    try apply_retained_csv_edits(source, edits) |> ignore catch {
      _ => ()
    } noraise {
      _ => fail("expected retained-artifact operation to reject input")
    }
    assert_eq(source, [["id", "status"], ["01", "open"]])
  }
  try
    apply_retained_csv_edits(parse_retained_csv("h\n" + "a\n".repeat(20_000)), [
      AppendRow(["b"]),
    ])
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  // A bounded table remains reusable after many sequential edits.
  let large = parse_retained_csv("h,h,h,h\n" + "a,a,a,a\n".repeat(19_999))
  let edits = Array::make(64, SetCell(1, 1, "small"))
  let (within_limit, _) = apply_retained_csv_edits(large, edits)
  assert_true(@utf8.encode(within_limit).length() <= 1_048_576)
  // A valid source below 1 MiB can exceed the final byte cap after CSV quoting.
  let dense_source = "h,".repeat(19) +
    "h\n" +
    ("a,".repeat(19) + "a\n").repeat(14_000)
  assert_true(@utf8.encode(dense_source).length() < 1_048_576)
  try
    apply_retained_csv_edits(parse_retained_csv(dense_source), [
      SetCell(1, 1, "a"),
    ])
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "CSV draft binds source recipe candidate and preserves receipts grants and original bytes" {
  let (config, _) = test_executor_config()
  let source = b"id,status\n01,open\n02,draft\n"
  let binding = csv_fixture(config, source)
  let recipe = csv_draft_recipe(source, [
    { "op": "set-cell", "row": 1, "column": 2, "value": "ready" },
    { "op": "remove-row", "row": 2 },
    { "op": "append-row", "cells": ["03", "new"] },
  ])
  let receipt_path = config.retention_root + "/table-results.json"
  let receipt = @fs.read_file(receipt_path).binary()
  let draft = draft_retained_csv(binding, "checks.csv", config, recipe)
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
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(draft.csv))),
  )
  assert_eq(draft.candidate_size_bytes, @utf8.encode(draft.csv).length())
  assert_eq(draft.recipe_size_bytes, recipe.length())
  assert_eq(
    (draft.source_rows, draft.candidate_rows, draft.operation_count),
    (2, 2, 3),
  )
  assert_eq(
    retained_json_at(draft.context(), "/derived_candidate"),
    (true : Json),
  )
  assert_eq(parse_retained_csv(draft.csv), [
    ["id", "status"],
    ["01", "ready"],
    ["03", "new"],
  ])
  let wrong = csv_draft_recipe(b"another source", [
    { "op": "remove-row", "row": 1 },
  ])
  try draft_retained_csv(binding, "checks.csv", config, wrong) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  try
    draft_retained_csv(
      { ..binding, command_digest: "d".repeat(64), },
      "checks.csv",
      config,
      recipe,
    )
    |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
  assert_eq(@fs.read_file(receipt_path).binary(), receipt)
  assert_eq(
    @fs.read_file(config.scratch_root + "/table-results/checks.csv").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
  @fs.write_file(
    config.scratch_root + "/table-results/checks.csv",
    b"id,status\n01,tampered\n",
  )
  try
    draft_retained_csv(binding, "checks.csv", config, recipe) |> ignore
  catch {
    _ => ()
  } noraise {
    _ => fail("expected retained-artifact operation to reject input")
  }
}

///|
async test "compiled CSV editing exports repeatable reusable candidates and no output on refusal" {
  guard @env.get_env_var("MOONFORT_ARTIFACT_READER_CLI") is Some(executable) else {
    fail("set MOONFORT_ARTIFACT_READER_CLI for compiled CSV editing journey")
  }
  let (config, _) = test_executor_config()
  let source = @utf8.encode(
    "id,status,note\r\n01,open,\"review, then correct\r\nsecond line\"\r\n02,draft,remove\r\n03,keep,月🌙\r\n",
  )
  let binding = csv_fixture(config, source)
  let (config_path, binding_path) = write_artifact_cli_inputs(config, binding)
  let extra_env = { "MOONFORT_EXECUTOR_CONFIG": config_path }
  // Start by discovering exact source fingerprint and logical data-row numbers.
  let (inspect_code, inspection, _) = @process.collect_output(
    executable,
    ["table", "checks.csv", "--json"],
    extra_env~,
    stdin=@process.redirect_from_file(binding_path),
  )
  assert_eq(inspect_code, 0)
  let page : RetentionCsvPage = @json.from_json(@json.parse(inspection.text()))
  assert_eq(page.rows[0].row, 1)
  assert_eq(
    page.file.fingerprint,
    @crypto.bytes_to_hex_string(@crypto.sha256(source)),
  )
  let recipe = csv_draft_recipe(source, [
    { "op": "set-cell", "row": 1, "column": 2, "value": "ready" },
    { "op": "remove-row", "row": 2 },
    { "op": "append-row", "cells": ["04", "new", "added \"locally\" 🌙"] },
  ])
  let recipe_path = config.scratch_root + "/edits.json"
  @fs.write_file(recipe_path, recipe, create_mode=CreateNew)
  let args = ["edit-csv", "checks.csv", "--recipe", recipe_path]
  let receipt_path = config.retention_root + "/table-results.json"
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
    retained_json_at(context, "/source_file/fingerprint"),
    ToJson::to_json(page.file.fingerprint),
  )
  assert_eq(
    retained_json_at(context, "/candidate_fingerprint"),
    ToJson::to_json(
      @crypto.bytes_to_hex_string(@crypto.sha256(output.binary())),
    ),
  )
  let reopened = config.scratch_root + "/candidate.csv"
  @fs.write_file(reopened, output.binary(), create_mode=CreateNew)
  let rows = parse_retained_csv(@fs.read_file(reopened).text())
  assert_eq(rows, [
    ["id", "status", "note"],
    ["01", "ready", "review, then correct\r\nsecond line"],
    ["03", "keep", "月🌙"],
    ["04", "new", "added \"locally\" 🌙"],
  ])
  let (changes, added, removed, changed, unchanged) = compare_retained_csv_records(
    parse_retained_csv(@utf8.decode(source)),
    rows,
    [1],
  )
  assert_eq((added, removed, changed, unchanged), (1, 1, 1, 1))
  assert_eq(changes[0].changed_columns, [2])
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
      ["edit-csv", "checks.csv"],
      args + ["--json"],
      args + ["--recipe", recipe_path],
      ["edit-csv", "checks.csv", "--recipe", recipe_path + ".missing"],
      ["edit-csv", "checks.csv", "--recipe", config.scratch_root],
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
  if @env.get_env_var("MOONFORT_CSV_DRAFT_EVIDENCE") is Some(root) {
    for
      (name, bytes) in [
        ("retained-checks.csv", source),
        ("inspection.json", inspection.binary()),
        ("local-edits.json", recipe),
        ("candidate.csv", output.binary()),
        ("candidate.context.json", errors.binary()),
        (
          "comparison.json",
          @utf8.encode(ToJson::to_json(changes).stringify() + "\n"),
        ),
      ] {
      @fs.write_file(root + "/" + name, bytes, create_mode=CreateOrTruncate)
    }
  }
  // A valid first edit followed by an invalid edit must emit no candidate.
  for
    invalid in [
      b"{}",
      csv_draft_recipe(b"stale", [{ "op": "remove-row", "row": 1 }]),
      csv_draft_recipe(source, [
        { "op": "set-cell", "row": 1, "column": 2, "value": "partial" },
        { "op": "remove-row", "row": 99 },
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
  assert_eq(
    @fs.read_file(config.scratch_root + "/table-results/checks.csv").binary(),
    source,
  )
  assert_eq(@fs.readdir(config.approval_root + "/consumed"), [])
  assert_eq(@fs.readdir(config.workspaces["book"].root), [])
}
