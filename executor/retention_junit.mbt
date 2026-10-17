///|
/// Test outcomes projected from a verified retained JUnit XML artifact.
pub(all) struct RetentionJunitTable {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  row_count : Int
  passed : Int
  failed : Int
  errors : Int
  skipped : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
/// Export each testcase with its original XML start line, suite, outcome,
/// timing/location strings and decoded failure diagnostics. All XML validates
/// before returning a candidate. No process runs and no original is modified.
pub async fn tabulate_retained_junit(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
) -> RetentionJunitTable {
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("JUnit requires a retained file of at most 1 MiB")
  }
  let report = @junit.parse(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let output = StringBuilder()
  let mut size = 0
  for cells in [report.headers] + report.rows {
    let line = enriched_csv_record(cells)
    size += @utf8.encode(line).length()
    guard size <= 1_048_576 else { fail("JUnit CSV candidate exceeds 1 MiB") }
    output.write_string(line)
  }
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during JUnit projection")
  }
  let csv = output.to_string()
  let table : RetentionJunitTable = {
    binding,
    file,
    row_count: report.rows.length(),
    passed: report.passed,
    failed: report.failed,
    errors: report.errors,
    skipped: report.skipped,
    candidate_fingerprint: @crypto.bytes_to_hex_string(
      @crypto.sha256(@utf8.encode(csv)),
    ),
    candidate_size_bytes: size,
    csv,
  }
  guard @utf8.encode(table.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("JUnit table context exceeds protocol budget")
  }
  table
}

///|
/// Receipt/source binding and observed counts without the CSV payload.
pub fn RetentionJunitTable::context(self : RetentionJunitTable) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-junit-csv-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "source_line_column": "__source_line",
    "row_count": self.row_count.to_json(),
    "passed": self.passed.to_json(),
    "failed": self.failed.to_json(),
    "errors": self.errors.to_json(),
    "skipped": self.skipped.to_json(),
    "counts_from": "testcase outcomes; declared suite totals are not used",
    "omitted_metadata": ["properties", "system-out", "system-err"],
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}

///|
pub extend RetentionJunitTable with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionJunitTable with ToJson::{to_json}

///|
pub extend RetentionJunitTable with @moonbitlang/core/json.FromJson::{from_json}
