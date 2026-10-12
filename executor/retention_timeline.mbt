///|
/// Per-file provenance in a merged retained event timeline.
pub(all) struct RetentionTimelineSource {
  file : @sandbox.ScratchEntry
  total_lines : Int
  row_count : Int
  blank_lines_skipped : Int
} derive(Debug, ToJson, FromJson)

///|
/// Chronologically merged JSONL events. Every CSV row identifies its original
/// retained path and physical line. This is a derived candidate, not a receipt.
pub(all) struct RetentionTimeline {
  binding : RetentionArtifactBinding
  sources : Array[RetentionTimelineSource]
  mapping_fingerprint : String
  timestamp_pointer : String
  columns : Array[RetentionJsonColumn]
  skip_blank_lines : Bool
  total_lines : Int
  row_count : Int
  blank_lines_skipped : Int
  missing_cells : Int
  null_cells : Int
  first_timestamp : String
  last_timestamp : String
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
priv struct RetainedTimelineEvent {
  timestamp : String
  path : String
  line : Int
  value : Json
}

///|
fn retained_timeline_mapping(
  mapping : Bytes,
) -> (Array[String], String, Array[RetentionJsonColumn]) raise {
  guard mapping.length() <= 65_536 else {
    fail("timeline mapping exceeds 64 KiB")
  }
  let document = parse_retained_json(@utf8.decode(mapping))
  guard document is Object(fields) &&
    fields.length() == 4 &&
    fields.get("version") is Some(version) &&
    version.stringify() == "1" &&
    fields.get("files") is Some(Array(files)) &&
    fields.get("timestamp") is Some(String(timestamp)) &&
    fields.get("columns") is Some(Array(columns)) else {
    fail(
      "timeline mapping requires version 1, files, timestamp pointer and columns",
    )
  }
  guard files.length() >= 1 && files.length() <= 32 else {
    fail("timeline requires 1..32 exact retained file paths")
  }
  let seen : Map[String, Bool] = {}
  let paths = files.map(file => {
    guard file is String(path) &&
      !path.is_empty() &&
      path.length() <= 4096 &&
      !path.contains("\u{0}") &&
      !seen.contains(path) else {
      fail("timeline file paths must be nonempty, unique and bounded")
    }
    seen[path] = true
    path
  })
  paths.sort_by((a, b) => a[:].lexical_compare(b[:]))
  retained_edit_tokens(timestamp) |> ignore
  let (_, selected) = retained_json_columns(
    @utf8.encode(
      ({ "version": 1, "rows": "", "columns": columns.to_json() } : Json).stringify(),
    ),
  )
  guard selected.length() <= 61 &&
    !selected.any(column => {
      ["__source_path", "__source_line", "__timestamp"].contains(column.header)
    }) else {
    fail(
      "timeline requires 1..61 columns; generated source and timestamp headers are reserved",
    )
  }
  (paths, timestamp, selected)
}

///|
// Fixed UTC millisecond precision gives chronological lexical order without
// guessing locale, units, time zones, missing precision, or leap seconds.
fn retained_timeline_timestamp(text : String) -> Unit raise {
  guard text.length() == 24 &&
    text[4] == '-' &&
    text[7] == '-' &&
    text[10] == 'T' &&
    text[13] == ':' &&
    text[16] == ':' &&
    text[19] == '.' &&
    text[23] == 'Z' else {
    fail("timestamp requires YYYY-MM-DDTHH:mm:ss.SSSZ")
  }
  let number = fn(start : Int, length : Int) -> Int raise {
    let mut value = 0
    for i in start..<(start + length) {
      guard text[i] >= '0' && text[i] <= '9' else {
        fail("timestamp requires ASCII decimal digits")
      }
      value = value * 10 + text[i].to_int() - 48
    }
    value
  }
  let year = number(0, 4)
  let month = number(5, 2)
  let day = number(8, 2)
  let hour = number(11, 2)
  let minute = number(14, 2)
  let second = number(17, 2)
  number(20, 3) |> ignore
  guard year >= 1 &&
    month >= 1 &&
    month <= 12 &&
    hour <= 23 &&
    minute <= 59 &&
    second <= 59 else {
    fail("timestamp has an invalid calendar or clock component")
  }
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let days = if month == 2 {
    if leap {
      29
    } else {
      28
    }
  } else if [4, 6, 9, 11].contains(month) {
    30
  } else {
    31
  }
  guard day >= 1 && day <= days else {
    fail("timestamp has an invalid calendar day")
  }
}

///|
/// Merge explicitly selected retained JSONL files into a complete chronological
/// CSV. Timestamps are canonical UTC milliseconds; ties use lexical path then
/// physical line. Invalid/missing timestamps or records refuse the whole result.
pub async fn merge_retained_timeline(
  binding : RetentionArtifactBinding,
  config : ExecutorConfig,
  mapping : Bytes,
  skip_blank_lines? : Bool = false,
) -> RetentionTimeline {
  let (paths, timestamp_pointer, columns) = retained_timeline_mapping(mapping)
  let timestamp_tokens = retained_edit_tokens(timestamp_pointer)
  let record = bound_artifact_record(binding, config)
  let files = paths.map(path => {
    guard record.reviewable_files
      .filter(file => file.relative_path == path)
      .get(0)
      is Some(file) &&
      file.size_bytes <= 1_048_576L else {
      fail("timeline requires exact retained files of at most 1 MiB each")
    }
    file
  })
  guard files.fold(init=0L, (sum, file) => sum + file.size_bytes) <= 4_194_304L else {
    fail("timeline selected source files exceed 4 MiB")
  }
  let sources : Array[RetentionTimelineSource] = []
  let events : Array[RetainedTimelineEvent] = []
  let mut total_lines = 0
  let mut blank_lines_skipped = 0
  let mut total_values = 0
  for file in files {
    let path = file.relative_path
    let text = @utf8.decode(export_retained_artifact(binding, path, config))
    let (rows, lines, physical, blanks, values) = retained_jsonl_rows_counted(
      text, skip_blank_lines, total_values,
    ) catch {
      error => fail("timeline file \{path.to_json().stringify()}: \{error}")
    }
    total_lines += physical
    guard total_lines <= 20_000 else {
      fail("timeline exceeds 20000 physical lines across selected files")
    }
    total_values = values
    blank_lines_skipped += blanks
    sources.push({
      file,
      total_lines: physical,
      row_count: rows.length(),
      blank_lines_skipped: blanks,
    })
    for index, row in rows {
      let timestamp = try {
        guard retained_json_cell_at(row, timestamp_tokens)
          is Some(String(value)) else {
          fail("timeline timestamp must select a present string")
        }
        retained_timeline_timestamp(value)
        value
      } catch {
        error =>
          fail(
            "timeline file \{path.to_json().stringify()} source line \{lines[index]}: \{error}",
          )
      }
      events.push({ timestamp, path, line: lines[index], value: row, })
    }
  }
  events.sort_by((a, b) => {
    let time = a.timestamp[:].lexical_compare(b.timestamp[:])
    if time != 0 {
      time
    } else {
      let path = a.path[:].lexical_compare(b.path[:])
      if path != 0 {
        path
      } else {
        a.line - b.line
      }
    }
  })
  let (csv, row_count, missing_cells, null_cells) = retained_json_csv(
    Json::array(events.map(event => event.value)),
    [{ header: "__timestamp", pointer: timestamp_pointer, }] + columns,
    source_paths=events.map(event => event.path),
    source_lines=events.map(event => event.line),
  )
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during timeline merge")
  }
  let bytes = @utf8.encode(csv)
  let result : RetentionTimeline = {
    binding,
    sources,
    mapping_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(mapping)),
    timestamp_pointer,
    columns,
    skip_blank_lines,
    total_lines,
    row_count,
    blank_lines_skipped,
    missing_cells,
    null_cells,
    first_timestamp: events.get(0).map(event => event.timestamp).unwrap_or(""),
    last_timestamp: events
    .get(events.length() - 1)
    .map(event => event.timestamp)
    .unwrap_or(""),
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    csv,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("timeline context exceeds protocol budget")
  }
  result
}

///|
/// Read-only derivation metadata without payload or host-local paths.
pub fn RetentionTimeline::context(self : RetentionTimeline) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-retained-jsonl-timeline-v1",
    "binding": self.binding.to_json(),
    "sources": self.sources.to_json(),
    "mapping_fingerprint": self.mapping_fingerprint.to_json(),
    "timestamp_pointer": self.timestamp_pointer.to_json(),
    "timestamp_format": "YYYY-MM-DDTHH:mm:ss.SSSZ",
    "order": "timestamp-ascending-then-path-then-physical-line",
    "columns": self.columns.to_json(),
    "skip_blank_lines": self.skip_blank_lines.to_json(),
    "total_lines": self.total_lines.to_json(),
    "row_count": self.row_count.to_json(),
    "blank_lines_skipped": self.blank_lines_skipped.to_json(),
    "missing_cells": self.missing_cells.to_json(),
    "null_cells": self.null_cells.to_json(),
    "first_timestamp": self.first_timestamp.to_json(),
    "last_timestamp": self.last_timestamp.to_json(),
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}
