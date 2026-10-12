///|
test "CSV page public output preserves strings and escapes quotes" {
  let page : @executor.RetentionCsvPage = {
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
      size_bytes: 100L,
      fingerprint: "d".repeat(64),
    },
    columns: [2, 1],
    headers: ["note", "id"],
    where_column: 0,
    equals: "",
    total_rows: 1,
    matching_rows: 1,
    rows: [{ row: 1, cells: ["月🌙, \"review\"\nnext", "001"], }],
    next_after_row: 1,
    has_more: false,
  }
  assert_eq(
    page.to_csv(),
    "\"note\",\"id\"\r\n\"月🌙, \"\"review\"\"\nnext\",\"001\"\r\n",
  )
  let decoded : @executor.RetentionCsvPage = @json.from_json(page.to_json())
  assert_eq(decoded, page)
}
