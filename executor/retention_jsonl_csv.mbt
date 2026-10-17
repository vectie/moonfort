///|
/// A complete JSON Lines projection. The first CSV column, __source_line,
/// identifies the physical one-based source line, including skipped blanks.
pub(all) struct RetentionJsonLinesTable {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  mapping_fingerprint : String
  columns : Array[RetentionJsonColumn]
  total_lines : Int
  row_count : Int
  blank_lines_skipped : Int
  skip_blank_lines : Bool
  missing_cells : Int
  null_cells : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
fn retained_jsonl_columns(mapping : Bytes) -> Array[RetentionJsonColumn] raise {
  guard mapping.length() <= 65_536 else {
    fail("JSONL table mapping exceeds 64 KiB")
  }
  let document = parse_retained_json(@utf8.decode(mapping))
  guard document is Object(fields) &&
    fields.length() == 2 &&
    fields.get("version") is Some(version) &&
    version.stringify() == "1" &&
    fields.get("columns") is Some(Array(columns)) else {
    fail("JSONL table mapping requires version 1 and columns")
  }
  // Reuse the existing exact header/pointer rules. No JSONL rows selector:
  // every nonblank physical line is one complete JSON value and one CSV row.
  let (_, selected) = retained_json_columns(
    @utf8.encode(
      ({ "version": 1, "rows": "", "columns": ToJson::to_json(columns) } : Json).stringify(),
    ),
  )
  guard selected.length() <= 63 &&
    !selected.any(column => column.header == "__source_line") else {
    fail("JSONL requires 1..63 mapped columns; __source_line is reserved")
  }
  selected
}

///|
fn retained_jsonl_rows(
  text : String,
  skip_blank_lines : Bool,
) -> (Array[Json], Array[Int], Int, Int) raise {
  let (rows, lines, total, blanks, _) = retained_jsonl_rows_counted(
    text, skip_blank_lines, 0,
  )
  (rows, lines, total, blanks)
}

///|
// Share the same value budget across files when building a retained timeline.
fn retained_jsonl_rows_counted(
  text : String,
  skip_blank_lines : Bool,
  initial_values : Int,
) -> (Array[Json], Array[Int], Int, Int, Int) raise {
  guard initial_values >= 0 && initial_values <= 20_000 else {
    fail("invalid JSONL initial value budget")
  }
  let lines = text.split("\n").to_array()
  let total_lines = if text.is_empty() {
    0
  } else if text.has_suffix("\n") {
    lines.length() - 1
  } else {
    lines.length()
  }
  guard total_lines <= 20_000 else {
    fail("JSONL exceeds 20000 physical lines")
  }
  let rows : Array[Json] = []
  let source_lines : Array[Int] = []
  let mut values = initial_values
  let mut blanks = 0
  for index = 0; index < total_lines; index = index + 1 {
    let line = lines[index].to_owned()
    let blank = line.iter().all(ch => ch == ' ' || ch == '\t' || ch == '\r')
    if blank {
      guard skip_blank_lines else {
        fail(
          "JSONL source line \{index + 1} is blank; explicitly enable skipping",
        )
      }
      blanks += 1
      continue
    }
    let (value, count) = try {
      // Standard validation comes first. The retained reader then preserves
      // numeric lexemes and rejects duplicate decoded keys. Its counter spans
      // all records, so splitting a document never resets the value budget.
      validate_retained_json_syntax(line)
      let reader : RetainedJsonReader = {
        chars: line.iter().collect(),
        position: 0,
        values,
      }
      let value = reader.value()
      (value, reader.values)
    } catch {
      error => fail("JSONL source line \{index + 1}: \{error}")
    }
    values = count
    rows.push(value)
    source_lines.push(index + 1)
  }
  (rows, source_lines, total_lines, blanks, values)
}

///|
/// Project every retained JSONL/NDJSON record into scalar CSV columns and a
/// leading physical source-line column. Blank lines refuse unless explicitly
/// skipped. All records validate before any candidate is returned. Source and
/// mapping remain unchanged; no workload executes and no file is promoted.
pub async fn tabulate_retained_jsonl(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  mapping : Bytes,
  skip_blank_lines? : Bool = false,
) -> RetentionJsonLinesTable {
  let columns = retained_jsonl_columns(mapping)
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("JSONL requires a retained file of at most 1 MiB")
  }
  let text = @utf8.decode(export_retained_artifact(binding, path, config))
  let (rows, source_lines, total_lines, blank_lines_skipped) = retained_jsonl_rows(
    text, skip_blank_lines,
  )
  let (csv, row_count, missing_cells, null_cells) = retained_json_csv(
    Json::array(rows),
    columns,
    source_lines~,
  )
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during JSONL projection")
  }
  let bytes = @utf8.encode(csv)
  let result : RetentionJsonLinesTable = {
    binding,
    file,
    mapping_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(mapping)),
    columns,
    total_lines,
    row_count,
    blank_lines_skipped,
    skip_blank_lines,
    missing_cells,
    null_cells,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    csv,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("JSONL table context exceeds protocol budget")
  }
  result
}

///|
/// Provenance and format choices, without the candidate payload.
pub fn RetentionJsonLinesTable::context(self : RetentionJsonLinesTable) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-jsonl-csv-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "mapping_fingerprint": ToJson::to_json(self.mapping_fingerprint),
    "source_line_column": "__source_line",
    "columns": ToJson::to_json(self.columns),
    "total_lines": ToJson::to_json(self.total_lines),
    "row_count": ToJson::to_json(self.row_count),
    "skip_blank_lines": ToJson::to_json(self.skip_blank_lines),
    "blank_lines_skipped": ToJson::to_json(self.blank_lines_skipped),
    "missing_cells": ToJson::to_json(self.missing_cells),
    "null_cells": ToJson::to_json(self.null_cells),
    "candidate_fingerprint": ToJson::to_json(self.candidate_fingerprint),
    "candidate_size_bytes": ToJson::to_json(self.candidate_size_bytes),
  }
}

///|
pub extend RetentionJsonLinesTable with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionJsonLinesTable with ToJson::{to_json}

///|
pub extend RetentionJsonLinesTable with @moonbitlang/core/json.FromJson::{
  from_json,
}
