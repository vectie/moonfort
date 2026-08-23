///|
const CommandOutputMediaType : String = "text/plain; charset=utf-8"

///|
pub(all) suberror CommandOutputArtifactRefusal {
  InvalidReference
  ArtifactExpired
  ArtifactUnavailable
  ArtifactIntegrityFailure
} derive(Debug, Eq, ToJson)

///|
fn command_output_artifact_root(config : ExecutorConfig) -> String {
  "\{config.retention_root}/output-artifacts"
}

///|
async fn artifact_root_is_private(config : ExecutorConfig) -> Bool {
  let root = command_output_artifact_root(config)
  try
    @fs.realpath(root) == root &&
    @fs.kind(root, follow_symlink=false) is Directory &&
    private_directory(root)
  catch {
    _ => false
  }
}

///|
fn output_artifact_payload(
  reference : @sandbox.CommandOutputArtifactRef,
  approval_digest : String,
  command_digest : String,
) -> String {
  [
    "moonfort-command-output-artifact-v1",
    reference.artifact_id,
    reference.run_id,
    reference.sha256,
    reference.size_bytes.to_string(),
    reference.media_type,
    reference.expires_at_ms.to_string(),
    reference.key_id,
    approval_digest,
    command_digest,
  ].join("\n")
}

///|
fn output_artifact_signature(
  reference : @sandbox.CommandOutputArtifactRef,
  approval_digest : String,
  command_digest : String,
  key : String,
) -> String {
  @crypto.bytes_to_hex_string(
    @crypto.hmac(
      @crypto.SHA256::new(),
      @utf8.encode(key),
      @utf8.encode(
        output_artifact_payload(reference, approval_digest, command_digest),
      ),
    ),
  )
}

///|
fn constant_time_string_equal(left : String, right : String) -> Bool {
  let left = @utf8.encode(left)
  let right = @utf8.encode(right)
  if left.length() != right.length() {
    return false
  }
  let mut difference = 0
  for index in 0..<left.length() {
    difference = difference | (left[index].to_int() ^ right[index].to_int())
  }
  difference == 0
}

///|
fn output_reference_is_well_formed(
  reference : @sandbox.CommandOutputArtifactRef,
  config : ExecutorConfig,
) -> Bool {
  safe_identifier(reference.artifact_id) &&
  safe_identifier(reference.run_id) &&
  sha256_digest(reference.sha256) &&
  reference.size_bytes >= 0L &&
  reference.size_bytes <= config.limits.max_output_bytes.to_int64() &&
  reference.media_type == CommandOutputMediaType &&
  reference.expires_at_ms > 0L &&
  reference.key_id == config.artifact_key_id &&
  sha256_digest(reference.signature)
}

///|
async fn bounded_output_artifact_bytes(
  path : String,
  expected_size : Int64,
  limit : Int,
) -> Bytes {
  guard expected_size >= 0L &&
    expected_size <= limit.to_int64() &&
    @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.realpath(path) == path &&
    protected_regular_file(path) else {
    raise ArtifactUnavailable
  }
  let file = @fs.open(path, mode=ReadOnly) catch {
    _ => raise ArtifactUnavailable
  }
  defer file.close()
  guard file.kind() is Regular && file.size() == expected_size else {
    raise ArtifactIntegrityFailure
  }
  let output = @buffer.Buffer(size_hint=expected_size.to_int().min(8_192))
  for ;; {
    guard file.read_some(max_len=(limit - output.length() + 1).min(8_192))
      is Some(chunk) else {
      break
    }
    guard output.length() + chunk.length() <= limit else {
      raise ArtifactIntegrityFailure
    }
    output.write_bytes(chunk)
  }
  guard output.length().to_int64() == expected_size &&
    file.size() == expected_size &&
    @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.realpath(path) == path else {
    raise ArtifactIntegrityFailure
  }
  output.to_bytes()
}

