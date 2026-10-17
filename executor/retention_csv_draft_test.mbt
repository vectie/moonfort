///|
test "CSV draft public context separates original and candidate identities" {
  let draft : @executor.RetentionCsvDraft = {
    binding: {
      protocol_version: 1,
      retention_id: "demo",
      workspace_id: "demo",
      approval_digest: "b".repeat(64),
      command_digest: "c".repeat(64),
    },
    file: {
      relative_path: "report.csv",
      kind: RegularFile,
      size_bytes: 25L,
      fingerprint: "d".repeat(64),
    },
    recipe_fingerprint: "e".repeat(64),
    recipe_size_bytes: 200,
    candidate_fingerprint: "f".repeat(64),
    candidate_size_bytes: 20,
    operation_count: 1,
    source_rows: 2,
    candidate_rows: 1,
    csv: "\"id\"\r\n\"sensitive cell\"\r\n",
  }
  let context = draft.context()
  guard context is Object(fields) else { fail("object expected") }
  assert_eq(fields.get("derived_candidate"), Some(true))
  assert_eq(
    fields.get("candidate_fingerprint"),
    Some(ToJson::to_json("f".repeat(64))),
  )
  assert_eq(fields.get("source_file"), Some(draft.file.to_json()))
  assert_false(context.stringify().contains("sensitive cell"))
  let reopened : @executor.RetentionCsvDraft = @json.from_json(draft.to_json())
  assert_eq(reopened.csv, draft.csv)
  assert_eq(reopened.context(), context)
}
