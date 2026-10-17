///|
pub struct TextDiff {
  patch : String
  added_lines : Int
  removed_lines : Int
} derive(Debug, Eq)

///|
fn lines(text : String) -> Array[String] raise {
  guard @utf8.encode(text).length() <= 262_144 else {
    fail("text diff supports at most 256 KiB per file")
  }
  guard text
    .iter()
    .all(c => {
      (c >= ' ' || c == '\n' || c == '\r' || c == '\t') &&
      !(c >= '\u{7f}' && c <= '\u{9f}')
    }) else {
    fail("text diff requires text without binary control characters")
  }
  if text.is_empty() {
    return []
  }
  let parts = text.split("\n").map(part => part.to_owned()).collect()
  let result : Array[String] = []
  for index = 0; index < parts.length(); index = index + 1 {
    if index < parts.length() - 1 {
      result.push(parts[index] + "\n")
    } else if !parts[index].is_empty() {
      result.push(parts[index])
    }
  }
  guard result.length() <= 2000 else {
    fail("text diff supports at most 2000 lines per file")
  }
  result
}

///|
fn range(start : Int, count : Int) -> String {
  if count == 1 {
    start.to_string()
  } else {
    "\{start},\{count}"
  }
}

///|
/// A bounded minimal line diff. Lines retain their LF/CRLF endings and missing
/// final newlines, so exporting the patch never silently normalizes content.
pub fn unified(
  before : String,
  after : String,
  old_label : String,
  new_label : String,
  context? : Int = 3,
) -> TextDiff raise {
  guard context >= 0 && context <= 20 else {
    fail("context must be between 0 and 20")
  }
  guard [old_label, new_label].all(label => {
    !label.is_empty() &&
    label.iter().all(c => c >= ' ' && !(c >= '\u{7f}' && c <= '\u{9f}'))
  }) else {
    fail("invalid diff label")
  }
  let left = lines(before)
  let right = lines(after)
  let width = right.length() + 1
  let lengths = Array::make((left.length() + 1) * width, 0)
  for i = left.length() - 1; i >= 0; i = i - 1 {
    for j = right.length() - 1; j >= 0; j = j - 1 {
      lengths[i * width + j] = if left[i] == right[j] {
        lengths[(i + 1) * width + j + 1] + 1
      } else {
        lengths[(i + 1) * width + j].max(lengths[i * width + j + 1])
      }
    }
  }
  // 0 = context, 1 = removed, 2 = added.
  let edits : Array[(Int, String)] = []
  let mut added_lines = 0
  let mut removed_lines = 0
  for i = 0, j = 0; i < left.length() || j < right.length(); {
    if i < left.length() && j < right.length() && left[i] == right[j] {
      edits.push((0, left[i]))
      continue i + 1, j + 1
    } else if i < left.length() &&
      (
        j == right.length() ||
        lengths[(i + 1) * width + j] >= lengths[i * width + j + 1]
      ) {
      edits.push((1, left[i]))
      removed_lines += 1
      continue i + 1, j
    } else {
      edits.push((2, right[j]))
      added_lines += 1
      continue i, j + 1
    }
  }
  if added_lines + removed_lines == 0 {
    return { patch: "", added_lines, removed_lines, }
  }
  let output = StringBuilder()
  // The tab terminates the filename unambiguously, including names with spaces.
  output.write_string("--- \{old_label}\t\n+++ \{new_label}\t\n")
  let mut old_line = 1
  let mut new_line = 1
  let mut cursor = 0
  while cursor < edits.length() {
    let mut change = cursor
    while change < edits.length() && edits[change].0 == 0 {
      change += 1
    }
    if change == edits.length() {
      break
    }
    let start = (change - context).max(cursor)
    // Join hunks whose context would overlap or touch.
    let mut last_change = change
    let mut scan = change + 1
    while scan < edits.length() {
      if edits[scan].0 != 0 {
        if scan - last_change - 1 > context * 2 {
          break
        }
        last_change = scan
      }
      scan += 1
    }
    let end = (last_change + context + 1).min(edits.length())
    while cursor < start {
      if edits[cursor].0 != 2 {
        old_line += 1
      }
      if edits[cursor].0 != 1 {
        new_line += 1
      }
      cursor += 1
    }
    let mut old_count = 0
    let mut new_count = 0
    for index = start; index < end; index = index + 1 {
      if edits[index].0 != 2 {
        old_count += 1
      }
      if edits[index].0 != 1 {
        new_count += 1
      }
    }
    let old_start = if old_count == 0 { old_line - 1 } else { old_line }
    let new_start = if new_count == 0 { new_line - 1 } else { new_line }
    output.write_string(
      "@@ -\{range(old_start, old_count)} +\{range(new_start, new_count)} @@\n",
    )
    for index = start; index < end; index = index + 1 {
      let (kind, line) = edits[index]
      output.write_string(
        if kind == 0 {
          " "
        } else if kind == 1 {
          "-"
        } else {
          "+"
        },
      )
      output.write_string(line)
      if !line.has_suffix("\n") {
        output.write_string("\n\\ No newline at end of file\n")
      }
    }
    old_line += old_count
    new_line += new_count
    cursor = end
  }
  { patch: output.to_string(), added_lines, removed_lines, }
}

///|
pub extend TextDiff with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend TextDiff with Eq::{not_equal, equal}