///|
fn bounded_utf8_prefix(bytes : Bytes, max_bytes : Int) -> String {
  for end = max_bytes.min(bytes.length()); end >= 0; end = end - 1 {
    let candidate = @utf8.decode_lossy(bytes[:end])
    if @utf8.encode(candidate).length() <= max_bytes {
      return candidate
    }
  }
  ""
}

///|
fn bounded_utf8_suffix(bytes : Bytes, max_bytes : Int) -> String {
  for start = (bytes.length() - max_bytes).max(0)
      start <= bytes.length()
      start = start + 1 {
    let candidate = @utf8.decode_lossy(bytes[start:])
    if @utf8.encode(candidate).length() <= max_bytes {
      return candidate
    }
  }
  ""
}

///|
fn model_output_projection(output : String, max_bytes : Int) -> String {
  let bytes = @utf8.encode(output)
  if bytes.length() <= max_bytes {
    return output
  }
  let marker = @utf8.encode("\n[... full output retained in artifact ...]\n")
  if max_bytes <= marker.length() {
    return bounded_utf8_prefix(bytes, max_bytes)
  }
  let available = max_bytes - marker.length()
  let head = available / 2
  let tail = available - head
  bounded_utf8_prefix(bytes, head) +
  @utf8.decode_lossy(marker) +
  bounded_utf8_suffix(bytes, tail)
}

///|
fn output_artifact_required(
  receipt : @sandbox.SandboxReceipt,
  max_model_output_bytes : Int,
) -> Bool {
  receipt.output_truncated ||
  @utf8.encode(receipt.output).length() > max_model_output_bytes
}

///|
async fn retain_command_output_artifact(
  run_id : String,
  output : String,
  output_limit : Int,
  approval_digest : String,
  command_digest : String,
  config : ExecutorConfig,
) -> @sandbox.CommandOutputArtifactRef {
  let bytes = @utf8.encode(output)
  guard artifact_root_is_private(config) &&
    safe_identifier(run_id) &&
    sha256_digest(approval_digest) &&
    sha256_digest(command_digest) &&
    output_limit > 0 &&
    output_limit <= config.limits.max_output_bytes &&
    bytes.length() <= output_limit &&
    retention_window_is_valid(config.limits.retention_ms) else {
    raise InvalidReference
  }
  guard @env.rand(16) is Some(random) else { raise ArtifactUnavailable }
  let artifact_id = @crypto.bytes_to_hex_string(random)
  let now = @env.now().reinterpret_as_int64()
  guard now >= 0L &&
    config.limits.retention_ms <= 9_223_372_036_854_775_807L - now else {
    raise ArtifactUnavailable
  }
  let unsigned : @sandbox.CommandOutputArtifactRef = {
    artifact_id,
    run_id,
    sha256: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    size_bytes: bytes.length().to_int64(),
    media_type: CommandOutputMediaType,
    expires_at_ms: now + config.limits.retention_ms,
    key_id: config.artifact_key_id,
    signature: "",
  }
  let reference = {
    ..unsigned,
    signature: output_artifact_signature(
      unsigned,
      approval_digest,
      command_digest,
      config.artifact_signing_key,
    ),
  }
  let record : CommandOutputArtifactRecord = {
    reference,
    approval_digest,
    command_digest,
  }
  let metadata = record.to_json().stringify()
  guard @utf8.encode(metadata).length() <= config.limits.max_protocol_bytes else {
    raise ArtifactUnavailable
  }
  let root = command_output_artifact_root(config)
  let blob = "\{root}/\{artifact_id}.blob"
  let manifest = "\{root}/\{artifact_id}.json"
  let blob_staging = "\{root}/.\{artifact_id}.blob.tmp"
  let manifest_staging = "\{root}/.\{artifact_id}.json.tmp"
  try {
    @fs.write_file(
      blob_staging,
      output,
      create_mode=CreateNew,
      permission=0o600,
      sync=Full,
    )
    @fs.write_file(
      manifest_staging,
      metadata,
      create_mode=CreateNew,
      permission=0o600,
      sync=Full,
    )
    guard @fs.kind(blob_staging, follow_symlink=false) is Regular &&
      @fs.kind(manifest_staging, follow_symlink=false) is Regular &&
      @fs.realpath(blob_staging) == blob_staging &&
      @fs.realpath(manifest_staging) == manifest_staging else {
      raise ArtifactUnavailable
    }
    @fs.rename(blob_staging, blob, replace=false)
    @fs.rename(manifest_staging, manifest, replace=false)
  } catch {
    _ => {
      ignore(@fs.remove(blob_staging) catch { _ => () })
      ignore(@fs.remove(manifest_staging) catch { _ => () })
      ignore(@fs.remove(blob) catch { _ => () })
      raise ArtifactUnavailable
    }
  }
  reference
}

