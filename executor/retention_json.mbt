///|
pub(all) struct RetentionJsonEntry {
  pointer : String
  kind : String
  child_count : Int
  preview : String
  preview_truncated : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionJsonPage {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  selected : RetentionJsonEntry
  children : Array[RetentionJsonEntry]
  next_after_child : Int
  has_more : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionJsonSelection {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  pointer : String
  value : Json
} derive(Debug, ToJson, FromJson)

///|
priv struct RetainedJsonReader {
  chars : Array[Char]
  mut position : Int
  mut values : Int
}

///|
fn RetainedJsonReader::space(self : RetainedJsonReader) -> Unit {
  while self.position < self.chars.length() &&
        [' ', '\t', '\r', '\n'].contains(self.chars[self.position]) {
    self.position += 1
  }
}

///|
fn RetainedJsonReader::string(self : RetainedJsonReader) -> String raise {
  let token = StringBuilder()
  token.write_char('"')
  self.position += 1
  while self.position < self.chars.length() {
    let ch = self.chars[self.position]
    token.write_char(ch)
    self.position += 1
    if ch == '\\' {
      token.write_char(self.chars[self.position])
      self.position += 1
    } else if ch == '"' {
      break
    }
  }
  guard @json.parse(token.to_string()) is String(value) else {
    fail("invalid JSON string")
  }
  value
}

///|
// Called only after standard syntax/Unicode/depth validation. Rebuild values
// from the validated tokens because the standard parser discards duplicates
// and normalizes many numeric spellings. No numeric arithmetic is performed.
fn RetainedJsonReader::value(self : RetainedJsonReader) -> Json raise {
  self.space()
  self.values += 1
  guard self.values <= 20_000 else { fail("JSON exceeds 20000 values") }
  match self.chars[self.position] {
    '{' => {
      self.position += 1
      self.space()
      let fields : Map[String, Json] = Map([])
      if self.chars[self.position] != '}' {
        while true {
          let key = self.string()
          guard !fields.contains(key) else {
            fail("JSON has duplicate object keys")
          }
          self.space()
          self.position += 1 // validated colon
          fields[key] = self.value()
          self.space()
          if self.chars[self.position] == '}' {
            break
          }
          self.position += 1 // validated comma
          self.space()
        }
      }
      self.position += 1
      Json::object(fields)
    }
    '[' => {
      self.position += 1
      self.space()
      let values : Array[Json] = []
      if self.chars[self.position] != ']' {
        while true {
          values.push(self.value())
          self.space()
          if self.chars[self.position] == ']' {
            break
          }
          self.position += 1
        }
      }
      self.position += 1
      Json::array(values)
    }
    '"' => Json::string(self.string())
    _ => {
      let token = StringBuilder()
      while self.position < self.chars.length() &&
            ![' ', '\t', '\r', '\n', ',', '}', ']'].contains(
              self.chars[self.position],
            ) {
        token.write_char(self.chars[self.position])
        self.position += 1
      }
      let spelling = token.to_string()
      match @json.parse(spelling) {
        Number(number, ..) => Json::number(number, repr=spelling)
        value => value
      }
    }
  }
}

///|
fn validate_retained_json_syntax(text : String) -> Unit raise {
  // Bound recursion before the standard parser; its depth parameter is being
  // retired. JSON string contents and escaped quotes do not increase depth.
  let mut depth = 0
  let mut in_string = false
  let mut escaped = false
  for char in text {
    if in_string {
      if escaped {
        escaped = false
      } else if char == '\\' {
        escaped = true
      } else if char == '"' {
        in_string = false
      }
    } else {
      match char {
        '"' => in_string = true
        '[' | '{' => {
          depth += 1
          guard depth <= 64 else { fail("JSON nesting exceeds 64") }
        }
        ']' | '}' => depth -= 1
        _ => ()
      }
    }
  }
  @json.parse(text) |> ignore
}

///|
fn parse_retained_json(text : String) -> Json raise {
  validate_retained_json_syntax(text)
  let reader : RetainedJsonReader = {
    chars: text.iter().collect(),
    position: 0,
    values: 0,
  }
  reader.value()
}

///|
fn retained_pointer_token(token : String) -> String raise {
  let chars = token.iter().collect()
  let decoded = StringBuilder()
  for index = 0; index < chars.length(); {
    if chars[index] == '~' {
      guard index + 1 < chars.length() else {
        fail("invalid JSON Pointer escape")
      }
      match chars[index + 1] {
        '0' => decoded.write_char('~')
        '1' => decoded.write_char('/')
        _ => fail("invalid JSON Pointer escape")
      }
      continue index + 2
    }
    decoded.write_char(chars[index])
    continue index + 1
  }
  decoded.to_string()
}

///|
fn retained_json_at(root : Json, pointer : String) -> Json raise {
  guard @utf8.encode(pointer).length() <= 4096 else {
    fail("JSON Pointer exceeds 4096 bytes")
  }
  if pointer.is_empty() {
    return root
  }
  guard pointer.has_prefix("/") else { fail("JSON Pointer must start with /") }
  let mut current = root
  for raw in pointer[1:].split("/") {
    let token = retained_pointer_token(raw.to_owned())
    current = match current {
      Object(fields) =>
        match fields.get(token) {
          Some(value) => value
          None => fail("JSON Pointer object key is missing")
        }
      Array(values) => {
        guard !token.is_empty() && (token == "0" || !token.has_prefix("0")) else {
          fail("JSON Pointer array index must be canonical decimal")
        }
        let mut index = 0
        for ch in token {
          guard ch >= '0' && ch <= '9' && index <= 1_048_576 else {
            fail("invalid JSON Pointer array index")
          }
          index = index * 10 + ch.to_int() - '0'.to_int()
        }
        guard values.get(index) is Some(value) else {
          fail("JSON Pointer array index is out of range")
        }
        value
      }
      _ => fail("JSON Pointer traverses a scalar")
    }
  }
  current
}

///|
fn retained_json_child_pointer(parent : String, key : String) -> String {
  parent +
  "/" +
  key.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
}

///|
fn retained_json_entry(value : Json, pointer : String) -> RetentionJsonEntry {
  let (kind, count) = match value {
    Object(fields) => ("object", fields.length())
    Array(values) => ("array", values.length())
    String(_) => ("string", 0)
    Number(_, ..) => ("number", 0)
    True | False => ("boolean", 0)
    Null => ("null", 0)
  }
  let preview = match value {
    Object(_) | Array(_) => "\{count} children"
    _ => value.stringify()
  }
  let short = StringBuilder()
  let mut length = 0
  for ch in preview {
    if length < 120 {
      short.write_char(ch)
    }
    length += 1
  }
  {
    pointer,
    kind,
    child_count: count,
    preview: short.to_string(),
    preview_truncated: length > 120,
  }
}

///|
async fn retained_json_source(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  pointer : String,
) -> (@sandbox.ScratchEntry, Json) {
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("JSON requires a retained file of at most 1 MiB")
  }
  let root = parse_retained_json(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let value = retained_json_at(root, pointer)
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during JSON inspection")
  }
  (file, value)
}

///|
/// List direct children of a verified retained JSON value. Object keys use
/// lexical order; array children use index order. after_child is a zero-based
/// count already consumed. Preserve pointer and binding when continuing.
pub async fn browse_retained_json(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  pointer? : String = "",
  after_child? : Int = 0,
  limit? : Int = 20,
) -> RetentionJsonPage {
  guard after_child >= 0 && limit >= 1 && limit <= 100 else {
    fail("invalid JSON child page")
  }
  let (file, value) = retained_json_source(binding, path, config, pointer)
  let selected = retained_json_entry(value, pointer)
  guard after_child <= selected.child_count else {
    fail("JSON cursor out of range")
  }
  let keys = match value {
    Object(fields) => {
      let keys = fields.keys().collect()
      keys.sort_by((a, b) => a[:].lexical_compare(b[:]))
      keys
    }
    _ => []
  }
  let children : Array[RetentionJsonEntry] = []
  let page = fn() -> RetentionJsonPage {
    {
      binding,
      file,
      selected,
      children: children.copy(),
      next_after_child: after_child + children.length(),
      has_more: after_child + children.length() < selected.child_count,
    }
  }
  guard @utf8.encode(page().to_json().stringify()).length() <=
    config.limits.max_protocol_bytes else {
    fail("JSON page metadata exceeds protocol budget")
  }
  for index = after_child
      index < selected.child_count && children.length() < limit
      index = index + 1 {
    let (key, child) = match value {
      Object(fields) => (keys[index], fields[keys[index]])
      Array(values) => (index.to_string(), values[index])
      _ => fail("scalar has no children")
    }
    children.push(
      retained_json_entry(child, retained_json_child_pointer(pointer, key)),
    )
    if @utf8.encode(page().to_json().stringify()).length() >
      config.limits.max_protocol_bytes {
      children.pop() |> ignore
      guard !children.is_empty() else {
        fail("JSON child exceeds protocol budget")
      }
      break
    }
  }
  page()
}

///|
/// Extract a typed subtree, retaining exact JSON number spellings. String
/// escape spelling and whitespace may change. The full contextual response
/// must fit the configured protocol budget; whole-file export remains available.
pub async fn extract_retained_json(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  pointer? : String = "",
) -> RetentionJsonSelection {
  let (file, value) = retained_json_source(binding, path, config, pointer)
  let selection : RetentionJsonSelection = { binding, file, pointer, value, }
  guard @utf8.encode(selection.to_json().stringify()).length() <=
    config.limits.max_protocol_bytes else {
    fail("JSON selection exceeds protocol budget; use whole-file export")
  }
  selection
}

///|
pub extend RetentionJsonEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionJsonEntry with Eq::{not_equal, equal}

///|
pub extend RetentionJsonEntry with ToJson::{to_json}

///|
pub extend RetentionJsonEntry with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend RetentionJsonPage with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionJsonPage with Eq::{not_equal, equal}

///|
pub extend RetentionJsonPage with ToJson::{to_json}

///|
pub extend RetentionJsonPage with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend RetentionJsonSelection with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionJsonSelection with ToJson::{to_json}

///|
pub extend RetentionJsonSelection with @moonbitlang/core/json.FromJson::{
  from_json,
}
