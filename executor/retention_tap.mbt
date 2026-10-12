///|
/// Receipt-bound TAP observations and their source context.
pub(all) struct RetentionTapTable {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  plan_count : Int?
  test_count : Int
  status_counts : Map[String, Int]
  row_count : Int
  failures_only : Bool
  skip_reason : String
  bailout : String?
  bailout_line : Int?
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
/// Convert retained flat TAP output without rerunning its producer.
pub async fn tabulate_retained_tap(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  failures_only? : Bool = false,
) -> RetentionTapTable {
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1048576L else {
    fail("TAP requires a retained file of at most 1 MiB")
  }
  let report = @tap.parse(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let output = StringBuilder()
  let mut output_size = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    let row = enriched_csv_record(cells)
    output_size += @utf8.encode(row).length()
    guard output_size <= 1048576 else { fail("TAP CSV exceeds 1 MiB") }
    output.write_string(row)
  }
  write([
    "test_number", "report_line", "status", "description", "directive", "reason",
    "diagnostics",
  ])
  let counts : Map[String, Int] = {
    "passed": 0,
    "failed": 0,
    "skipped": 0,
    "todo": 0,
    "unexpected-pass": 0,
  }
  let mut row_count = 0
  for point in report.points {
    counts[point.status] = counts[point.status] + 1
    if !failures_only || point.status == "failed" {
      write([
        point.number.to_string(),
        point.report_line.to_string(),
        point.status,
        point.description,
        point.directive,
        point.reason,
        point.diagnostics.join("\n"),
      ])
      row_count += 1
    }
  }
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during TAP projection")
  }
  let csv = output.to_string()
  let bytes = @utf8.encode(csv)
  let table : RetentionTapTable = {
    binding,
    file,
    plan_count: report.plan,
    test_count: report.points.length(),
    status_counts: counts,
    row_count,
    failures_only,
    skip_reason: report.skip_reason,
    bailout: report.bailout,
    bailout_line: report.bailout_line,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    csv,
  }
  guard @utf8.encode(table.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("TAP context exceeds protocol budget")
  }
  table
}

///|
pub fn RetentionTapTable::context(self : RetentionTapTable) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-tap-tests-csv-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "plan_count": match self.plan_count {
      Some(value) => value.to_json()
      None => Json::null()
    },
    "test_count": self.test_count.to_json(),
    "status_counts": self.status_counts.to_json(),
    "row_count": self.row_count.to_json(),
    "failures_only": self.failures_only.to_json(),
    "skip_reason": self.skip_reason.to_json(),
    "bailout": match self.bailout {
      Some(value) => value.to_json()
      None => Json::null()
    },
    "bailout_line": match self.bailout_line {
      Some(value) => value.to_json()
      None => Json::null()
    },
    "plan_satisfied": (self.plan_count == Some(self.test_count) &&
    self.bailout is None).to_json(),
    "row_semantics": "top-level test points in original order; failures filter selects only failed status",
    "report_line_semantics": "one-based physical test line in original report",
    "diagnostic_semantics": "following comments and indented YAML blocks are opaque text; preamble and post-plan comments omitted",
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}
