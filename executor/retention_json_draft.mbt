///|
/// A derived JSON candidate, never a retained execution result or promotion.
/// Candidate digest and size cover value.stringify() plus one LF, exactly as
/// emitted by browse-retention edit-json. Recipe digest covers supplied bytes.
pub(all) struct RetentionJsonDraft {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  recipe_fingerprint : String
  candidate_fingerprint : String
  candidate_size_bytes : Int
  operation_count : Int
  value : Json
} derive(Debug, ToJson, FromJson)

///|
priv struct RetainedJsonEdit {
  operation : String
  tokens : Array[String]
  value : Json
}

///|
fn retained_edit_tokens(pointer : String) -> Array[String] raise {
  guard @utf8.encode(pointer).length() <= 4096 else {
    fail("JSON Pointer exceeds 4096 bytes")
  }
  if pointer.is_empty() {
    return []
  }
  guard pointer.has_prefix("/") else { fail("JSON Pointer must start with /") }
  let tokens : Array[String] = []
  for raw in pointer[1:].split("/") {
    tokens.push(retained_pointer_token(raw.to_owned()))
  }
  tokens
}

///|
fn retained_json_edits(recipe : Bytes) -> Array[RetainedJsonEdit] raise {
  guard recipe.length() <= 65_536 else {
    fail("JSON edit recipe exceeds 64 KiB")
  }
  let document = parse_retained_json(@utf8.decode(recipe))
  guard document is Object(fields) &&
    fields.length() == 2 &&
    fields.get("version") is Some(version) &&
    version.stringify() == "1" &&
    fields.get("operations") is Some(Array(operations)) else {
    fail("JSON edit recipe requires version 1 and operations")
  }
  guard operations.length() >= 1 && operations.length() <= 100 else {
    fail("JSON edit recipe requires 1..100 operations")
  }
  operations.map(operation => {
    guard operation is Object(fields) &&
      fields.get("op") is Some(String(op)) &&
      fields.get("pointer") is Some(String(pointer)) else {
      fail("JSON edit operation requires op and pointer")
    }
    guard (op == "set" && fields.length() == 3 && fields.contains("value")) ||
      (op == "remove" && fields.length() == 2) else {
      fail("JSON edit operation must be set with value or remove without value")
    }
    let tokens = retained_edit_tokens(pointer)
    guard op != "remove" || !tokens.is_empty() else {
      fail("cannot remove the JSON document root")
    }
    {
      operation: op,
      tokens,
      value: fields.get("value").unwrap_or(Json::null()),
    }
  })
}

///|
fn retained_edit_index(token : String, length : Int) -> Int raise {
  guard !token.is_empty() && (token == "0" || !token.has_prefix("0")) else {
    fail("JSON edit array index must be canonical decimal")
  }
  let mut index = 0
  for ch in token {
    guard ch >= '0' && ch <= '9' && index <= 1_048_576 else {
      fail("invalid JSON edit array index")
    }
    index = index * 10 + ch.to_int() - '0'.to_int()
  }
  guard index < length else { fail("JSON edit array index is out of range") }
  index
}

///|
// Copy containers along the selected path. No value from the original parsed
// document or an edit recipe is mutated, including on a later failed operation.
fn retained_apply_edit(
  current : Json,
  edit : RetainedJsonEdit,
  depth : Int,
) -> Json raise {
  if depth == edit.tokens.length() {
    return edit.value
  }
  let token = edit.tokens[depth]
  let last = depth + 1 == edit.tokens.length()
  match current {
    Object(fields) => {
      let copy = fields.copy()
      if last && edit.operation == "set" {
        copy[token] = edit.value
      } else {
        guard fields.get(token) is Some(value) else {
          fail("JSON edit object key is missing")
        }
        if last {
          copy.remove(token)
        } else {
          copy[token] = retained_apply_edit(value, edit, depth + 1)
        }
      }
      Json::object(copy)
    }
    Array(values) => {
      if token == "-" && last && edit.operation == "set" {
        let copy = values.copy()
        copy.push(edit.value)
        return Json::array(copy)
      }
      let index = retained_edit_index(token, values.length())
      let copy : Array[Json] = []
      for i, value in values {
        if i != index {
          copy.push(value)
        } else if !last {
          copy.push(retained_apply_edit(value, edit, depth + 1))
        } else if edit.operation == "set" {
          copy.push(edit.value)
        }
      }
      Json::array(copy)
    }
    _ => fail("JSON edit traverses a scalar")
  }
}

///|
fn retained_apply_edits(
  root : Json,
  edits : Array[RetainedJsonEdit],
) -> Json raise {
  let mut candidate = root
  for index, edit in edits {
    candidate = try {
      let next = retained_apply_edit(candidate, edit, 0)
      let text = next.stringify()
      guard @utf8.encode(text).length() + 1 <= 1_048_576 else {
        fail("JSON candidate exceeds 1 MiB including final LF")
      }
      // Revalidate aggregate depth/value count after each edit, including
      // repeated appends and nested values that were small in the recipe.
      parse_retained_json(text)
    } catch {
      error => fail("JSON edit operation \{index + 1} failed: \{error}")
    }
  }
  candidate
}

///|
/// Apply a bounded local version-1 set/remove recipe to a verified retained
/// JSON artifact. Operations are sequential. Missing parents refuse; set adds
/// object fields, replaces array elements, or appends at an array's /- pointer.
/// No file, grant, receipt or destination is written. Keep recipe bytes with the
/// candidate and its context; this does not accept or promote the result.
pub async fn draft_retained_json(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  recipe : Bytes,
) -> RetentionJsonDraft {
  let edits = retained_json_edits(recipe)
  let (file, source) = retained_json_source(binding, path, config, "")
  let value = retained_apply_edits(source, edits)
  let bytes = @utf8.encode(value.stringify() + "\n")
  let result : RetentionJsonDraft = {
    binding,
    file,
    recipe_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(recipe)),
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    operation_count: edits.length(),
    value,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("JSON candidate context exceeds protocol budget")
  }
  result
}

///|
/// Exportable provenance without candidate content. These hashes describe a
/// local derivation; they are not a new execution receipt or an approval.
pub fn RetentionJsonDraft::context(self : RetentionJsonDraft) -> Json {
  {
    "derived_candidate": true,
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "recipe_format": "moonfort-json-edits-v1",
    "recipe_fingerprint": self.recipe_fingerprint.to_json(),
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
    "operation_count": self.operation_count.to_json(),
  }
}
