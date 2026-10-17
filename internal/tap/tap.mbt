///|
/// A top-level observation; diagnostic lines remain opaque text.
pub(all) struct Point {
  number : Int
  report_line : Int
  status : String
  description : String
  directive : String
  reason : String
  diagnostics : Array[String]
} derive(Debug, Eq)

///|
pub(all) struct Report {
  points : Array[Point]
  plan : Int?
  skip_reason : String
  bailout : String?
  bailout_line : Int?
} derive(Debug, Eq)

///|
fn number(value : String) -> Int raise {
  guard !value.is_empty() && value.length() <= 5 else {
    fail("TAP invalid test number or plan")
  }
  for c in value {
    guard c >= '0' && c <= '9' else { fail("TAP expected decimal number") }
  }
  let result = @string.parse_int(value)
  guard result <= 10000 else { fail("TAP exceeds 10000 test points") }
  result
}

///|
fn directive(value : String) -> (String, String) raise {
  let value = value.trim().to_owned()
  let mut end = 0
  while end < value.length() && value[end] != ' ' && value[end] != '\t' {
    end += 1
  }
  let key = value[:end].to_owned().to_upper()
  guard key == "TODO" || key == "SKIP" || key == "SKIPPED:" else {
    fail("TAP unsupported directive")
  }
  (if key == "TODO" { "TODO" } else { "SKIP" }, value[end:].trim().to_owned())
}

///|
/// Read a bounded flat TAP report. YAML diagnostics are preserved, never evaluated.
pub fn parse(text : String) -> Report raise {
  guard @utf8.encode(text).length() <= 1048576 else {
    fail("TAP exceeds 1 MiB")
  }
  let points : Array[Point] = []
  let mut plan : Int? = None
  let mut skip_reason = ""
  let mut trailing_plan = false
  let mut bailout : String? = None
  let mut bailout_line : Int? = None
  let mut yaml_indent : String? = None
  let mut yaml_allowed = false
  let mut attach_comments = false
  let lines = text.split("\n").to_array()
  for index, raw in lines {
    let line = raw.trim_end(chars="\r").to_owned()
    let trimmed = line.trim().to_owned()
    if yaml_indent is Some(indent) {
      guard line.has_prefix(indent) || trimmed.is_empty() else {
        fail("TAP unterminated diagnostic block")
      }
      points[points.length() - 1].diagnostics.push(line)
      if line == indent + "..." {
        yaml_indent = None
      }
      continue
    }
    if trimmed.is_empty() {
      continue
    }
    if line == "TAP version 13" {
      guard index == 0 else { fail("TAP version must be first line") }
      continue
    }
    if trimmed.has_prefix("# Subtest:") {
      fail("TAP nested subtests are outside this flat report view")
    }
    if trimmed.has_prefix("#") {
      if attach_comments {
        points[points.length() - 1].diagnostics.push(line)
      }
      yaml_allowed = false
      continue
    }
    guard bailout is None else { fail("TAP content after bailout") }
    if trimmed == "---" && line != trimmed {
      guard yaml_allowed else {
        fail("TAP diagnostic block must follow a test")
      }
      let offset = line.find("---").unwrap()
      yaml_indent = Some(line[:offset].to_owned())
      points[points.length() - 1].diagnostics.push(line)
      yaml_allowed = false
      continue
    }
    yaml_allowed = false
    if line.has_prefix("Bail out!") {
      bailout = Some(line[9:].trim().to_owned())
      bailout_line = Some(index + 1)
      attach_comments = false
      continue
    }
    if line.has_prefix("1..") {
      guard plan is None else { fail("TAP duplicate plan") }
      let parts = line[3:].split("#").to_array()
      let count = number(parts[0].trim().to_owned())
      if parts.length() > 1 {
        let (kind, reason) = directive(
          parts[1:].map(p => p.to_owned()).join("#"),
        )
        guard kind == "SKIP" && count == 0 else {
          fail("TAP skip plan must declare zero tests")
        }
        skip_reason = reason
      }
      plan = Some(count)
      trailing_plan = !points.is_empty()
      attach_comments = false
      continue
    }
    guard !trailing_plan else { fail("TAP test after trailing plan") }
    let passed = line == "ok" ||
      line.has_prefix("ok ") ||
      line.has_prefix("ok\t")
    let failed = line == "not ok" ||
      line.has_prefix("not ok ") ||
      line.has_prefix("not ok\t")
    guard passed || failed else { fail("TAP unsupported or malformed line") }
    let body = line[if passed { 2 } else { 6 }:].trim().to_owned()
    let pieces = body.split("#").to_array()
    let mut description = pieces[0].trim().to_owned()
    let mut digit_end = 0
    while digit_end < description.length() &&
          description[digit_end] >= '0' &&
          description[digit_end] <= '9' {
      digit_end += 1
    }
    let sequence = points.length() + 1
    guard sequence <= 10000 else { fail("TAP exceeds 10000 test points") }
    if digit_end > 0 {
      guard digit_end == description.length() ||
        description[digit_end] == ' ' ||
        description[digit_end] == '\t' else {
        fail("TAP ambiguous test number")
      }
      guard number(description[:digit_end].to_owned()) == sequence else {
        fail("TAP test numbers must be sequential")
      }
      description = description[digit_end:].trim().to_owned()
    }
    if description == "-" || description.has_prefix("- ") {
      description = description[1:].trim().to_owned()
    }
    let (kind, reason) = if pieces.length() > 1 {
      directive(pieces[1:].map(p => p.to_owned()).join("#"))
    } else {
      ("", "")
    }
    let status = if kind == "SKIP" {
      "skipped"
    } else if kind == "TODO" {
      if passed {
        "unexpected-pass"
      } else {
        "todo"
      }
    } else if passed {
      "passed"
    } else {
      "failed"
    }
    points.push({
      number: sequence,
      report_line: index + 1,
      status,
      description,
      directive: kind,
      reason,
      diagnostics: [],
    })
    yaml_allowed = true
    attach_comments = true
  }
  guard yaml_indent is None else { fail("TAP unterminated diagnostic block") }
  if plan is Some(count) {
    guard (bailout is Some(_) && points.length() <= count) ||
      count == points.length() else {
      fail("TAP plan does not match observed tests")
    }
  }
  guard !points.is_empty() || plan == Some(0) || bailout is Some(_) else {
    fail("TAP has no test points, skip plan or bailout")
  }
  { points, plan, skip_reason, bailout, bailout_line, }
}

///|
pub extend Point with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend Point with Eq::{not_equal, equal}

///|
pub extend Report with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend Report with Eq::{not_equal, equal}
