///|
/// One exact-key row change. Row numbers count data records, not physical lines.
/// Missing rows are None, distinct from a present row containing empty cells.
pub(all) struct RetentionCsvChange {
  key : Array[String]
  change : String
  before_row : Int?
  after_row : Int?
  before : Array[String]?
  after : Array[String]?
  changed_columns : Array[Int]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A complete read-only comparison of two verified retained CSV artifacts.
/// Row ordering is ignored; columns must have identical ordered headers.
pub(all) struct RetentionCsvComparison {
  baseline : RetentionArtifactBinding
  candidate : RetentionArtifactBinding
  before_file : @sandbox.ScratchEntry
  after_file : @sandbox.ScratchEntry
  key_columns : Array[Int]
  headers : Array[String]
  baseline_rows : Int
  candidate_rows : Int
  added : Int
  removed : Int
  changed : Int
  unchanged : Int
  entries : Array[RetentionCsvChange]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn retained_csv_key_index(
  records : Array[Array[String]],
  columns : Array[Int],
  side : String,
) -> Map[String, Int] raise {
  let index : Map[String, Int] = Map([])
  for row in 1..<records.length() {
    let key = columns.map(column => records[row][column - 1])
    for position, value in key {
      guard !value.is_empty() else {
        fail(
          "\{side} CSV data row \{row} has an empty key in column \{columns[position]}",
        )
      }
    }
    // Encoding the tuple avoids collisions between compound keys containing
    // separators, quotes, or embedded newlines.
    let identity = ToJson::to_json(key).stringify()
    if index.get(identity) is Some(previous) {
      fail(
        "\{side} CSV data row \{row} repeats the key of data row \{previous}",
      )
    }
    index[identity] = row
  }
  index
}

///|
fn compare_retained_csv_records(
  left : Array[Array[String]],
  right : Array[Array[String]],
  columns : Array[Int],
) -> (Array[RetentionCsvChange], Int, Int, Int, Int) raise {
  guard left[0] == right[0] else {
    fail(
      "CSV headers must match exactly in order; compare schema changes separately",
    )
  }
  guard !columns.is_empty() && columns.length() <= left[0].length() else {
    fail("CSV comparison requires at least one existing key column")
  }
  for position, column in columns {
    guard column >= 1 &&
      column <= left[0].length() &&
      !columns[:position].contains(column) else {
      fail("CSV key columns must be distinct one-based column numbers")
    }
  }
  let old = retained_csv_key_index(left, columns, "baseline")
  let new = retained_csv_key_index(right, columns, "candidate")
  let keys : Map[String, Array[String]] = Map([])
  for (records, index) in [(left, old), (right, new)] {
    for identity, row in index {
      keys[identity] = columns.map(column => records[row][column - 1])
    }
  }
  let names = keys.keys().collect()
  names.sort_by((a, b) => {
    for position in 0..<columns.length() {
      let order = keys[a][position][:].lexical_compare(keys[b][position][:])
      if order != 0 {
        return order
      }
    }
    0
  })
  let entries : Array[RetentionCsvChange] = []
  let mut added = 0
  let mut removed = 0
  let mut changed = 0
  let mut unchanged = 0
  for identity in names {
    let before_row = old.get(identity)
    let after_row = new.get(identity)
    let before = before_row.map(row => left[row])
    let after = after_row.map(row => right[row])
    let changed_columns : Array[Int] = []
    let change = match (before, after) {
      (Some(a), Some(b)) => {
        for column in 1..<=left[0].length() {
          if a[column - 1] != b[column - 1] {
            changed_columns.push(column)
          }
        }
        if changed_columns.is_empty() {
          unchanged += 1
          continue
        }
        changed += 1
        "changed"
      }
      (None, Some(_)) => {
        added += 1
        "added"
      }
      (Some(_), None) => {
        removed += 1
        "removed"
      }
      _ => fail("CSV comparison key is missing from both inputs")
    }
    if change != "changed" {
      for column in 1..<=left[0].length() {
        changed_columns.push(column)
      }
    }
    entries.push({
      key: keys[identity],
      change,
      before_row,
      after_row,
      before,
      after,
      changed_columns,
    })
  }
  (entries, added, removed, changed, unchanged)
}

///|
/// Compare the same relative CSV path from two retained runs by an explicit
/// ordered tuple of key columns. Each key component must be nonempty and each
/// tuple unique per side. Ambiguous keys refuse with side and data-row numbers.
/// All cell values compare as exact strings without trimming or coercion.
/// Inputs are each at most 1 MiB; the complete JSON report is at most 4 MiB.
/// No execution, retained-state write, grant consumption, or promotion occurs.
pub async fn compare_retained_csv(
  baseline : RetentionArtifactBinding,
  candidate : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  key_columns~ : Array[Int],
) -> RetentionCsvComparison {
  let left_record = bound_artifact_record(baseline, config)
  let right_record = bound_artifact_record(candidate, config)
  guard left_record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(before_file) &&
    before_file.size_bytes <= 1_048_576L else {
    fail("baseline CSV requires a retained file of at most 1 MiB")
  }
  guard right_record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(after_file) &&
    after_file.size_bytes <= 1_048_576L else {
    fail("candidate CSV requires a retained file of at most 1 MiB")
  }
  let left = parse_retained_csv(
    @utf8.decode(export_retained_artifact(baseline, path, config)),
  )
  let right = parse_retained_csv(
    @utf8.decode(export_retained_artifact(candidate, path, config)),
  )
  let (entries, added, removed, changed, unchanged) = compare_retained_csv_records(
    left, right, key_columns,
  )
  let result : RetentionCsvComparison = {
    baseline,
    candidate,
    before_file,
    after_file,
    key_columns: key_columns.copy(),
    headers: left[0],
    baseline_rows: left.length() - 1,
    candidate_rows: right.length() - 1,
    added,
    removed,
    changed,
    unchanged,
    entries,
  }
  guard @utf8.encode(result.to_json().stringify()).length() + 1 <= 4_194_304 else {
    fail("CSV comparison JSON report exceeds 4 MiB; use verified file exports")
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("CSV comparison context exceeds protocol budget")
  }
  guard bound_artifact_record(baseline, config) == left_record &&
    bound_artifact_record(candidate, config) == right_record else {
    fail("retention changed during CSV comparison")
  }
  result
}

///|
/// Export one CSV row per changed cell, or every cell in an added/removed row.
/// The key is a JSON array inside one quoted CSV cell. Empty before/after values
/// on added/removed rows mean absence; change identifies which side is absent.
/// All fields are quoted; formulas remain strings and are not neutralized.
pub fn RetentionCsvComparison::to_csv(
  self : RetentionCsvComparison,
) -> String raise {
  let output = StringBuilder()
  let mut size = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    let row = enriched_csv_record(cells)
    size += @utf8.encode(row).length()
    guard size <= 4_194_304 else { fail("CSV comparison export exceeds 4 MiB") }
    output.write_string(row)
  }
  write([
    "change", "key", "before_row", "after_row", "column", "header", "before", "after",
  ])
  for entry in self.entries {
    for column in entry.changed_columns {
      write([
        entry.change,
        ToJson::to_json(entry.key).stringify(),
        entry.before_row.map(row => row.to_string()).unwrap_or(""),
        entry.after_row.map(row => row.to_string()).unwrap_or(""),
        column.to_string(),
        self.headers[column - 1],
        entry.before.map(row => row[column - 1]).unwrap_or(""),
        entry.after.map(row => row[column - 1]).unwrap_or(""),
      ])
    }
  }
  output.to_string()
}

///|
/// Source identities and complete row counts for the long-form CSV export.
/// This is a local inspection report, not a signed attestation or promotion.
pub fn RetentionCsvComparison::context(self : RetentionCsvComparison) -> Json {
  {
    "format": "moonfort-keyed-csv-comparison-v1",
    "review_only": true,
    "baseline": self.baseline.to_json(),
    "candidate": self.candidate.to_json(),
    "before_file": self.before_file.to_json(),
    "after_file": self.after_file.to_json(),
    "key_columns": ToJson::to_json(self.key_columns),
    "headers": ToJson::to_json(self.headers),
    "baseline_rows": ToJson::to_json(self.baseline_rows),
    "candidate_rows": ToJson::to_json(self.candidate_rows),
    "added": ToJson::to_json(self.added),
    "removed": ToJson::to_json(self.removed),
    "changed": ToJson::to_json(self.changed),
    "unchanged": ToJson::to_json(self.unchanged),
  }
}

///|
pub extend RetentionCsvChange with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionCsvChange with Eq::{not_equal, equal}

///|
pub extend RetentionCsvChange with ToJson::{to_json}

///|
pub extend RetentionCsvChange with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend RetentionCsvComparison with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionCsvComparison with Eq::{not_equal, equal}

///|
pub extend RetentionCsvComparison with ToJson::{to_json}

///|
pub extend RetentionCsvComparison with @moonbitlang/core/json.FromJson::{
  from_json,
}
