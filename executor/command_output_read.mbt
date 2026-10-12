///|
/// The exact signed reference and receipt bindings are required for every read.
/// Offsets and limits count bytes, not Unicode characters.
pub(all) struct CommandOutputReadRequest {
  protocol_version : Int
  reference : @sandbox.CommandOutputArtifactRef
  run_id : String
  approval_digest : String
  command_digest : String
  offset : Int64
  max_bytes : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CommandOutputReadResponse {
  protocol_version : Int
  reference : @sandbox.CommandOutputArtifactRef?
  offset : Int64
  next_offset : Int64
  content_base64 : String
  eof : Bool
  status : String
  error : ExecutorProtocolError?
} derive(Debug, Eq, ToJson)

///|
fn command_output_read_error(
  status : String,
  code : String,
  message : String,
) -> CommandOutputReadResponse {
  {
    protocol_version: 1,
    reference: None,
    offset: 0L,
    next_offset: 0L,
    content_base64: "",
    eof: false,
    status,
    error: Some({ code, message, }),
  }
}

///|
/// Decode a closed protocol shape. Host paths, commands, and alternate output
/// references cannot be added to this read-only request.
pub fn decode_command_output_read_request(
  value : Json,
) -> CommandOutputReadRequest raise {
  guard value is Object(fields) else { fail("output read must be an object") }
  let expected = [
    "protocol_version", "reference", "run_id", "approval_digest", "command_digest",
    "offset", "max_bytes",
  ]
  guard fields.length() == expected.length() &&
    fields.keys().all(key => expected.contains(key)) else {
    fail("output read has unexpected or missing fields")
  }
  guard fields.get("reference") is Some(Object(reference)) else {
    fail("output read requires its original signed reference")
  }
  let reference_fields = [
    "artifact_id", "run_id", "sha256", "size_bytes", "media_type", "expires_at_ms",
    "key_id", "signature",
  ]
  guard reference.length() == reference_fields.length() &&
    reference.keys().all(key => reference_fields.contains(key)) else {
    fail("output reference has unexpected or missing fields")
  }
  @json.from_json(value)
}

///|
fn command_output_request_valid(
  request : CommandOutputReadRequest,
  config : ExecutorConfig,
) -> Bool {
  request.protocol_version == 1 &&
  request.offset >= 0L &&
  request.max_bytes > 0 &&
  request.max_bytes <= config.limits.max_output_bytes &&
  safe_identifier(request.run_id) &&
  config.limits.max_protocol_bytes >= 4_096
}

///|
/// Verify the complete retained object before returning any bytes. This never
/// consumes a grant, starts a command, extends retention, or promotes scratch.
/// A repeat read of the same cursor is safe until the reference expires.
pub async fn read_command_output(
  request : CommandOutputReadRequest,
  config : ExecutorConfig,
) -> CommandOutputReadResponse {
  guard command_output_request_valid(request, config) else {
    return command_output_read_error(
      "refused", "output-request-refused", "output read request is invalid",
    )
  }
  let bytes = read_command_output_artifact(
    request.reference,
    request.run_id,
    request.approval_digest,
    request.command_digest,
    config,
  ) catch {
    InvalidReference =>
      return command_output_read_error(
        "refused", "output-reference-refused", "output reference or receipt binding is invalid",
      )
    ArtifactExpired =>
      return command_output_read_error(
        "expired", "output-expired", "retained command output has expired",
      )
    ArtifactIntegrityFailure =>
      return command_output_read_error(
        "refused", "output-integrity-refused", "retained command output failed verification",
      )
    _ =>
      return command_output_read_error(
        "unavailable", "output-unavailable", "retained command output is unavailable",
      )
  }
  guard request.offset <= bytes.length().to_int64() else {
    return command_output_read_error(
      "refused", "output-cursor-refused", "output cursor is outside the retained artifact",
    )
  }
  // Reserve space for bounded metadata and base64 expansion in the response.
  let protocol_chunk_limit = (config.limits.max_protocol_bytes - 2_048) / 4 * 3
  let chunk_limit = request.max_bytes.min(32_768).min(protocol_chunk_limit)
  let start = request.offset.to_int()
  let count = (bytes.length() - start).min(chunk_limit)
  let next_offset = request.offset + count.to_int64()
  {
    protocol_version: 1,
    reference: Some(request.reference),
    offset: request.offset,
    next_offset,
    content_base64: @base64.encode(bytes[start:start + count]),
    eof: next_offset == bytes.length().to_int64(),
    status: "available",
    error: None,
  }
}

///|
/// Explicit full-file export uses the same verifier. The caller must name the
/// complete byte budget; a partial cursor is never mistaken for a full file.
pub async fn export_command_output(
  request : CommandOutputReadRequest,
  config : ExecutorConfig,
) -> Bytes {
  guard command_output_request_valid(request, config) &&
    request.offset == 0L &&
    request.reference.size_bytes <= request.max_bytes.to_int64() else {
    raise InvalidReference
  }
  read_command_output_artifact(
    request.reference,
    request.run_id,
    request.approval_digest,
    request.command_digest,
    config,
  )
}
