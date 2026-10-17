///|
test "text draft public context separates source and candidate without disclosing content" {
  let draft : @executor.RetentionTextDraft = {
    binding: {
      protocol_version: 1,
      retention_id: "demo",
      workspace_id: "demo",
      approval_digest: "b".repeat(64),
      command_digest: "c".repeat(64),
    },
    file: {
      relative_path: "notes.txt",
      kind: RegularFile,
      size_bytes: 6L,
      fingerprint: "d".repeat(64),
    },
    recipe_fingerprint: "e".repeat(64),
    recipe_size_bytes: 180,
    candidate_fingerprint: "f".repeat(64),
    candidate_size_bytes: 17,
    operation_count: 1,
    source_lines: 1,
    candidate_lines: 1,
    text: "private candidate",
  }
  let context = draft.context()
  assert_false(context.stringify().contains("private candidate"))
  guard context is Object(fields) else { fail("expected context object") }
  assert_eq(fields.get("derived_candidate"), Some(true))
  assert_eq(fields.get("source_file"), Some(draft.file.to_json()))
  let reopened : @executor.RetentionTextDraft = @json.from_json(draft.to_json())
  assert_eq(reopened.text, draft.text)
  assert_eq(reopened.context(), context)
}
