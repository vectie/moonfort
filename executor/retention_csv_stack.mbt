///|
/// An original shard's identity and row count in a consolidated CSV candidate.
pub(all) struct RetentionCsvStackSource {
  file : @sandbox.ScratchEntry
  row_count : Int
} derive(Debug, ToJson, FromJson)

///|
/// Selected retained CSV shards in manifest order, with original-row locators.
/// This is a local derived candidate, not a retained receipt or accepted data.
pub(all) struct RetentionCsvStack {
  binding : RetentionArtifactBinding
  sources : Array[RetentionCsvStackSource]
  manifest_fingerprint : String
  manifest_size_bytes : Int
  row_count : Int
  candidate_fingerprint : String
  candidate_size_bytes : Int
  csv : String
} derive(Debug, ToJson, FromJson)

///|
fn retained_csv_stack_manifest(
  manifest : Bytes,
) -> Array[(String, String)] raise {
  guard manifest.length() <= 65_536 else {
    fail("CSV stack manifest exceeds 64 KiB")
  }
  let document = parse_retained_json(@utf8.decode(manifest))
  guard document is Object(fields) &&
    fields.length() == 2 &&
    fields.get("version") is Some(version) &&
    version.stringify() == "1" &&
    fields.get("files") is Some(Array(files)) &&
    files.length() >= 2 &&
    files.length() <= 32 else {
    fail("CSV stack manifest requires version 1 and 2..32 files")
  }
  let seen : Map[String, Bool] = {}
  files.map(file => {
    guard file is Object(fields) &&
      fields.length() == 2 &&
      fields.get("path") is Some(String(path)) &&
      fields.get("fingerprint") is Some(String(fingerprint)) &&
      !path.is_empty() &&
      path.length() <= 4096 &&
      !path.contains("\u{0}") &&
      !path.contains("\\") &&
      path.split("/").all(part => part != "" && part != "." && part != "..") &&
      !seen.contains(path) else {
      fail("CSV stack files require unique relative paths and fingerprints")
    }
    guard fingerprint.length() == 64 &&
      fingerprint
      .iter()
      .all(character => {
        (character >= '0' && character <= '9') ||
        (character >= 'a' && character <= 'f')
      }) else {
      fail("CSV stack fingerprint requires lowercase SHA-256")
    }
    seen[path] = true
    (path, fingerprint)
  })
}

///|
fn stack_retained_csv_records(
  tables : Array[(String, Array[Array[String]])],
) -> (String, Int) raise {
  guard tables.length() >= 2 && tables.length() <= 32 else {
    fail("CSV stack requires 2..32 tables")
  }
  guard tables[0].1.get(0) is Some(headers) &&
    headers.length() >= 1 &&
    headers.length() <= 62 &&
    !headers.contains("__source_path") &&
    !headers.contains("__source_row") else {
    fail(
      "CSV stack requires 1..62 source columns without reserved locator headers",
    )
  }
  let output = StringBuilder()
  let header = enriched_csv_record(["__source_path", "__source_row"] + headers)
  output.write_string(header)
  let mut size = @utf8.encode(header).length()
  guard size <= 1_048_576 else { fail("CSV stack candidate exceeds 1 MiB") }
  let mut rows = 0
  for (path, records) in tables {
    guard records.get(0) is Some(actual) && actual == headers else {
      fail("CSV stack ordered headers differ at " + path.to_json().stringify())
    }
    guard rows + records.length() - 1 <= 20_000 else {
      fail("CSV stack candidate exceeds 20000 data rows")
    }
    for row in 1..<records.length() {
      let text = enriched_csv_record([path, row.to_string()] + records[row])
      size += @utf8.encode(text).length()
      guard size <= 1_048_576 else { fail("CSV stack candidate exceeds 1 MiB") }
      output.write_string(text)
      rows += 1
    }
  }
  (output.to_string(), rows)
}

///|
/// Consolidate 2..32 explicitly selected retained CSV shards from one receipt.
/// Ordered headers must match exactly. Manifest order and logical row order
/// are preserved; each output row includes its original path and data-row number.
/// No deduplication, type conversion, execution, retention write or promotion occurs.
///
/// ```mbt nocheck
/// let candidate = @executor.stack_retained_csv(binding, config, manifest_bytes)
///
/// let csv_bytes = @utf8.encode(candidate.csv)
///
/// let context_json = candidate.context().stringify() + "\n"
/// ```
pub async fn stack_retained_csv(
  binding : RetentionArtifactBinding,
  config : ExecutorConfig,
  manifest : Bytes,
) -> RetentionCsvStack {
  let selected = retained_csv_stack_manifest(manifest)
  let record = bound_artifact_record(binding, config)
  let files = selected.map(selection => {
    let (path, fingerprint) = selection
    guard record.reviewable_files
      .filter(file => file.relative_path == path)
      .get(0)
      is Some(file) &&
      file.size_bytes <= 1_048_576L else {
      fail(
        "CSV stack requires retained files of at most 1 MiB: " +
        path.to_json().stringify(),
      )
    }
    guard file.fingerprint == fingerprint else {
      fail(
        "CSV stack manifest fingerprint is stale at " +
        path.to_json().stringify(),
      )
    }
    file
  })
  guard files.fold(init=0L, (sum, file) => sum + file.size_bytes) <= 4_194_304L else {
    fail("CSV stack selected source files exceed 4 MiB")
  }
  let tables : Array[(String, Array[Array[String]])] = []
  let sources : Array[RetentionCsvStackSource] = []
  let mut rows = 0
  for file in files {
    let records = parse_retained_csv(
      @utf8.decode(
        export_retained_artifact(binding, file.relative_path, config),
      ),
    ) catch {
      error =>
        fail(
          "CSV stack source " +
          file.relative_path.to_json().stringify() +
          ": \{error}",
        )
    }
    rows += records.length() - 1
    guard rows <= 20_000 else {
      fail("CSV stack candidate exceeds 20000 data rows")
    }
    sources.push({ file, row_count: records.length() - 1, })
    tables.push((file.relative_path, records))
  }
  let (csv, row_count) = stack_retained_csv_records(tables)
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during CSV consolidation")
  }
  let bytes = @utf8.encode(csv)
  let result : RetentionCsvStack = {
    binding,
    sources,
    manifest_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(manifest)),
    manifest_size_bytes: manifest.length(),
    row_count,
    candidate_fingerprint: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    candidate_size_bytes: bytes.length(),
    csv,
  }
  guard @utf8.encode(result.context().stringify()).length() + 1 <=
    config.limits.max_protocol_bytes else {
    fail("CSV stack context exceeds protocol budget")
  }
  result
}

///|
/// Exact derivation metadata without CSV cell contents or host-local paths.
pub fn RetentionCsvStack::context(self : RetentionCsvStack) -> Json {
  {
    "derived_candidate": true,
    "derivation": "moonfort-csv-stack-v1",
    "binding": self.binding.to_json(),
    "sources": self.sources.to_json(),
    "manifest_fingerprint": self.manifest_fingerprint.to_json(),
    "manifest_size_bytes": self.manifest_size_bytes.to_json(),
    "row_count": self.row_count.to_json(),
    "candidate_fingerprint": self.candidate_fingerprint.to_json(),
    "candidate_size_bytes": self.candidate_size_bytes.to_json(),
    "ordering": "manifest-file-order-then-original-logical-data-row",
    "locators": ["__source_path", "__source_row"],
    "duplicates": "preserved",
  }
}
