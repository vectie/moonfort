///|
pub(all) struct RetentionTextMatch {
  line : Int
  excerpt : String
  omitted_before : Bool
  omitted_after : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionTextSearch {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  query : String
  ignore_ascii_case : Bool
  total_lines : Int
  matching_lines : Int
  matches : Array[RetentionTextMatch]
  next_after_line : Int
  has_more : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
fn retained_search_excerpt(
  line : String,
  position : Int,
  width : Int,
  number : Int,
) -> RetentionTextMatch {
  let start = (position - 40).max(0)
  let end = (position + width + 80).min(line.length())
  let out = StringBuilder::new()
  let mut offset = 0
  for character in line {
    let next = offset + (if character.to_int() > 65535 { 2 } else { 1 })
    if next > start && offset < end {
      out.write_char(character)
    }
    offset = next
  }
  {
    line: number,
    excerpt: out.to_string(),
    omitted_before: start > 0,
    omitted_after: end < line.length(),
  }
}

///|
/// Find literal text inside one verified UTF-8 retained artifact (at most 1 MiB).
/// Results count matching lines, not occurrences. Cursors are 1-based line
/// numbers exclusive of the previous result; reuse the same query and case mode.
/// Excerpts surround the first occurrence without splitting Unicode characters.
pub async fn search_retained_artifact(
  binding : RetentionArtifactBinding,
  path : String,
  query : String,
  config : ExecutorConfig,
  after_line? : Int = 0,
  limit? : Int = 20,
  ignore_ascii_case? : Bool = false,
) -> RetentionTextSearch {
  guard !query.is_empty() &&
    @utf8.encode(query).length() <= 128 &&
    !query.contains("\n") &&
    !query.contains("\r") &&
    !query.contains("\u{0}") &&
    after_line >= 0 &&
    limit >= 1 &&
    limit <= 100 else {
    fail("invalid retained search query or page")
  }
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("search requires a retained file of at most 1 MiB")
  }
  let text = @utf8.decode(export_retained_artifact(binding, path, config))
  guard !text.contains("\u{0}") else {
    fail("search requires text without NUL bytes")
  }
  let lines = text.split("\n").to_array()
  let total_lines = if text.is_empty() {
    0
  } else if text.has_suffix("\n") {
    lines.length() - 1
  } else {
    lines.length()
  }
  guard after_line <= total_lines else {
    fail("search cursor is beyond the end")
  }
  let needle = if ignore_ascii_case { query.to_lower() } else { query }
  let matches : Array[RetentionTextMatch] = []
  let mut matching_lines = 0
  let mut pending = 0
  let mut full = false
  let response = fn() -> RetentionTextSearch {
    {
      binding,
      file,
      query,
      ignore_ascii_case,
      total_lines,
      matching_lines,
      matches: matches.copy(),
      next_after_line: if matches.is_empty() {
        after_line
      } else {
        matches[matches.length() - 1].line
      },
      has_more: pending > matches.length(),
    }
  }
  for index = 0; index < total_lines; index = index + 1 {
    let line = lines[index]
      .strip_suffix("\r")
      .unwrap_or(lines[index])
      .to_string()
    let searchable = if ignore_ascii_case { line.to_lower() } else { line }
    if searchable.find(needle) is Some(position) {
      matching_lines += 1
      if index + 1 > after_line {
        pending += 1
        if !full {
          matches.push(
            retained_search_excerpt(line, position, query.length(), index + 1),
          )
          // Reserve space for growing counters and the final has_more flag.
          if matches.length() > limit ||
            @utf8.encode(response().to_json().stringify()).length() + 64 >
            config.limits.max_protocol_bytes {
            ignore(matches.pop())
            guard !matches.is_empty() else {
              fail("search metadata exceeds response budget")
            }
            full = true
          }
        }
      }
    }
  }
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during search")
  }
  let result = response()
  guard @utf8.encode(result.to_json().stringify()).length() <=
    config.limits.max_protocol_bytes else {
    fail("search metadata exceeds response budget")
  }
  result
}
