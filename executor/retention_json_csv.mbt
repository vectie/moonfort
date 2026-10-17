///|
/// One CSV header and JSON Pointer relative to each selected array element.
pub(all) struct RetentionJsonColumn {
  header : String
  pointer : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// A CSV projection of retained JSON. Missing object fields and JSON nulls are
/// blank CSV cells; context reports their counts. Original bytes stay retained.
pub(all) struct RetentionJsonTable {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  mapping_fingerprint : String
  pointer : String
  columns : Array[RetentionJsonColumn]
  row_count : Int
  missing_cells : Int
  null_cells : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
fn retained_json_columns(
  mapping : Bytes,
) -> (String, Array[RetentionJsonColumn]) raise {
  guard mapping.length() <= 65_536 else {
    fail("JSON table mapping exceeds 64 KiB")
  }
  let document = parse_retained_json(@utf8.decode(mapping))
  guard document is Object(fields) &&
    fields.length() == 3 &&
    fields.get("version") is Some(version) &&
    version.stringify() == "1" &&
    fields.get("rows") is Some(String(pointer)) &&
    fields.get("columns") is Some(Array(columns)) else {
    fail("JSON table mapping requires version 1, rows pointer and columns")
  }
  retained_edit_tokens(pointer) |> ignore
  guard columns.length() >= 1 && columns.length() <= 64 else {
    fail("JSON table mapping requires 1..64 columns")
  }
  let names : Map[String, Bool] = Map([])
  let selected = columns.map(column => {
    guard column is Object(fields) &&
      fields.length() == 2 &&
      fields.get("header") is Some(String(header)) &&
      fields.get("pointer") is Some(String(pointer)) else {
      fail("JSON table column requires header and pointer")
    }
    guard !header.is_empty() &&
      header.length() <= 16_384 &&
      !header.contains("\u{0}") &&
      !names.contains(header) else {
      fail("JSON table headers must be nonempty, unique and bounded")
    }
    names[header] = true
    retained_edit_tokens(pointer) |> ignore
    RetentionJsonColumn::{ header, pointer, }
  })
  (pointer, selected)
}

///|
// A missing object member is a blank cell. A malformed array index, an absent
// array position or scalar traversal remains an error, not a silent blank.
fn retained_json_cell_at(root : Json, tokens : Array[String]) -> Json? raise {
  let mut current = root
  for token in tokens {
    current = match current {
      Object(fields) => {
        guard fields.get(token) is Some(value) else { return None }
        value
      }
      Array(values) => values[retained_edit_index(token, values.length())]
      _ => fail("JSON table column traverses a scalar")
    }
  }
  Some(current)
}

///|
fn retained_json_csv(
  selected : Json,
  columns : Array[RetentionJsonColumn],
  source_lines? : Array[Int],
  source_paths? : Array[String],
) -> (String, Int, Int, Int) raise {
  guard selected is Array(rows) else {
    fail("JSON table rows pointer must select an array")
  }
  guard source_lines is None || source_lines.unwrap().length() == rows.length() else {
    fail("JSON table source line count must match rows")
  }
  guard source_paths is None ||
    (source_lines is Some(_) && source_paths.unwrap().length() == rows.length()) else {
    fail("JSON table source paths require matching source lines and rows")
  }
  let tokens = columns.map(column => retained_edit_tokens(column.pointer))
  let output = StringBuilder()
  let mut size = 0
  let mut missing_cells = 0
  let mut null_cells = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    let record = enriched_csv_record(cells)
    size += @utf8.encode(record).length()
    guard size <= 1_048_576 else { fail("JSON table candidate exceeds 1 MiB") }
    output.write_string(record)
  }
  let headers = columns.map(column => column.header)
  write(
    if source_paths is Some(_) {
      ["__source_path", "__source_line"] + headers
    } else if source_lines is Some(_) {
      ["__source_line"] + headers
    } else {
      headers
    },
  )
  for row_index, row in rows {
    let cells : Array[String] = match source_lines {
      Some(lines) =>
        match source_paths {
          Some(paths) => [paths[row_index], lines[row_index].to_string()]
          None => [lines[row_index].to_string()]
        }
      None => []
    }
    for column_index, path in tokens {
      let cell = try {
        match retained_json_cell_at(row, path) {
          None => {
            missing_cells += 1
            ""
          }
          Some(Null) => {
            null_cells += 1
            ""
          }
          Some(String(value)) => value
          Some(Number(_, ..) | True | False as value) => value.stringify()
          Some(_) =>
            fail("JSON table cell selects a container; select a scalar field")
        }
      } catch {
        error => {
          let location = match source_lines {
            Some(lines) =>
              match source_paths {
                Some(paths) =>
                  "JSONL file \{paths[row_index].to_json().stringify()} source line \{lines[row_index]}"
                None => "JSONL source line \{lines[row_index]}"
              }
            None => "JSON table row \{row_index + 1}"
          }
          fail("\{location} column \{column_index + 1}: \{error}")
        }
      }
      guard cell.length() <= 16_384 && !cell.contains("\u{0}") else {
        fail("JSON table cell exceeds 16384 UTF-16 units or contains NUL")
      }
      cells.push(cell)
    }
    write(cells)
  }
  (output.to_string(), rows.length(), missing_cells, null_cells)
}

///|
/// Project a retained JSON array into CSV using a local version-1 mapping.
/// Mapping rows selects an array; ordered columns contain header and pointer
/// relative to each array element. Exact number spellings and string contents
/// are preserved. Missing object fields and null become blank cells. Selected
/// containers and invalid traversal refuse. No source or destination is written.
pub async fn tabulate_retained_json(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  mapping : Bytes,
) -> RetentionJsonTable {
  let (pointer, columns) = retained_json_columns(mapping)
  let (file, selected) = retained_json_source(binding, path, config, pointer)
  let (csv, row_count, missing_cells, null_cells) = retained_json_csv(
    selected, columns,
  )
  let bytes = @utf8.encode(csv)
  let result : RetentionJsonTable = {
    binding,
    file,
    mapping_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(mapping)),
    pointer,
    columns,
    row_count,
    missing_cells,
    null_cells,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    csv,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("JSON table context exceeds protocol budget")
  }
  result
}

///|
/// Reproducible column selection and hashes without candidate content.
pub fn RetentionJsonTable::context(self : RetentionJsonTable) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-json-csv-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "mapping_fingerprint": self.mapping_fingerprint.to_json(),
    "pointer": self.pointer.to_json(),
    "columns": self.columns.to_json(),
    "row_count": self.row_count.to_json(),
    "missing_cells": self.missing_cells.to_json(),
    "null_cells": self.null_cells.to_json(),
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}

///|
pub extend RetentionJsonColumn with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionJsonColumn with Eq::{not_equal, equal}

///|
pub extend RetentionJsonColumn with ToJson::{to_json}

///|
pub extend RetentionJsonColumn with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend RetentionJsonTable with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionJsonTable with ToJson::{to_json}

///|
pub extend RetentionJsonTable with @moonbitlang/core/json.FromJson::{from_json}
