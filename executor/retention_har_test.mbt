///|
test "HAR public context roundtrip retains filter and source without copying CSV" {
  let table : @executor.RetentionHarTable = {
    binding: {
      protocol_version: 1,
      retention_id: "example",
      workspace_id: "book",
      approval_digest: "a".repeat(64),
      command_digest: "b".repeat(64),
    },
    file: {
      relative_path: "network.har",
      kind: RegularFile,
      size_bytes: 200L,
      fingerprint: "c".repeat(64),
    },
    entry_count: 3,
    row_count: 1,
    http_method: "POST",
    status: Some(503),
    minimum_ms: 100.0,
    candidate_fingerprint: "d".repeat(64),
    candidate_size_bytes: 80,
    csv: "private-request-url",
  }
  let context = table.context()
  guard context is Object(fields) else { fail("expected context object") }
  assert_eq(fields.get("entry_count"), Some(3))
  assert_eq(fields.get("row_count"), Some(1))
  assert_eq(
    fields.get("selection"),
    Some({ "method": "POST", "status": 503, "minimum_ms": 100 }),
  )
  assert_false(context.stringify().contains("private-request-url"))
  let encoded = table.to_json()
  guard encoded is Object(serialized) else { fail("expected serialized table") }
  assert_eq(serialized.get("method"), Some(Json::string("POST")))
  assert_false(serialized.contains("http_method"))
  let reopened : @executor.RetentionHarTable = @json.from_json(encoded)
  assert_eq(reopened.context(), context)
  assert_eq(reopened.csv, table.csv)
}