///|
/// Read one complete retained output only after checking its opaque identity,
/// HMAC run/approval binding, lifetime, exact size, and SHA-256 digest.
pub async fn read_command_output_artifact(
  reference : @sandbox.CommandOutputArtifactRef,
  run_id : String,
  approval_digest : String,
  command_digest : String,
  config : ExecutorConfig,
) -> Bytes {
  guard artifact_root_is_private(config) &&
    output_reference_is_well_formed(reference, config) &&
    reference.run_id == run_id &&
    sha256_digest(approval_digest) &&
    sha256_digest(command_digest) else {
    raise InvalidReference
  }
  guard reference.expires_at_ms > @env.now().reinterpret_as_int64() else {
    raise ArtifactExpired
  }
  let root = command_output_artifact_root(config)
  let manifest_path = "\{root}/\{reference.artifact_id}.json"
  let blob_path = "\{root}/\{reference.artifact_id}.blob"
  let record : CommandOutputArtifactRecord = @json.from_json(
    @json.parse(
      bounded_regular_file(manifest_path, config.limits.max_protocol_bytes),
    ),
  ) catch {
    _ => raise ArtifactUnavailable
  }
  let expected_signature = output_artifact_signature(
    reference,
    approval_digest,
    command_digest,
    config.artifact_signing_key,
  )
  guard record.reference == reference &&
    record.approval_digest == approval_digest &&
    record.command_digest == command_digest &&
    constant_time_string_equal(reference.signature, expected_signature) else {
    raise ArtifactIntegrityFailure
  }
  let bytes = bounded_output_artifact_bytes(
    blob_path,
    reference.size_bytes,
    config.limits.max_output_bytes,
  )
  guard constant_time_string_equal(
    @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    reference.sha256,
  ) else {
    raise ArtifactIntegrityFailure
  }
  bytes
}

///|
async fn sweep_expired_output_artifacts(config : ExecutorConfig) -> Int {
  guard artifact_root_is_private(config) else { return 0 }
  let root = command_output_artifact_root(config)
  let now = @env.now().reinterpret_as_int64()
  let mut removed = 0
  for name in @fs.readdir(root, sort=true) {
    guard name.has_suffix(".json") else { continue }
    let id = name[:name.length() - 5].to_owned()
    guard safe_identifier(id) else { continue }
    let manifest = "\{root}/\{id}.json"
    let record : CommandOutputArtifactRecord = @json.from_json(
      @json.parse(
        bounded_regular_file(manifest, config.limits.max_protocol_bytes),
      ),
    ) catch {
      _ => continue
    }
    let reference = record.reference
    let signature = output_artifact_signature(
      reference,
      record.approval_digest,
      record.command_digest,
      config.artifact_signing_key,
    )
    guard reference.artifact_id == id &&
      output_reference_is_well_formed(reference, config) &&
      sha256_digest(record.approval_digest) &&
      sha256_digest(record.command_digest) &&
      constant_time_string_equal(reference.signature, signature) &&
      reference.expires_at_ms <= now else {
      continue
    }
    let blob = "\{root}/\{id}.blob"
    if @fs.exists(blob) {
      guard @fs.kind(blob, follow_symlink=false) is Regular &&
        @fs.realpath(blob) == blob else {
        continue
      }
      @fs.remove(blob) catch {
        _ => continue
      }
    }
    @fs.remove(manifest) catch {
      _ => continue
    }
    removed += 1
  }
  removed
}
