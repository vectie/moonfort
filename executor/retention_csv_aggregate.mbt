///|
/// Exact fixed-six-decimal rollup of one verified retained CSV. Blank numeric
/// cells are counted separately. This is a derived candidate, not a receipt.
pub(all) struct RetentionCsvAggregate {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  group_by : Array[Int]
  value_column : Int
  source_rows : Int
  group_count : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
priv struct RetainedNumericGroup {
  cells : Array[String]
  mut rows : Int
  mut count : Int
  mut sum : Int64
  mut minimum : Int64
  mut maximum : Int64
  first_row : Int
}

///|
// Parse decimal digits ourselves: no binary floating point or locale guessing.
// Values and running totals are bounded by 9e12, with six decimal places.
fn retained_decimal(text : String) -> Int64 raise {
  guard !text.is_empty() else { fail("empty decimal") }
  let negative = text[0] == '-'
  let start = if negative { 1 } else { 0 }
  let mut digits = 0
  let mut fraction = -1
  let mut value = 0L
  for i in start..<text.length() {
    let c = text[i]
    if c == '.' && fraction == -1 && digits > 0 {
      fraction = 0
    } else {
      guard c >= '0' && c <= '9' && fraction < 6 else {
        fail("expected plain decimal with at most six fractional digits")
      }
      let digit = (c.to_int() - 48).to_int64()
      guard value <= (9_000_000_000_000_000_000L - digit) / 10L else {
        fail("decimal exceeds magnitude 9000000000000")
      }
      value = value * 10L + digit
      digits += 1
      if fraction >= 0 {
        fraction += 1
      }
    }
  }
  guard digits > 0 && fraction != 0 else { fail("incomplete decimal") }
  let places = if fraction == -1 { 0 } else { fraction }
  for _ in places..<6 {
    guard value <= 900_000_000_000_000_000L else {
      fail("decimal exceeds magnitude 9000000000000")
    }
    value *= 10L
  }
  if negative {
    -value
  } else {
    value
  }
}

///|
fn retained_decimal_text(value : Int64) -> String {
  let magnitude = if value < 0L { -value } else { value }
  let whole = (magnitude / 1_000_000L).to_string()
  let fraction = (magnitude % 1_000_000L).to_string()
  (if value < 0L { "-" } else { "" }) +
  whole +
  "." +
  "0".repeat(6 - fraction.length()) +
  fraction
}

///|
fn aggregate_csv_records(
  records : Array[Array[String]],
  group_by : Array[Int],
  value_column : Int,
) -> (String, Int) raise {
  let width = records[0].length()
  guard group_by.length() <= 56 && value_column >= 1 && value_column <= width else {
    fail(
      "CSV aggregation requires an existing value column and at most 56 group columns",
    )
  }
  for index, column in group_by {
    guard column >= 1 && column <= width && !group_by[:index].contains(column) else {
      fail(
        "CSV aggregation group columns must be distinct existing one-based columns",
      )
    }
  }
  let groups : Array[RetainedNumericGroup] = []
  let index : Map[String, Int] = {}
  for row in 1..<records.length() {
    let cells = group_by.map(column => records[row][column - 1])
    let identity = cells.to_json().stringify()
    let position = match index.get(identity) {
      Some(position) => position
      None => {
        let position = groups.length()
        index[identity] = position
        groups.push({
          cells,
          rows: 0,
          count: 0,
          sum: 0L,
          minimum: 0L,
          maximum: 0L,
          first_row: row,
        })
        position
      }
    }
    let group = groups[position]
    group.rows += 1
    let text = records[row][value_column - 1]
    if text.is_empty() {
      continue
    }
    let value = retained_decimal(text) catch {
      _ =>
        fail(
          "invalid decimal at source data row \{row}, column \{value_column}",
        )
    }
    guard (value >= 0L && group.sum <= 9_000_000_000_000_000_000L - value) ||
      (value < 0L && group.sum >= -9_000_000_000_000_000_000L - value) else {
      fail(
        "CSV aggregate running sum exceeds magnitude 9000000000000 at source data row \{row}",
      )
    }
    group.sum += value
    if group.count == 0 || value < group.minimum {
      group.minimum = value
    }
    if group.count == 0 || value > group.maximum {
      group.maximum = value
    }
    group.count += 1
  }
  groups.sort_by((a, b) => {
    if a.count == 0 && b.count != 0 {
      1
    } else if b.count == 0 && a.count != 0 {
      -1
    } else if a.sum > b.sum {
      -1
    } else if a.sum < b.sum {
      1
    } else {
      a.first_row - b.first_row
    }
  })
  let output = StringBuilder()
  let mut size = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    let record = enriched_csv_record(cells)
    size += @utf8.encode(record).length()
    guard size <= 1_048_576 else {
      fail("CSV aggregate candidate exceeds 1 MiB")
    }
    output.write_string(record)
  }
  write(
    group_by.map(column => records[0][column - 1]) +
    [
      "row_count", "numeric_count", "blank_count", "sum", "minimum", "maximum", "mean",
      "first_source_row",
    ],
  )
  for group in groups {
    let stats = if group.count == 0 {
      ["", "", "", ""]
    } else {
      let count = group.count.to_int64()
      let mut mean = group.sum / count
      let remainder = group.sum % count
      if remainder * 2L >= count {
        mean += 1L
      }
      if remainder * 2L <= -count {
        mean -= 1L
      }
      [
        retained_decimal_text(group.sum),
        retained_decimal_text(group.minimum),
        retained_decimal_text(group.maximum),
        retained_decimal_text(mean),
      ]
    }
    write(
      group.cells +
      [
        group.rows.to_string(),
        group.count.to_string(),
        (group.rows - group.count).to_string(),
      ] +
      stats +
      [group.first_row.to_string()],
    )
  }
  (output.to_string(), groups.length())
}

///|
/// Roll up a chosen decimal column, optionally by exact group keys. No grouping
/// yields one total. Empty cells are missing; other invalid numbers refuse the
/// entire export. Exact sums/min/max use six decimal places. Mean rounds halfway
/// away from zero to six places. Rank descending sum, then original row.
pub async fn aggregate_retained_csv(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  value_column~ : Int,
  group_by? : Array[Int] = [],
) -> RetentionCsvAggregate {
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("CSV aggregation requires a retained file of at most 1 MiB")
  }
  let records = parse_retained_csv(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let (csv, group_count) = aggregate_csv_records(
    records, group_by, value_column,
  )
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during CSV aggregation")
  }
  let bytes = @utf8.encode(csv)
  let result : RetentionCsvAggregate = {
    binding,
    file,
    group_by: group_by.copy(),
    value_column,
    source_rows: records.length() - 1,
    group_count,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    csv,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("CSV aggregate context exceeds protocol budget")
  }
  result
}

///|
/// Source and candidate provenance without contents or local host paths.
pub fn RetentionCsvAggregate::context(self : RetentionCsvAggregate) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-csv-decimal-aggregate-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "group_by": self.group_by.to_json(),
    "value_column": self.value_column.to_json(),
    "source_rows": self.source_rows.to_json(),
    "group_count": self.group_count.to_json(),
    "decimal_places": 6,
    "mean_rounding": "half-away-from-zero",
    "blank_values": "excluded-from-numeric-statistics",
    "order": "sum-descending-then-first-source-row-missing-last",
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}
