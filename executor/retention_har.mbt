///|
/// A request-level timing candidate derived from one verified retained HAR.
pub(all) struct RetentionHarTable {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  entry_count : Int
  row_count : Int
  http_method : String
  status : Int?
  minimum_ms : Double
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive (
  Debug,
  ToJson(fields(http_method(rename="method"))),
  FromJson(fields(http_method(rename="method"))),
)

///|
fn har_object(value : Json) -> Map[String, Json] raise {
  guard value is Object(fields) else { fail("HAR expected an object") }
  fields
}

///|
fn har_child(
  fields : Map[String, Json],
  key : String,
) -> Map[String, Json] raise {
  guard fields.get(key) is Some(value) else { fail("HAR missing \{key}") }
  har_object(value)
}

///|
fn har_text(
  fields : Map[String, Json],
  key : String,
  optional? : Bool = false,
) -> String raise {
  match fields.get(key) {
    None if optional => ""
    Some(String(value)) => {
      guard value.length() <= 16_384 && !value.contains("\u{0}") else {
        fail("HAR text exceeds cell limit or contains NUL")
      }
      value
    }
    _ => fail("HAR \{key} requires a string")
  }
}

///|
// Interpret an already syntax-validated JSON numeral exactly, before binary64
// rounding. Strip only mathematically insignificant coefficient zeros; decimal
// points and exponents can represent integers (1.00e2), or hide a tiny fraction.
fn har_exact_integer(spelling : String) -> Int64? {
  let chars = spelling.iter().collect()
  let negative = chars[0] == '-'
  let digits : Array[Int] = []
  let mut fraction_digits = 0
  let mut after_point = false
  let mut cursor = if negative { 1 } else { 0 }
  while cursor < chars.length() && chars[cursor] != 'e' && chars[cursor] != 'E' {
    if chars[cursor] == '.' {
      after_point = true
    } else {
      digits.push(chars[cursor].to_int() - 48)
      if after_point {
        fraction_digits += 1
      }
    }
    cursor += 1
  }
  let mut exponent = 0
  let mut exponent_negative = false
  if cursor < chars.length() {
    cursor += 1
    if chars[cursor] == '-' || chars[cursor] == '+' {
      exponent_negative = chars[cursor] == '-'
      cursor += 1
    }
    // Beyond this bound no nonzero coefficient in this very spelling could
    // cancel the exponent into a safe integer. Saturate without Int overflow.
    let cap = chars.length() + 32
    while cursor < chars.length() {
      exponent = (exponent * 10 + chars[cursor].to_int() - 48).min(cap)
      cursor += 1
    }
  }
  if exponent_negative {
    exponent = -exponent
  }
  let mut first = 0
  while first < digits.length() && digits[first] == 0 {
    first += 1
  }
  if first == digits.length() {
    return Some(0L)
  }
  let mut end = digits.length()
  while digits[end - 1] == 0 {
    end -= 1
  }
  let power = exponent - fraction_digits + digits.length() - end
  if power < 0 || end - first + power > 16 {
    return None
  }
  let mut result = 0L
  for i in first..<end {
    result = result * 10L + digits[i].to_int64()
  }
  for _ in 0..<power {
    result *= 10L
  }
  if result > 9007199254740991L {
    return None
  }
  Some(if negative { -result } else { result })
}

///|
// Keep source spelling while computing timing arithmetic with finite binary64.
// -1 means unavailable for the explicitly permitted HAR fields, never zero.
fn har_number(
  fields : Map[String, Json],
  key : String,
  unavailable? : Bool = false,
  optional? : Bool = false,
  integer? : Bool = false,
) -> (String, Double?) raise {
  match fields.get(key) {
    None if optional => ("", None)
    Some(Number(number, ..) as value) => {
      let spelling = value.stringify()
      if unavailable &&
        number == -1.0 &&
        har_exact_integer(spelling) == Some(-1L) {
        return ("", None)
      }
      guard number >= 0.0 &&
        !number.is_inf() &&
        !number.is_nan() &&
        (!spelling.has_prefix("-") || har_exact_integer(spelling) == Some(0L)) else {
        fail("HAR \{key} requires a nonnegative finite number")
      }
      if integer {
        guard har_exact_integer(spelling) is Some(exact) && exact >= 0L else {
          fail("HAR \{key} requires a safe nonnegative integer")
        }
      }
      (spelling, Some(number))
    }
    _ => fail("HAR \{key} requires a number")
  }
}

///|
fn retained_har_csv(
  document : Json,
  http_method? : String = "",
  status? : Int,
  minimum_ms? : Double = 0.0,
) -> (String, Int, Int) raise {
  guard http_method.length() <= 16_384 &&
    !http_method.contains("\u{0}") &&
    !minimum_ms.is_nan() &&
    !minimum_ms.is_inf() &&
    minimum_ms >= 0.0 &&
    (status is None || (status.unwrap() >= 0 && status.unwrap() <= 999)) else {
    fail("invalid HAR selection")
  }
  let log = har_child(har_object(document), "log")
  guard har_text(log, "version") == "1.2" &&
    log.get("entries") is Some(Array(entries)) else {
    fail("HAR requires version 1.2 and inline entries")
  }
  guard entries.length() <= 5000 else { fail("HAR exceeds 5000 entries") }
  let output = StringBuilder()
  let mut size = 0
  let mut row_count = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    let row = enriched_csv_record(cells)
    size += @utf8.encode(row).length()
    guard size <= 1_048_576 else { fail("HAR CSV candidate exceeds 1 MiB") }
    output.write_string(row)
  }
  write([
    "__entry_pointer", "pageref", "started_datetime", "method", "url", "status",
    "mime_type", "time_ms", "blocked_ms", "dns_ms", "connect_ms", "send_ms", "wait_ms",
    "receive_ms", "ssl_ms", "known_phase_sum_ms", "total_minus_known_phases_ms",
    "unavailable_phase_count", "request_body_bytes", "response_body_bytes", "content_bytes",
  ])
  for index, entry in entries {
    let fields = har_object(entry)
    let request = har_child(fields, "request")
    let response = har_child(fields, "response")
    let content = har_child(response, "content")
    let timings = har_child(fields, "timings")
    let started = har_text(fields, "startedDateTime")
    let request_method = har_text(request, "method")
    let url = har_text(request, "url")
    guard !started.is_empty() && !request_method.is_empty() && !url.is_empty() else {
      fail("HAR requires nonempty start, method and URL labels")
    }
    let (status_cell, response_status) = har_number(
      response,
      "status",
      integer=true,
    )
    guard response_status.unwrap() <= 999.0 else {
      fail("HAR status exceeds 999")
    }
    let (time_cell, time) = har_number(fields, "time")
    let cells = [
      "/log/entries/\{index}",
      har_text(fields, "pageref", optional=true),
      started,
      request_method,
      url,
      status_cell,
      har_text(content, "mimeType"),
      time_cell,
    ]
    let mut known = 0.0
    let mut missing = 0
    for phase in ["blocked", "dns", "connect", "send", "wait", "receive", "ssl"] {
      let optional = ["blocked", "dns", "connect", "ssl"].contains(phase)
      let (cell, value) = har_number(
        timings,
        phase,
        optional~,
        unavailable=optional,
      )
      cells.push(cell)
      // SSL is a subset of connect, so adding it again would double count.
      if phase != "ssl" {
        match value {
          Some(value) => known += value
          None => missing += 1
        }
      }
    }
    guard !known.is_inf() else { fail("HAR phase sum overflow") }
    cells.push(known.to_string())
    cells.push((time.unwrap() - known).to_string())
    cells.push(missing.to_string())
    cells.push(
      har_number(request, "bodySize", unavailable=true, integer=true).0,
    )
    cells.push(
      har_number(response, "bodySize", unavailable=true, integer=true).0,
    )
    cells.push(har_number(content, "size", integer=true).0)
    // Validate every entry, including excluded entries, before emitting output.
    if (http_method.is_empty() || request_method == http_method) &&
      (
        status is None ||
        response_status.unwrap() == status.unwrap().to_double()
      ) &&
      time.unwrap() >= minimum_ms {
      write(cells)
      row_count += 1
    }
  }
  (output.to_string(), entries.length(), row_count)
}

