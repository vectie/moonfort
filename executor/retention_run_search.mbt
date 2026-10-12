///|
pub(all) struct RetentionRunMatch {
  file : @sandbox.ScratchEntry
  hit : RetentionTextMatch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionSearchOmission {
  file : @sandbox.ScratchEntry
  reason : String
  bytes_verified : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionRunSearch {
  binding : RetentionArtifactBinding
  query : String
  ignore_ascii_case : Bool
  prefix : String
  contains : String
  selected_files : Int
  searched_files : Int
  searched_bytes : Int64
  matching_files : Int
  matching_lines : Int
  skipped_files : Array[RetentionSearchOmission]
  matches : Array[RetentionRunMatch]
  next_after_path : String
  next_after_line : Int
  has_more : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct RetentionSearchText {
  file : @sandbox.ScratchEntry
  text : String
}

///|
fn retained_run_total_lines(text : String, lines : Array[StringView]) -> Int {
  if text.is_empty() {
    0
  } else if text.has_suffix("\n") {
    lines.length() - 1
  } else {
    lines.length()
  }
}

///|
/// Search all selected retained files in lexical path / one-based line order.
/// Prefix and contains are literal case-sensitive path filters. Reuse the same
/// binding, query and filters with both returned cursors to resume. At most 128
/// files may be selected, with at most 8 MiB of files eligible for text search.
/// Files over 1 MiB, invalid UTF-8 and NUL-containing content are explicitly
/// omitted; a byte verification/read failure refuses the entire request.
/// Counts cover the entire selected corpus on every page, not just this page.
/// This reads retained evidence only, never executes or promotes artifacts.
pub async fn search_retained_run(
  binding : RetentionArtifactBinding,
  query : String,
  config : ExecutorConfig,
  prefix? : String = "",
  contains? : String = "",
  after_path? : String = "",
  after_line? : Int = 0,
  limit? : Int = 20,
  ignore_ascii_case? : Bool = false,
) -> RetentionRunSearch {
  guard !query.is_empty() &&
    @utf8.encode(query).length() <= 128 &&
    !query.contains("\n") &&
    !query.contains("\r") &&
    !query.contains("\u{0}") &&
    prefix.length() <= 4096 &&
    contains.length() <= 4096 &&
    after_path.length() <= 4096 &&
    after_line >= 0 &&
    (!after_path.is_empty() || after_line == 0) &&
    limit >= 1 &&
    limit <= 100 else {
    fail("invalid run search query, filters or page")
  }
  let record = bound_artifact_record(binding, config)
  let files = record.reviewable_files.filter(file => {
    file.relative_path.has_prefix(prefix) &&
    file.relative_path.contains(contains)
  })
  guard files.length() <= 128 else {
    fail(
      "run search selects more than 128 files; narrow --prefix or --contains",
    )
  }
  files.sort_by((a, b) => a.relative_path[:].lexical_compare(b.relative_path[:]))
  let eligible_bytes = files.fold(init=0L, (sum, file) => {
    sum + (if file.size_bytes <= 1_048_576L { file.size_bytes } else { 0L })
  })
  guard eligible_bytes <= 8_388_608L else {
    fail(
      "run search selects more than 8 MiB of searchable files; narrow filters",
    )
  }
  let texts : Array[RetentionSearchText] = []
  let skipped_files : Array[RetentionSearchOmission] = []
  let needle = if ignore_ascii_case { query.to_lower() } else { query }
  let mut matching_files = 0
  let mut matching_lines = 0
  let mut searched_bytes = 0L
  let mut cursor_valid = after_path.is_empty()
  for file in files {
    if file.size_bytes > 1_048_576L {
      skipped_files.push({ file, reason: "over_1_mib", bytes_verified: false, })
      continue
    }
    // Keep verification outside the UTF-8 classification: changed or missing
    // evidence must never look like an ordinary skipped binary file.
    let bytes = export_retained_artifact(binding, file.relative_path, config)
    let text = match (try? @utf8.decode(bytes)) {
      Ok(text) => text
      Err(_) => {
        skipped_files.push({
          file,
          reason: "invalid_utf8",
          bytes_verified: true,
        })
        continue
      }
    }
    if text.contains("\u{0}") {
      skipped_files.push({ file, reason: "contains_nul", bytes_verified: true, })
      continue
    }
    let lines = text.split("\n").to_array()
    let total_lines = retained_run_total_lines(text, lines)
    if file.relative_path == after_path {
      cursor_valid = after_line <= total_lines
    }
    let mut in_file = 0
    for index in 0..<total_lines {
      let line = lines[index]
        .strip_suffix("\r")
        .unwrap_or(lines[index])
        .to_string()
      let searchable = if ignore_ascii_case { line.to_lower() } else { line }
      if searchable.find(needle) is Some(_) {
        in_file += 1
      }
    }
    matching_lines += in_file
    if in_file > 0 {
      matching_files += 1
    }
    searched_bytes += file.size_bytes
    texts.push({ file, text, })
  }
  guard cursor_valid else {
    fail("run search cursor must name a searched file and a valid line")
  }
  let matches : Array[RetentionRunMatch] = []
  let mut pending = 0
  let mut full = false
  let response = fn() -> RetentionRunSearch {
    {
      binding,
      query,
      ignore_ascii_case,
      prefix,
      contains,
      selected_files: files.length(),
      searched_files: texts.length(),
      searched_bytes,
      matching_files,
      matching_lines,
      skipped_files,
      matches: matches.copy(),
      next_after_path: if matches.is_empty() {
        after_path
      } else {
        matches[matches.length() - 1].file.relative_path
      },
      next_after_line: if matches.is_empty() {
        after_line
      } else {
        matches[matches.length() - 1].hit.line
      },
      has_more: pending > matches.length(),
    }
  }
  guard @utf8.encode(response().to_json().stringify()).length() + 64 <=
    config.limits.max_protocol_bytes else {
    fail("run search metadata exceeds response budget; narrow filters")
  }
  for source in texts {
    let order = source.file.relative_path[:].lexical_compare(after_path[:])
    if order < 0 {
      continue
    }
    let lines = source.text.split("\n").to_array()
    let total_lines = retained_run_total_lines(source.text, lines)
    for index in 0..<total_lines {
      if order == 0 && index + 1 <= after_line {
        continue
      }
      let line = lines[index]
        .strip_suffix("\r")
        .unwrap_or(lines[index])
        .to_string()
      let searchable = if ignore_ascii_case { line.to_lower() } else { line }
      if searchable.find(needle) is Some(position) {
        pending += 1
        if !full {
          matches.push({
            file: source.file,
            hit: retained_search_excerpt(
              line,
              position,
              query.length(),
              index + 1,
            ),
          })
          if matches.length() > limit ||
            @utf8.encode(response().to_json().stringify()).length() + 64 >
            config.limits.max_protocol_bytes {
            ignore(matches.pop())
            guard !matches.is_empty() else {
              fail("run search match exceeds response budget; narrow filters")
            }
            full = true
          }
        }
      }
    }
  }
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during run search")
  }
  let result = response()
  guard @utf8.encode(result.to_json().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("run search metadata exceeds response budget")
  }
  result
}
