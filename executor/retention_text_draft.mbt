///|
/// A local plain-text candidate. Neither the candidate nor its context is an
/// execution receipt, retained artifact, approval, or promotion authorization.
pub(all) struct RetentionTextDraft {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  recipe_fingerprint : String
  recipe_size_bytes : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  operation_count : Int
  source_lines : Int
  candidate_lines : Int
  text : String
} derive(Debug, ToJson, FromJson)

///|
priv struct RetainedTextEdit {
  start_line : Int
  end_line : Int
  expected : String
  replacement : String
}

///|
fn text_edit_position(fields : Map[String, Json], key : String) -> Int raise {
  guard fields.get(key) is Some(value) && value is Number(_, ..) else {
    fail("text edit requires a canonical positive integer " + key)
  }
  let raw = value.stringify()
  let mut position = 0
  for ch in raw {
    guard ch >= '0' && ch <= '9' && position <= 2001 else {
      fail("text edit requires a canonical positive integer " + key)
    }
    position = position * 10 + ch.to_int() - '0'.to_int()
  }
  guard position >= 1 && position <= 2001 else {
    fail("text edit line boundary is outside 1..2001")
  }
  position
}

///|
fn text_draft_lines(text : String) -> (String, Array[String]) raise {
  guard @utf8.encode(text).length() <= 262_144 else {
    fail("text editing supports at most 256 KiB per file")
  }
  guard text
    .iter()
    .all(c => {
      (c >= ' ' || c == '\n' || c == '\r' || c == '\t') &&
      !(c >= '\u{7f}' && c <= '\u{9f}')
    }) else {
    fail("text editing refuses binary control characters")
  }
  let bom = if text.has_prefix("\u{feff}") { "\u{feff}" } else { "" }
  let body = text[bom.length():].to_owned()
  let parts = body.split("\n").map(part => part.to_owned()).collect()
  let lines : Array[String] = []
  for index, part in parts {
    if index + 1 < parts.length() {
      lines.push(part + "\n")
    } else if !part.is_empty() {
      lines.push(part)
    }
  }
  guard lines.length() <= 2000 else {
    fail("text editing supports at most 2000 lines per file")
  }
  (bom, lines)
}

///|
fn retained_text_edits(
  recipe : Bytes,
) -> (String, Array[RetainedTextEdit]) raise {
  guard recipe.length() <= 65_536 else {
    fail("text edit recipe exceeds 64 KiB")
  }
  let document = parse_retained_json(@utf8.decode(recipe))
  guard document is Object(fields) &&
    fields.length() == 3 &&
    fields.get("version") is Some(version) &&
    version.stringify() == "1" &&
    fields.get("source_fingerprint") is Some(String(fingerprint)) &&
    fields.get("operations") is Some(Array(operations)) else {
    fail(
      "text edit recipe requires version 1, source_fingerprint and operations",
    )
  }
  guard fingerprint.length() == 64 &&
    fingerprint
    .iter()
    .all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) else {
    fail("source_fingerprint requires lowercase SHA-256")
  }
  guard operations.length() >= 1 && operations.length() <= 100 else {
    fail("text edit recipe requires 1..100 operations")
  }
  let edits = operations.map(operation => {
    guard operation is Object(fields) &&
      fields.length() == 4 &&
      fields.get("expected") is Some(String(expected)) &&
      fields.get("replacement") is Some(String(replacement)) else {
      fail(
        "text edit requires exactly start_line, end_line, expected and replacement",
      )
    }
    let start_line = text_edit_position(fields, "start_line")
    let end_line = text_edit_position(fields, "end_line")
    guard start_line <= end_line else { fail("text edit range is reversed") }
    { start_line, end_line, expected, replacement, }
  })
  edits.sort_by_key(edit => edit.start_line)
  for i in 1..<edits.length() {
    guard edits[i - 1].end_line <= edits[i].start_line &&
      edits[i - 1].start_line != edits[i].start_line else {
      fail("text edit ranges overlap or share an ambiguous insertion boundary")
    }
  }
  (fingerprint, edits)
}

