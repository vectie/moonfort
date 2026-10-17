///|
/// Portable review package metadata. Artifact paths are relative to artifacts/.
pub(all) struct RetentionBundleManifest {
  format_version : Int
  purpose : String
  binding : RetentionArtifactBinding
  expires_at_ms : Int64
  files : Array[@sandbox.ScratchEntry]
  total_bytes : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
fn bundle_crc32(bytes : Bytes) -> UInt {
  let mut crc = 0xffffffffU
  for byte in bytes {
    crc = crc ^ byte.to_uint()
    for bit = 0; bit < 8; bit = bit + 1 {
      crc = if (crc & 1U) == 1U { (crc >> 1) ^ 0xedb88320U } else { crc >> 1 }
    }
  }
  crc ^ 0xffffffffU
}

///|
// ZIP store method, UTF-8 flag, fixed 1980-01-01 timestamp. No compression,
// extraction, permissions, executable attributes, or host filesystem paths.
fn bundle_zip(entries : Array[(String, Bytes)]) -> Bytes {
  let output = @buffer.Buffer()
  let central = @buffer.Buffer()
  for (path, bytes) in entries {
    let name = @utf8.encode(path)
    let crc = bundle_crc32(bytes)
    let offset = output.length()
    output.write_uint_le(0x04034b50U)
    for word in [20, 0x0800, 0, 0, 33] {
      output.write_uint16_le(word.to_uint16())
    }
    output.write_uint_le(crc)
    output.write_int_le(bytes.length())
    output.write_int_le(bytes.length())
    output.write_uint16_le(name.length().to_uint16())
    output.write_uint16_le(0)
    output.write_bytes(name)
    output.write_bytes(bytes)
    central.write_uint_le(0x02014b50U)
    for word in [0x0314, 20, 0x0800, 0, 0, 33] {
      central.write_uint16_le(word.to_uint16())
    }
    central.write_uint_le(crc)
    central.write_int_le(bytes.length())
    central.write_int_le(bytes.length())
    central.write_uint16_le(name.length().to_uint16())
    for field = 0; field < 4; field = field + 1 {
      central.write_uint16_le(0)
    }
    central.write_int_le(0)
    central.write_int_le(offset)
    central.write_bytes(name)
  }
  let central_offset = output.length()
  output.write_bytes(central.to_bytes())
  output.write_uint_le(0x06054b50U)
  output.write_uint16_le(0)
  output.write_uint16_le(0)
  output.write_uint16_le(entries.length().to_uint16())
  output.write_uint16_le(entries.length().to_uint16())
  output.write_int_le(central.length())
  output.write_int_le(central_offset)
  output.write_uint16_le(0)
  output.to_bytes()
}

///|
/// Export 1..200 selected manifest files as a stored UTF-8 ZIP with manifest.json
/// and artifacts/<relative path>. All bytes are verified before returning any
/// output. Combined artifact bytes are bounded by 16 MiB and the disk limit.
/// This creates a review copy, never an approval, promotion, or execution.
pub async fn export_retained_bundle(
  binding : RetentionArtifactBinding,
  paths : Array[String],
  config : ExecutorConfig,
) -> Bytes {
  guard paths.length() > 0 && paths.length() <= 200 else {
    fail("bundle requires 1..200 files")
  }
  let record = bound_artifact_record(binding, config)
  let selected = paths.copy()
  selected.sort_by((left, right) => left[:].lexical_compare(right[:]))
  let files : Array[@sandbox.ScratchEntry] = []
  let mut total = 0L
  for index, path in selected {
    guard @sandbox.scratch_relative_path_is_safe(path) &&
      @utf8.encode(path).length() <= 4096 &&
      (index == 0 || selected[index - 1] != path) else {
      fail("invalid or duplicate bundle path")
    }
    guard record.reviewable_files
      .filter(entry => entry.relative_path == path)
      .get(0)
      is Some(entry) else {
      fail("bundle file is not retained")
    }
    total += entry.size_bytes
    guard total <= retained_artifact_byte_limit(config).to_int64() else {
      fail("bundle exceeds combined artifact byte limit")
    }
    files.push(entry)
  }
  let manifest : RetentionBundleManifest = {
    format_version: 1,
    purpose: "Review copy only; not approval or promotion",
    binding,
    expires_at_ms: record.expires_at_ms,
    files,
    total_bytes: total,
  }
  let entries = [
    ("manifest.json", @utf8.encode(manifest.to_json().stringify() + "\n")),
  ]
  for file in files {
    let (observed, _, bytes) = verified_retained_artifact(
      binding,
      file.relative_path,
      config,
    )
    guard observed == record else { fail("retention changed during bundle") }
    entries.push(("artifacts/" + file.relative_path, bytes))
  }
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during bundle")
  }
  bundle_zip(entries)
}

///|
pub extend RetentionBundleManifest with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionBundleManifest with Eq::{not_equal, equal}

///|
pub extend RetentionBundleManifest with ToJson::{to_json}

///|
pub extend RetentionBundleManifest with @moonbitlang/core/json.FromJson::{
  from_json,
}
