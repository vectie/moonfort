///|
/// Receipt-bound line coverage; repeated source/test records are not merged.
pub(all) struct RetentionLcovTable {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  record_count : Int
  line_count : Int
  covered_count : Int
  row_count : Int
  uncovered_only : Bool
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
fn lcov_number(value : String) -> Int raise {
  guard !value.is_empty() else { fail("LCOV expected decimal integer") }
  for c in value {
    guard c >= '0' && c <= '9' else { fail("LCOV expected decimal integer") }
  }
  @string.parse_int(value)
}

///|
fn retained_lcov_csv(
  text : String,
  uncovered_only : Bool,
) -> (String, Int, Int, Int, Int) raise {
  guard @utf8.encode(text).length() <= 1048576 else {
    fail("LCOV exceeds 1 MiB")
  }
  let output = StringBuilder()
  let mut output_size = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    let row = enriched_csv_record(cells)
    output_size += @utf8.encode(row).length()
    guard output_size <= 1048576 else { fail("LCOV CSV exceeds 1 MiB") }
    output.write_string(row)
  }
  write([
    "record", "report_line", "test_name", "source_file", "source_line", "hits", "checksum",
  ])
  let mut test_name = ""
  let mut source_file = ""
  let mut active = false
  let mut pending_test = false
  let mut records = 0
  let mut total = 0
  let mut covered = 0
  let mut rows = 0
  let mut record_lines = 0
  let mut record_covered = 0
  let mut found : Int? = None
  let mut hit : Int? = None
  let seen : Map[Int, Bool] = Map([])
  let lines = text.split("\n").to_array()
  for index, raw in lines {
    let line = raw.to_owned().trim_end(chars="\r").to_owned()
    if line.is_empty() && index == lines.length() - 1 {
      continue
    }
    if line == "end_of_record" {
      guard active else { fail("LCOV end outside record") }
      if found is Some(value) {
        guard value == record_lines else { fail("LCOV LF conflicts with DA") }
      }
      if hit is Some(value) {
        guard value == record_covered else { fail("LCOV LH conflicts with DA") }
      }
      active = false
      test_name = ""
      continue
    }
    let parts = line.split(":").to_array()
    guard parts.length() >= 2 else { fail("LCOV expected tagged line") }
    let tag = parts[0].to_owned()
    let value = parts[1:].map(p => p.to_owned()).join(":")
    match tag {
      "TN" => {
        guard !active && !pending_test else { fail("LCOV misplaced TN") }
        test_name = value
        pending_test = true
      }
      "SF" => {
        guard !active && !value.is_empty() else {
          fail("LCOV misplaced or empty SF")
        }
        active = true
        pending_test = false
        source_file = value
        records += 1
        guard records <= 1000 else { fail("LCOV exceeds 1000 records") }
        record_lines = 0
        record_covered = 0
        found = None
        hit = None
        seen.clear()
      }
      "DA" => {
        guard active else { fail("LCOV DA outside record") }
        let cells = value.split(",").map(p => p.to_owned()).to_array()
        guard cells.length() == 2 || cells.length() == 3 else {
          fail("LCOV malformed DA")
        }
        let number = lcov_number(cells[0])
        let count = lcov_number(cells[1])
        guard number > 0 && !seen.contains(number) else {
          fail("LCOV invalid or duplicate line")
        }
        seen[number] = true
        record_lines += 1
        total += 1
        guard total <= 10000 else {
          fail("LCOV exceeds 10000 line observations")
        }
        if count > 0 {
          covered += 1
          record_covered += 1
        }
        if !uncovered_only || count == 0 {
          rows += 1
          write([
            records.to_string(),
            (index + 1).to_string(),
            test_name,
            source_file,
            number.to_string(),
            count.to_string(),
            cells.get(2).unwrap_or(""),
          ])
        }
      }
      "LF" => {
        guard active && found is None else { fail("LCOV misplaced LF") }
        found = Some(lcov_number(value))
      }
      "LH" => {
        guard active && hit is None else { fail("LCOV misplaced LH") }
        hit = Some(lcov_number(value))
      }
      "FN" | "FNDA" | "FNF" | "FNH" | "BRDA" | "BRF" | "BRH" => {
        guard active else { fail("LCOV metadata outside record") }
        // Deliberately opaque: this view makes no function/branch claims.
      }
      _ => fail("LCOV unsupported tag")
    }
  }
  guard !active && !pending_test && records > 0 else {
    fail("LCOV incomplete or empty report")
  }
  (output.to_string(), records, total, covered, rows)
}

///|
/// Inspect coverage evidence only; never opens source paths or runs a tool.
pub async fn tabulate_retained_lcov(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  uncovered_only? : Bool = false,
) -> RetentionLcovTable {
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1048576L else {
    fail("LCOV requires a retained file of at most 1 MiB")
  }
  let (csv, record_count, line_count, covered_count, row_count) = retained_lcov_csv(
    @utf8.decode(export_retained_artifact(binding, path, config)),
    uncovered_only,
  )
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during LCOV projection")
  }
  let bytes = @utf8.encode(csv)
  let table : RetentionLcovTable = {
    binding,
    file,
    record_count,
    line_count,
    covered_count,
    row_count,
    uncovered_only,
    csv,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
  }
  guard @utf8.encode(table.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("LCOV context exceeds protocol budget")
  }
  table
}

///|
pub fn RetentionLcovTable::context(self : RetentionLcovTable) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-lcov-lines-csv-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "record_count": ToJson::to_json(self.record_count),
    "line_count": ToJson::to_json(self.line_count),
    "covered_count": ToJson::to_json(self.covered_count),
    "row_count": ToJson::to_json(self.row_count),
    "uncovered_only": ToJson::to_json(self.uncovered_only),
    "row_semantics": "DA observations in original order; repeated TN/SF records are separate, not merged",
    "report_line_semantics": "one-based physical DA line in original report",
    "coverage_semantics": "line-only; hits greater than zero are covered; counts include all records before filtering",
    "omitted_metadata": ["FN", "FNDA", "FNF", "FNH", "BRDA", "BRF", "BRH"],
    "path_semantics": "source_file is opaque and is never opened",
    "candidate_fingerprint": ToJson::to_json(self.candidate_fingerprint),
    "candidate_size_bytes": ToJson::to_json(self.candidate_size_bytes),
  }
}

///|
pub extend RetentionLcovTable with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionLcovTable with ToJson::{to_json}

///|
pub extend RetentionLcovTable with @moonbitlang/core/json.FromJson::{from_json}