///|
fn apply_retained_text_edits(
  source : String,
  edits : Array[RetainedTextEdit],
) -> (String, Int, Int) raise {
  let (bom, lines) = text_draft_lines(source)
  // Validate every original range and exact expected slice before construction.
  for edit in edits {
    guard edit.start_line <= edit.end_line &&
      edit.end_line <= lines.length() + 1 else {
      fail("text edit range is outside the original file")
    }
    let expected = lines[edit.start_line - 1:edit.end_line - 1]
      .to_owned()
      .join("")
    guard expected == edit.expected else {
      fail("text edit expected text does not match original range")
    }
  }
  let output = StringBuilder()
  output.write_string(bom)
  let mut cursor = 0
  let mut size = @utf8.encode(bom).length()
  for edit in edits {
    for i in cursor..<(edit.start_line - 1) {
      output.write_string(lines[i])
      size += @utf8.encode(lines[i]).length()
    }
    size += @utf8.encode(edit.replacement).length()
    guard size <= 262_144 else { fail("text candidate exceeds 256 KiB") }
    output.write_string(edit.replacement)
    cursor = edit.end_line - 1
  }
  for i in cursor..<lines.length() {
    output.write_string(lines[i])
  }
  let candidate = output.to_string()
  let (_, candidate_lines) = text_draft_lines(candidate)
  (candidate, lines.length(), candidate_lines.length())
}

///|
/// Apply a fingerprint-bound local recipe to verified retained UTF-8 text.
/// Ranges are original one-based half-open line boundaries, with LF/CRLF kept
/// inside each line. The leading BOM is excluded from ranges and preserved.
/// Equal boundaries insert (expected must be empty); an empty replacement
/// deletes. N+1 is the EOF boundary. Nonoverlapping edits are sorted by start.
/// No original file, receipt, grant, or destination is changed.
pub async fn draft_retained_text(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  recipe : Bytes,
) -> RetentionTextDraft {
  let (fingerprint, edits) = retained_text_edits(recipe)
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 262_144L else {
    fail("text editing requires a retained file of at most 256 KiB")
  }
  guard file.fingerprint == fingerprint else {
    fail("text edit recipe does not match the inspected source fingerprint")
  }
  let source = export_retained_artifact(binding, path, config)
  let (text, source_lines, candidate_lines) = apply_retained_text_edits(
    @utf8.decode(source),
    edits,
  )
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during text editing")
  }
  let bytes = @utf8.encode(text)
  let result : RetentionTextDraft = {
    binding,
    file,
    recipe_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(recipe)),
    recipe_size_bytes: recipe.length(),
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    operation_count: edits.length(),
    source_lines,
    candidate_lines,
    text,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("text candidate context exceeds protocol budget")
  }
  result
}

///|
/// Portable derivation identity, without original or replacement text.
pub fn RetentionTextDraft::context(self : RetentionTextDraft) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-text-edits-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "recipe_fingerprint": ToJson::to_json(self.recipe_fingerprint),
    "recipe_size_bytes": ToJson::to_json(self.recipe_size_bytes),
    "candidate_fingerprint": ToJson::to_json(self.candidate_fingerprint),
    "candidate_size_bytes": ToJson::to_json(self.candidate_size_bytes),
    "operation_count": ToJson::to_json(self.operation_count),
    "source_lines": ToJson::to_json(self.source_lines),
    "candidate_lines": ToJson::to_json(self.candidate_lines),
    "addressing": "original-one-based-half-open-lines-excluding-leading-BOM",
  }
}

///|
pub extend RetentionTextDraft with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionTextDraft with ToJson::{to_json}

///|
pub extend RetentionTextDraft with @moonbitlang/core/json.FromJson::{from_json}
