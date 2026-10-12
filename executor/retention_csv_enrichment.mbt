///|
/// A left-joined CSV candidate. The local lookup is reference data, not retained
/// execution evidence. Keep its exact bytes, candidate and context together.
pub(all) struct RetentionCsvEnrichment {
  binding : RetentionArtifactBinding
  file : @sandbox.ScratchEntry
  lookup_fingerprint : String
  lookup_size_bytes : Int
  source_key : Int
  lookup_key : Int
  lookup_columns : Array[Int]
  prefix : String
  source_rows : Int
  lookup_rows : Int
  matched_rows : Int
  unused_lookup_rows : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
fn enriched_csv_record(cells : Array[String]) -> String {
  cells
  .map(cell => "\"" + cell.replace_all(old="\"", new="\"\"") + "\"")
  .join(",") +
  "\r\n"
}

///|
fn enrich_csv_records(
  source : Array[Array[String]],
  lookup : Array[Array[String]],
  source_key : Int,
  lookup_key : Int,
  lookup_columns : Array[Int],
  prefix : String,
) -> (String, Array[Int], Int, Int) raise {
  guard source_key >= 1 &&
    source_key <= source[0].length() &&
    lookup_key >= 1 &&
    lookup_key <= lookup[0].length() else {
    fail("CSV enrichment keys must name existing one-based columns")
  }
  guard prefix.length() <= 128 && !prefix.contains("\u{0}") else {
    fail("CSV enrichment prefix exceeds 128 UTF-16 units or contains NUL")
  }
  let selected = if lookup_columns.is_empty() {
    [
      for column in 1..<=lookup[0].length() => column
    ].filter(column => column != lookup_key)
  } else {
    lookup_columns.copy()
  }
  guard !selected.is_empty() && source[0].length() + selected.length() <= 64 else {
    fail("CSV enrichment requires lookup columns and at most 64 result columns")
  }
  let headers = source[0].copy()
  for index, column in selected {
    guard column >= 1 &&
      column <= lookup[0].length() &&
      !selected[:index].contains(column) else {
      fail("CSV enrichment contains an invalid or repeated lookup column")
    }
    let header = prefix + lookup[0][column - 1]
    guard header.length() <= 16_384 else {
      fail("CSV enrichment header exceeds 16384 UTF-16 units")
    }
    headers.push(header)
  }
  let index : Map[String, Array[String]] = {}
  for row in lookup[1:] {
    let key = row[lookup_key - 1]
    guard !key.is_empty() && !index.contains(key) else {
      fail("CSV lookup keys must be nonempty and unique")
    }
    index[key] = row
  }
  let used : Map[String, Bool] = {}
  let output = StringBuilder()
  let mut size = 0
  let write = fn(cells : Array[String]) -> Unit raise {
    let record = enriched_csv_record(cells)
    size += @utf8.encode(record).length()
    guard size <= 1_048_576 else {
      fail("CSV enrichment candidate exceeds 1 MiB")
    }
    output.write_string(record)
  }
  write(headers)
  let mut matched = 0
  for row in source[1:] {
    let cells = row.copy()
    let key = row[source_key - 1]
    match index.get(key) {
      Some(reference) => {
        matched += 1
        used[key] = true
        for column in selected {
          cells.push(reference[column - 1])
        }
      }
      None =>
        for _ in selected {
          cells.push("")
        }
    }
    write(cells)
  }
  (output.to_string(), selected, matched, index.length() - used.length())
}

///|
/// Append selected local lookup columns to every retained CSV row by exact,
/// case-sensitive string key. No trimming or numeric conversion is performed.
/// Source order and repeated source keys remain intact. Missing/empty source
/// keys append empty cells; lookup keys must be unique and nonempty.
/// Empty lookup_columns selects every lookup column except lookup_key.
/// Both inputs and output are bounded to 1 MiB, 20000 data rows and 64 columns.
/// No original, receipt, grant or durable destination is changed.
pub async fn enrich_retained_csv(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  lookup : Bytes,
  source_key~ : Int,
  lookup_key~ : Int,
  lookup_columns? : Array[Int] = [],
  prefix? : String = "lookup_",
) -> RetentionCsvEnrichment {
  guard lookup.length() <= 1_048_576 else { fail("CSV lookup exceeds 1 MiB") }
  let reference = parse_retained_csv(@utf8.decode(lookup))
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(file => file.relative_path == path)
    .get(0)
    is Some(file) &&
    file.size_bytes <= 1_048_576L else {
    fail("CSV enrichment requires a retained file of at most 1 MiB")
  }
  let source = parse_retained_csv(
    @utf8.decode(export_retained_artifact(binding, path, config)),
  )
  let (csv, selected, matched_rows, unused_lookup_rows) = enrich_csv_records(
    source, reference, source_key, lookup_key, lookup_columns, prefix,
  )
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during CSV enrichment")
  }
  let bytes = @utf8.encode(csv)
  let result : RetentionCsvEnrichment = {
    binding,
    file,
    lookup_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(lookup)),
    lookup_size_bytes: lookup.length(),
    source_key,
    lookup_key,
    lookup_columns: selected,
    prefix,
    source_rows: source.length() - 1,
    lookup_rows: reference.length() - 1,
    matched_rows,
    unused_lookup_rows,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    csv,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("CSV enrichment context exceeds protocol budget")
  }
  result
}

///|
/// Provenance and join settings, excluding candidate content and local paths.
/// This records a local derivation, not an execution receipt or acceptance.
pub fn RetentionCsvEnrichment::context(self : RetentionCsvEnrichment) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-csv-left-join-v1",
    "binding": self.binding.to_json(),
    "source_file": self.file.to_json(),
    "lookup_fingerprint": self.lookup_fingerprint.to_json(),
    "lookup_size_bytes": self.lookup_size_bytes.to_json(),
    "source_key": self.source_key.to_json(),
    "lookup_key": self.lookup_key.to_json(),
    "lookup_columns": self.lookup_columns.to_json(),
    "prefix": self.prefix.to_json(),
    "source_rows": self.source_rows.to_json(),
    "lookup_rows": self.lookup_rows.to_json(),
    "matched_rows": self.matched_rows.to_json(),
    "unmatched_rows": (self.source_rows - self.matched_rows).to_json(),
    "unused_lookup_rows": self.unused_lookup_rows.to_json(),
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
  }
}
