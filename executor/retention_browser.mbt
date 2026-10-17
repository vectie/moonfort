///|
/// Copy the retention/digest identities from one receipt and its workspace ID
/// from the originating approved task's grant. This is a read-only
/// artifact selection, not a new execution grant or a promotion request.
pub(all) struct RetentionArtifactBinding {
  protocol_version : Int
  retention_id : String
  workspace_id : String
  approval_digest : String
  command_digest : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionArtifactList {
  binding : RetentionArtifactBinding
  expires_at_ms : Int64
  total_files : Int
  total_bytes : Int64
  matched_files : Int
  matched_bytes : Int64
  files : Array[@sandbox.ScratchEntry]
  next_after : String
  has_more : Bool
  max_export_bytes : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionArtifactPage {
  binding : RetentionArtifactBinding
  expires_at_ms : Int64
  file : @sandbox.ScratchEntry
  offset : Int64
  next_offset : Int64
  content_base64 : String
  eof : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn decode_retention_artifact_binding(
  value : Json,
) -> RetentionArtifactBinding raise {
  guard value is Object(fields) else {
    fail("artifact binding must be an object")
  }
  let expected = [
    "protocol_version", "retention_id", "workspace_id", "approval_digest", "command_digest",
  ]
  guard fields.length() == expected.length() &&
    fields.keys().all(key => expected.contains(key)) else {
    fail("artifact binding has unexpected or missing fields")
  }
  @json.from_json(value)
}

///|
async fn bound_artifact_record(
  binding : RetentionArtifactBinding,
  config : ExecutorConfig,
) -> RetentionRecord {
  guard binding.protocol_version == 1 &&
    safe_identifier(binding.retention_id) &&
    safe_identifier(binding.workspace_id) &&
    sha256_digest(binding.approval_digest) &&
    sha256_digest(binding.command_digest) &&
    config.limits.max_protocol_bytes >= 4096 else {
    fail("artifact binding is invalid")
  }
  let record = load_retention_record(binding.retention_id, config)
  guard record.workspace_id == binding.workspace_id &&
    record.approval_digest == binding.approval_digest &&
    record.command_digest == binding.command_digest else {
    fail("artifact binding does not match the retained execution")
  }
  record
}

///|
fn retained_artifact_byte_limit(config : ExecutorConfig) -> Int {
  (config.limits.max_disk_mib.to_int64() * 1_048_576L).min(16_777_216L).to_int()
}

///|
/// Explore the saved regular-file manifest. Filters are literal case-sensitive
/// path matches; `after` is the prior page's `next_after` under the same filters.
/// Metadata describes the retained revision; reading a file verifies its bytes.
pub async fn list_retained_artifacts(
  binding : RetentionArtifactBinding,
  config : ExecutorConfig,
  prefix? : String = "",
  contains? : String = "",
  after? : String = "",
  limit? : Int = 50,
) -> RetentionArtifactList {
  guard limit > 0 &&
    limit <= 200 &&
    prefix.length() <= 4096 &&
    contains.length() <= 4096 &&
    after.length() <= 4096 else {
    fail("artifact list filters or page size are invalid")
  }
  let record = bound_artifact_record(binding, config)
  let all = record.reviewable_files.copy()
  all.sort_by((left, right) => {
    left.relative_path[:].lexical_compare(right.relative_path[:])
  })
  let matched = all.filter(entry => {
    entry.relative_path.has_prefix(prefix) &&
    entry.relative_path.contains(contains)
  })
  let pending = matched.filter(entry => {
    entry.relative_path[:].lexical_compare(after[:]) > 0
  })
  let files : Array[@sandbox.ScratchEntry] = []
  let response = fn() -> RetentionArtifactList {
    {
      binding,
      expires_at_ms: record.expires_at_ms,
      total_files: all.length(),
      total_bytes: all.fold(init=0L, (sum, entry) => sum + entry.size_bytes),
      matched_files: matched.length(),
      matched_bytes: matched.fold(init=0L, (sum, entry) => {
        sum + entry.size_bytes
      }),
      files: files.copy(),
      next_after: if files.is_empty() {
        after
      } else {
        files[files.length() - 1].relative_path
      },
      has_more: files.length() < pending.length(),
      max_export_bytes: retained_artifact_byte_limit(config),
    }
  }
  for entry in pending {
    if files.length() == limit {
      break
    }
    files.push(entry)
    if @utf8.encode(response().to_json().stringify()).length() >
      config.limits.max_protocol_bytes {
      ignore(files.pop())
      guard !files.is_empty() else {
        fail("artifact metadata exceeds the response budget")
      }
      break
    }
  }
  let result = response()
  guard @utf8.encode(result.to_json().stringify()).length() <=
    config.limits.max_protocol_bytes else {
    fail("artifact metadata exceeds the response budget")
  }
  result
}

///|
async fn verified_retained_artifact(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
) -> (RetentionRecord, @sandbox.ScratchEntry, Bytes) {
  guard @sandbox.scratch_relative_path_is_safe(path) else {
    fail("artifact path is invalid")
  }
  let record = bound_artifact_record(binding, config)
  guard record.reviewable_files
    .filter(entry => entry.relative_path == path)
    .get(0)
    is Some(entry) else {
    fail("artifact is not in this retained manifest")
  }
  let bytes = @sandbox.read_scratch_artifact(
    record.scratch_path,
    entry,
    retained_artifact_byte_limit(config),
  )
  // A promotion or expiry during a read must not yield a fresh usable result.
  guard bound_artifact_record(binding, config) == record else {
    fail("retention changed during the artifact read")
  }
  (record, entry, bytes)
}

///|
/// Preview a verified file in bounded byte pages. Exact byte cursors can split
/// UTF-8; concatenate decoded base64 pages before decoding the full text.
pub async fn read_retained_artifact(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
  offset? : Int64 = 0L,
  max_bytes? : Int = 4096,
) -> RetentionArtifactPage {
  guard offset >= 0L && max_bytes > 0 && max_bytes <= 32_768 else {
    fail("artifact preview cursor or byte count is invalid")
  }
  let (record, entry, bytes) = verified_retained_artifact(binding, path, config)
  guard offset <= bytes.length().to_int64() else {
    fail("artifact preview cursor is beyond the end")
  }
  let empty : RetentionArtifactPage = {
    binding,
    expires_at_ms: record.expires_at_ms,
    file: entry,
    offset,
    next_offset: offset,
    content_base64: "",
    eof: false,
  }
  let overhead = @utf8.encode(empty.to_json().stringify()).length() + 64
  guard overhead < config.limits.max_protocol_bytes else {
    fail("artifact metadata exceeds the response budget")
  }
  let budget = ((config.limits.max_protocol_bytes - overhead) / 4 * 3).min(
    max_bytes,
  )
  guard budget > 0 else {
    fail("artifact metadata leaves no preview byte budget")
  }
  let start = offset.to_int()
  let count = (bytes.length() - start).min(budget)
  {
    ..empty,
    next_offset: offset + count.to_int64(),
    content_base64: @base64.encode(bytes[start:start + count]),
    eof: start + count == bytes.length(),
  }
}

///|
/// Export exactly one verified retained file, with no text decoding or newline.
/// This neither consumes execution grants nor promotes or modifies scratch.
pub async fn export_retained_artifact(
  binding : RetentionArtifactBinding,
  path : String,
  config : ExecutorConfig,
) -> Bytes {
  let (_, _, bytes) = verified_retained_artifact(binding, path, config)
  bytes
}

///|
pub extend RetentionArtifactBinding with @moonbitlang/core/debug.Debug::{
  to_repr,
}

///|
pub extend RetentionArtifactBinding with Eq::{not_equal, equal}

///|
pub extend RetentionArtifactBinding with ToJson::{to_json}

///|
pub extend RetentionArtifactBinding with @moonbitlang/core/json.FromJson::{
  from_json,
}

///|
pub extend RetentionArtifactList with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionArtifactList with Eq::{not_equal, equal}

///|
pub extend RetentionArtifactList with ToJson::{to_json}

///|
pub extend RetentionArtifactList with @moonbitlang/core/json.FromJson::{
  from_json,
}

///|
pub extend RetentionArtifactPage with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RetentionArtifactPage with Eq::{not_equal, equal}

///|
pub extend RetentionArtifactPage with ToJson::{to_json}

///|
pub extend RetentionArtifactPage with @moonbitlang/core/json.FromJson::{
  from_json,
}
