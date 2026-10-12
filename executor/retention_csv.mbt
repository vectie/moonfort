///|
pub(all) struct RetentionCsvRow {
  row : Int
  cells : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionCsvPage {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  columns : Array[Int]
  headers : Array[String]
  where_column : Int
  equals : String
  total_rows : Int
  matching_rows : Int
  rows : Array[RetentionCsvRow]
  next_after_row : Int
  has_more : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
priv enum RetainedCsvState {
  Unquoted
  Quoted
  ClosedQuote
}

///|
// The first logical record is the header. Blank/duplicate names are kept;
// numeric, one-based column selection makes them unambiguous.
fn parse_retained_csv(text : String) -> Array[Array[String]] raise {
  guard !text.contains("\u{0}") else { fail("CSV contains NUL") }
  let records : Array[Array[String]] = []
  let mut fields : Array[String] = []
  let mut cell = StringBuilder()
  let mut cell_units = 0
  let mut state = Unquoted
  let mut skip_lf = false
  let mut dirty = false
  let source = text.strip_prefix("\u{feff}").unwrap_or(text[:])
  for character in source {
    if skip_lf {
      skip_lf = false
      if character == '\n' {
        continue
      }
    }
    if state is Quoted {
      if character == '"' {
        state = ClosedQuote
      } else {
        cell.write_char(character)
        cell_units += if character.to_int() > 65535 { 2 } else { 1 }
      }
    } else if character == ',' || character == '\n' || character == '\r' {
      fields.push(cell.to_string())
      guard fields.length() <= 64 else { fail("CSV exceeds 64 columns") }
      cell = StringBuilder()
      cell_units = 0
      state = Unquoted
      dirty = character == ','
      if character != ',' {
        if !records.is_empty() && fields.length() != records[0].length() {
          fail("CSV records have different column counts")
        }
        records.push(fields)
        guard records.length() <= 20_001 else {
          fail("CSV exceeds 20000 data rows")
        }
        fields = []
        skip_lf = character == '\r'
      }
    } else if character == '"' {
      if state is ClosedQuote {
        cell.write_char('"')
        cell_units += 1
        state = Quoted
      } else {
        guard cell_units == 0 else { fail("quote inside unquoted CSV field") }
        state = Quoted
      }
      dirty = true
    } else {
      guard state is Unquoted else { fail("text after closing CSV quote") }
      cell.write_char(character)
      cell_units += if character.to_int() > 65535 { 2 } else { 1 }
      dirty = true
    }
    guard cell_units <= 16_384 else {
      fail("CSV field exceeds 16384 UTF-16 units")
    }
  }
  guard !(state is Quoted) else { fail("unterminated CSV quote") }
  if dirty {
    fields.push(cell.to_string())
    guard fields.length() <= 64 else { fail("CSV exceeds 64 columns") }
    if !records.is_empty() && fields.length() != records[0].length() {
      fail("CSV records have different column counts")
    }
    records.push(fields)
  }
  guard !records.is_empty() && records.length() <= 20_001 else {
    fail("CSV requires a header and at most 20000 data rows")
  }
  records
}

///|
/// Inspect a verified UTF-8 comma-separated artifact of at most 1 MiB.
/// Column numbers and data-row cursors are one-based; the header is not a data
/// row. Empty columns selects all. where_column=0 disables exact cell filtering.
/// Reuse the same columns/filter with next_after_row to continue the page.
///
/// ```mbt nocheck
/// let page = @executor.read_retained_csv(
///   binding,
///   "checks.csv",
///   config,
///   columns=[1, 4],
///   where_column=3,
///   equals="follow-up",
///   limit=10,
/// )
///
/// let selected_csv = page.to_csv()
/// ```
pub async fn read_retained_csv(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  columns? : Array[Int] = [],
  where_column? : Int = 0,
  equals? : String = "",
  after_row? : Int = 0,
  limit? : Int = 20,
) -> RetentionCsvPage {
  guard after_row >= 0 &&
    limit >= 1 &&
    limit <= 100 &&
    columns.length() <= 64 &&
    where_column >= 0 &&
    @utf8.encode(equals).length() <= 16_384 &&
    (where_column != 0 || equals.is_empty()) else {
    fail("invalid CSV selection or page")
  }
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("CSV requires a retained file of at most 1 MiB")
  }
  let records = parse_retained_csv(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let width = records[0].length()
  let selected = if columns.is_empty() {
    [
      for index in 1..<=width => index
    ]
  } else {
    columns.copy()
  }
  for index, column in selected {
    guard column >= 1 && column <= width && !selected[:index].contains(column) else {
      fail("CSV selection contains an invalid or repeated column")
    }
  }
  let total_rows = records.length() - 1
  guard where_column <= width && after_row <= total_rows else {
    fail("CSV filter or cursor is beyond the table")
  }
  let headers = selected.map(column => records[0][column - 1])
  let rows : Array[RetentionCsvRow] = []
  let mut matching_rows = 0
  let mut pending = 0
  let mut full = false
  let response = fn() -> RetentionCsvPage {
    {
      binding,
      file,
      columns: selected,
      headers,
      where_column,
      equals,
      total_rows,
      matching_rows,
      rows: rows.copy(),
      next_after_row: if rows.is_empty() {
        after_row
      } else {
        rows[rows.length() - 1].row
      },
      has_more: pending > rows.length(),
    }
  }
  for row in 1..<=total_rows {
    let cells = records[row]
    if where_column == 0 || cells[where_column - 1] == equals {
      matching_rows += 1
      if row > after_row {
        pending += 1
        if !full {
          rows.push({ row, cells: selected.map(column => cells[column - 1]), })
          if rows.length() > limit ||
            @utf8.encode(response().to_json().stringify()).length() + 64 >
            config.limits.max_protocol_bytes {
            ignore(rows.pop())
            guard !rows.is_empty() else {
              fail("CSV row exceeds response budget; select fewer columns")
            }
            full = true
          }
        }
      }
    }
  }
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during CSV inspection")
  }
  let result = response()
  guard @utf8.encode(result.to_json().stringify()).length() <=
    config.limits.max_protocol_bytes else {
    fail("CSV metadata exceeds response budget")
  }
  result
}

///|
/// Re-encode just this page as CSV with a header and CRLF record endings.
/// All cells are quoted, original cell values are preserved, and no formulas
/// are evaluated or neutralized. This is a derived selection, not exact bytes.
///
/// ```mbt nocheck
/// let output = page.to_csv() // Header plus just this page's selected rows.
/// ```
pub fn RetentionCsvPage::to_csv(self : RetentionCsvPage) -> String {
  let output = StringBuilder()
  let write_record = fn(cells : Array[String]) {
    for index, cell in cells {
      if index > 0 {
        output.write_char(',')
      }
      output.write_char('"')
      output.write_string(cell.replace_all(old="\"", new="\"\""))
      output.write_char('"')
    }
    output.write_string("\r\n")
  }
  write_record(self.headers)
  for row in self.rows {
    write_record(row.cells)
  }
  output.to_string()
}
