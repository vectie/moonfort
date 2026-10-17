///|
test "CSV consolidation public context and serialization preserve each source identity" {
  let result : @executor.RetentionCsvStack = {
    binding: {
      protocol_version: 1,
      retention_id: "example",
      workspace_id: "book",
      approval_digest: "a".repeat(64),
      command_digest: "b".repeat(64),
    },
    sources: [
      {
        file: {
          relative_path: "one.csv",
          kind: RegularFile,
          size_bytes: 12L,
          fingerprint: "c".repeat(64),
        },
        row_count: 1,
      },
      {
        file: {
          relative_path: "two.csv",
          kind: RegularFile,
          size_bytes: 7L,
          fingerprint: "d".repeat(64),
        },
        row_count: 0,
      },
    ],
    manifest_fingerprint: "e".repeat(64),
    manifest_size_bytes: 123,
    row_count: 1,
    candidate_fingerprint: "f".repeat(64),
    candidate_size_bytes: 80,
    csv: "private cell content",
  }
  let context = result.context()
  guard context is Object(fields) else { fail("expected object") }
  assert_eq(fields.get("derived_candidate"), Some(true))
  assert_eq(fields.get("sources"), Some(result.sources.to_json()))
  assert_eq(fields.get("row_count"), Some(1))
  assert_false(context.stringify().contains("private cell content"))
  let reopened : @executor.RetentionCsvStack = @json.from_json(result.to_json())
  assert_eq(reopened.context(), context)
  assert_eq(reopened.csv, result.csv)
}