///|
/// Inspect HAR 1.2 request timings without running requests or decoding bodies.
/// Filters combine with AND; an empty method selects all methods. Status zero
/// is retained as recorded, not interpreted as HTTP success or failure.
#label_migration(http_method, alias=method)
pub async fn tabulate_retained_har(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  http_method? : String = "",
  status? : Int,
  minimum_ms? : Double = 0.0,
) -> RetentionHarTable {
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("HAR requires a retained file of at most 1 MiB")
  }
  let text = @utf8.decode(export_retained_artifact(binding, path, config))
  let document = parse_retained_json(
    text.strip_prefix("\u{feff}").unwrap_or(text[:]).to_owned(),
  )
  let (csv, entry_count, row_count) = retained_har_csv(
    document,
    http_method~,
    status?,
    minimum_ms~,
  )
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during HAR projection")
  }
  let bytes = @utf8.encode(csv)
  let result : RetentionHarTable = {
    binding,
    file,
    entry_count,
    row_count,
    http_method,
    status,
    minimum_ms,
    csv,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("HAR context exceeds protocol budget")
  }
  result
}

///|
/// Identity and interpretation context without request URLs or CSV contents.
pub fn RetentionHarTable::context(self : RetentionHarTable) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-har-requests-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "entry_count": self.entry_count.to_json(),
    "row_count": self.row_count.to_json(),
    "selection": {
      "method": self.http_method.to_json(),
      "status": match self.status {
        Some(value) => value.to_json()
        None => Json::null()
      },
      "minimum_ms": self.minimum_ms.to_json(),
    },
    "entry_pointer_column": "__entry_pointer",
    "order": "original log.entries order; timestamps are verbatim labels, not parsed or sorted",
    "timing_semantics": "milliseconds; known_phase_sum excludes unavailable phases and SSL (already part of connect); difference is descriptive binary64 arithmetic, not an acceptance test",
    "unavailable_semantics": "blank means absent optional timing or -1; unavailable_phase_count excludes SSL; zero remains explicit",
    "status_semantics": "recorded status 0..999; zero has no inferred HTTP outcome",
    "omitted_metadata": [
      "headers", "cookies", "queryString array", "postData", "response.content.text",
      "pages", "cache", "serverIPAddress", "connection", "custom fields",
    ],
    "privacy": "URLs remain verbatim and may contain private query strings or credentials; this candidate and the unchanged original are not sanitized for sharing",
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}

///|
pub extend RetentionHarTable with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionHarTable with ToJson::{to_json}

///|
pub extend RetentionHarTable with @moonbitlang/core/json.FromJson::{from_json}
