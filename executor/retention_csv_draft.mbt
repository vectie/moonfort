///|
/// A local edited CSV candidate, not retained execution evidence or approval.
/// Keep the exact recipe bytes, candidate CSV and context together.
pub(all) struct RetentionCsvDraft {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  recipe_fingerprint : String
  recipe_size_bytes : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  operation_count : Int
  source_rows : Int
  candidate_rows : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
priv enum RetainedCsvEdit {
  SetCell(Int, Int, String)
  RemoveRow(Int)
  AppendRow(Array[String])
}

///|
fn csv_edit_position(fields : Map[String, Json], key : String) -> Int raise {
  guard fields.get(key) is Some(value) && value is Number(_, ..) else {
    fail("CSV edit requires a positive integer " + key)
  }
  let text = value.stringify()
  let mut value = 0
  for character in text {
    guard character >= '0' && character <= '9' && value <= 20_001 else {
      fail("CSV edit requires a canonical integer " + key)
    }
    value = value * 10 + character.to_int() - '0'.to_int()
  }
  guard value >= 1 && value <= 20_001 else {
    fail("CSV edit position is outside 1..20001")
  }
  value
}

///|
fn csv_edit_cell(value : Json) -> String raise {
  guard value is String(cell) &&
    cell.length() <= 16_384 &&
    !cell.contains("\u{0}") else {
    fail(
      "CSV edited cells require strings of at most 16384 UTF-16 units without NUL",
    )
  }
  cell
}

///|
fn retained_csv_edits(recipe : Bytes) -> (String, Array[RetainedCsvEdit]) raise {
  guard recipe.length() <= 65_536 else {
    fail("CSV edit recipe exceeds 64 KiB")
  }
  let document = parse_retained_json(@utf8.decode(recipe))
  guard document is Object(fields) &&
    fields.length() == 3 &&
    fields.get("version") is Some(version) &&
    version.stringify() == "1" &&
    fields.get("source_fingerprint") is Some(String(fingerprint)) &&
    fields.get("operations") is Some(Array(operations)) else {
    fail(
      "CSV edit recipe requires version 1, source_fingerprint and operations",
    )
  }
  guard fingerprint.length() == 64 &&
    fingerprint
    .iter()
    .all(character => {
      (character >= '0' && character <= '9') ||
      (character >= 'a' && character <= 'f')
    }) else {
    fail("CSV edit source_fingerprint requires lowercase SHA-256")
  }
  guard operations.length() >= 1 && operations.length() <= 100 else {
    fail("CSV edit recipe requires 1..100 operations")
  }
  let edits = operations.map(operation => {
    guard operation is Object(fields) && fields.get("op") is Some(String(op)) else {
      fail("CSV edit operation requires op")
    }
    match op {
      "set-cell" => {
        guard fields.length() == 4 && fields.get("value") is Some(value) else {
          fail("set-cell requires exactly op, row, column and value")
        }
        SetCell(
          csv_edit_position(fields, "row"),
          csv_edit_position(fields, "column"),
          csv_edit_cell(value),
        )
      }
      "remove-row" => {
        guard fields.length() == 2 else {
          fail("remove-row requires exactly op and row")
        }
        RemoveRow(csv_edit_position(fields, "row"))
      }
      "append-row" => {
        guard fields.length() == 2 &&
          fields.get("cells") is Some(Array(cells)) &&
          cells.length() >= 1 &&
          cells.length() <= 64 else {
          fail("append-row requires exactly op and 1..64 cells")
        }
        AppendRow(cells.map(csv_edit_cell))
      }
      _ => fail("unknown CSV edit operation")
    }
  })
  (fingerprint, edits)
}

///|
// Copy every record before editing. Row positions count current logical data
// rows, excluding the header, and later operations see earlier removals/appends.
fn apply_retained_csv_edits(
  source : Array[Array[String]],
  edits : Array[RetainedCsvEdit],
) -> (String, Int) raise {
  let mut records = source.map(row => row.copy())
  for index, edit in edits {
    try {
      match edit {
        SetCell(row, column, value) => {
          guard row >= 1 &&
            row < records.length() &&
            column >= 1 &&
            column <= records[0].length() else {
            fail("CSV cell is outside the current table")
          }
          records[row][column - 1] = value
        }
        RemoveRow(row) => {
          guard row >= 1 && row < records.length() else {
            fail("CSV row is outside the current table")
          }
          let remaining : Array[Array[String]] = []
          for position, record in records {
            if position != row {
              remaining.push(record)
            }
          }
          records = remaining
        }
        AppendRow(cells) => {
          guard cells.length() == records[0].length() else {
            fail("CSV appended row must match the header width")
          }
          guard records.length() < 20_001 else {
            fail("CSV candidate exceeds 20000 data rows")
          }
          records.push(cells.copy())
        }
      }
    } catch {
      error => fail("CSV edit operation \{index + 1} failed: \{error}")
    }
  }
  let output = StringBuilder()
  let mut size = 0
  for record in records {
    let text = enriched_csv_record(record)
    size += @utf8.encode(text).length()
    guard size <= 1_048_576 else { fail("CSV candidate exceeds 1 MiB") }
    output.write_string(text)
  }
  (output.to_string(), records.length() - 1)
}

///|
/// Correct cells, remove data rows or append rows to a verified retained CSV.
/// The version-1 local recipe pins the inspected source fingerprint. Operations
/// use current one-based logical data-row and column positions in sequence.
/// The header is preserved; exact cell strings are quoted with CRLF endings.
/// No original, grant, receipt or destination is written. This is a candidate
/// for separate review and cannot inherit its source's promotion authority.
///
/// ```mbt nocheck
/// let draft = @executor.draft_retained_csv(
///   binding, "checks.csv", config, recipe_bytes,
/// )
///
/// let candidate_bytes = @utf8.encode(draft.csv)
///
/// let context_json = draft.context().stringify() + "\n"
/// ```
pub async fn draft_retained_csv(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  recipe : Bytes,
) -> RetentionCsvDraft {
  let (fingerprint, edits) = retained_csv_edits(recipe)
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("CSV editing requires a retained file of at most 1 MiB")
  }
  guard file.fingerprint == fingerprint else {
    fail("CSV edit recipe does not match the inspected source fingerprint")
  }
  let source = parse_retained_csv(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let (csv, candidate_rows) = apply_retained_csv_edits(source, edits)
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during CSV editing")
  }
  let bytes = @utf8.encode(csv)
  let result : RetentionCsvDraft = {
    binding,
    file,
    recipe_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(recipe)),
    recipe_size_bytes: recipe.length(),
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    operation_count: edits.length(),
    source_rows: source.length() - 1,
    candidate_rows,
    csv,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("CSV candidate context exceeds protocol budget")
  }
  result
}

///|
/// Export local derivation context without candidate cells or local paths.
pub fn RetentionCsvDraft::context(self : RetentionCsvDraft) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-csv-edits-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "recipe_fingerprint": ToJson::to_json(self.recipe_fingerprint),
    "recipe_size_bytes": ToJson::to_json(self.recipe_size_bytes),
    "candidate_fingerprint": ToJson::to_json(self.candidate_fingerprint),
    "candidate_size_bytes": ToJson::to_json(self.candidate_size_bytes),
    "operation_count": ToJson::to_json(self.operation_count),
    "source_rows": ToJson::to_json(self.source_rows),
    "candidate_rows": ToJson::to_json(self.candidate_rows),
    "addressing": "sequential-current-one-based-data-rows-and-columns",
  }
}

///|
pub extend RetentionCsvDraft with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionCsvDraft with ToJson::{to_json}

///|
pub extend RetentionCsvDraft with @moonbitlang/core/json.FromJson::{from_json}
