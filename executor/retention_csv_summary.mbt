///|
/// A complete frequency summary derived from one verified retained CSV.
/// Group keys keep exact strings. This is a candidate, not a new receipt.
pub(all) struct RetentionCsvSummary {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  group_by : Array[Int]
  where_column : Int
  equals : String
  source_rows : Int
  matching_rows : Int
  group_count : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
priv struct RetainedCsvGroup {
  cells : Array[String]
  mut count : Int
  first_row : Int
}

///|
fn summarize_csv_records(
  records : Array[Array[String]],
  group_by : Array[Int],
  where_column : Int,
  equals : String,
) -> (String, Int, Int) raise {
  guard !group_by.is_empty() && group_by.length() <= 62 else {
    fail("CSV summary requires 1..62 group columns")
  }
  let width = records[0].length()
  for index, column in group_by {
    guard column >= 1 && column <= width && !group_by[:index].contains(column) else {
      fail(
        "CSV summary group columns must be distinct existing one-based columns",
      )
    }
  }
  guard where_column >= 0 &&
    where_column <= width &&
    @utf8.encode(equals).length() <= 16_384 &&
    (where_column != 0 || equals.is_empty()) else {
    fail("invalid CSV summary filter")
  }
  let groups : Array[RetainedCsvGroup] = []
  let index : Map[String, Int] = Map([])
  let mut matching_rows = 0
  for row in 1..<records.length() {
    let cells = records[row]
    if where_column != 0 && cells[where_column - 1] != equals {
      continue
    }
    matching_rows += 1
    let key = group_by.map(column => cells[column - 1])
    // JSON tuples preserve boundaries even for commas, quotes and newlines.
    let identity = key.to_json().stringify()
    match index.get(identity) {
      Some(position) => groups[position].count += 1
      None => {
        index[identity] = groups.length()
        groups.push({ cells: key, count: 1, first_row: row, })
      }
    }
  }
  groups.sort_by((a, b) => {
    if a.count != b.count {
      b.count - a.count
    } else {
      a.first_row - b.first_row
    }
  })
  let output = StringBuilder()
  let mut size = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    let record = enriched_csv_record(cells)
    size += @utf8.encode(record).length()
    guard size <= 1_048_576 else { fail("CSV summary candidate exceeds 1 MiB") }
    output.write_string(record)
  }
  write(
    group_by.map(column => records[0][column - 1]) +
    ["row_count", "first_source_row"],
  )
  for group in groups {
    write(group.cells + [group.count.to_string(), group.first_row.to_string()])
  }
  (output.to_string(), matching_rows, groups.length())
}

///|
/// Group all matching data records by exact tuples, ordered by descending count
/// then first source data-row position. Optional filtering uses exact strings.
/// Export includes selected headers, row_count and first_source_row (one-based,
/// excluding the header). Empty groups produce a header-only candidate. No rows
/// are silently dropped or truncated. Source/candidate are each at most 1 MiB.
/// No artifact, retained receipt, approval or destination is modified.
pub async fn summarize_retained_csv(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  group_by~ : Array[Int],
  where_column? : Int = 0,
  equals? : String = "",
) -> RetentionCsvSummary {
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("CSV summary requires a retained file of at most 1 MiB")
  }
  let records = parse_retained_csv(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let (csv, matching_rows, group_count) = summarize_csv_records(
    records, group_by, where_column, equals,
  )
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during CSV summary")
  }
  let bytes = @utf8.encode(csv)
  let result : RetentionCsvSummary = {
    binding,
    file,
    group_by: group_by.copy(),
    where_column,
    equals,
    source_rows: records.length() - 1,
    matching_rows,
    group_count,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    csv,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("CSV summary context exceeds protocol budget")
  }
  result
}

///|
/// Derivation context without candidate contents or local storage paths.
pub fn RetentionCsvSummary::context(self : RetentionCsvSummary) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-csv-frequency-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "group_by": self.group_by.to_json(),
    "where_column": self.where_column.to_json(),
    "equals": self.equals.to_json(),
    "source_rows": self.source_rows.to_json(),
    "matching_rows": self.matching_rows.to_json(),
    "excluded_rows": (self.source_rows - self.matching_rows).to_json(),
    "group_count": self.group_count.to_json(),
    "order": "count-descending-then-first-source-row",
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}

///|
pub extend RetentionCsvSummary with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionCsvSummary with ToJson::{to_json}

///|
pub extend RetentionCsvSummary with @moonbitlang/core/json.FromJson::{from_json}
