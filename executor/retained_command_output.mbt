///|
// The backend-owned signed terminal spool is authoritative for local bytes.
// A string projection is retained only on older/non-local paths with no spool.
async fn retained_receipt_output_bytes(
  receipt : @sandbox.SandboxReceipt,
  grant : ExecutionGrant,
  approval_digest : String,
  live_output : LiveOutputReference?,
  config : ExecutorConfig,
) -> Bytes {
  guard grant.backend is LocalOs && live_output is Some(reference) else {
    return @utf8.encode(receipt.output)
  }
  guard safe_identifier(reference.stream_id) else { raise InvalidReference }
  let root = live_output_root(config)
  let record : LiveOutputRecord = @json.from_json(
    @json.parse(
      bounded_regular_file(
        root + "/" + reference.stream_id + ".json",
        config.limits.max_protocol_bytes,
      ),
    ),
  )
  guard live_output_reference_valid(record, config) &&
    record.reference == reference &&
    reference.run_id == grant.request_id &&
    receipt.run_id == grant.request_id &&
    record.approval_id == grant.approval_id &&
    record.approval_digest == approval_digest &&
    reference.status == live_output_terminal_status(receipt) &&
    (reference.status == "exited" || reference.status == "killed") &&
    reference.expires_at_ms > @env.now().reinterpret_as_int64() &&
    reference.size_bytes <= grant.limits.output_bytes.to_int64() else {
    raise ArtifactIntegrityFailure
  }
  let bytes = bounded_output_artifact_bytes(
    root + "/" + reference.stream_id + ".blob",
    reference.size_bytes,
    grant.limits.output_bytes,
  )
  guard @crypto.bytes_to_hex_string(@crypto.sha256(bytes)) == reference.sha256 else {
    raise ArtifactIntegrityFailure
  }
  bytes
}

///|
async fn retain_receipt_command_output(
  receipt : @sandbox.SandboxReceipt,
  grant : ExecutionGrant,
  approval_digest : String,
  command_digest : String,
  live_output : LiveOutputReference?,
  config : ExecutorConfig,
) -> @sandbox.SandboxReceipt {
  if !(receipt.status is Exited || receipt.status is Killed) {
    return receipt
  }
  let bytes = retained_receipt_output_bytes(
    receipt, grant, approval_digest, live_output, config,
  )
  if !output_artifact_required(receipt, config.limits.max_model_output_bytes) &&
    bytes == @utf8.encode(receipt.output) {
    return receipt
  }
  let artifact = retain_command_output_bytes(
    receipt.run_id,
    bytes,
    grant.limits.output_bytes,
    approval_digest,
    command_digest,
    config,
  )
  receipt.with_output_artifact(
    model_output_projection(
      receipt.output,
      config.limits.max_model_output_bytes.min(grant.limits.output_bytes),
    ),
    artifact,
  )
}
