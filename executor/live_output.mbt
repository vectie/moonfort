///|
const LiveOutputContract : String = "moonfort.live-output.v1"

///|
const LiveOutputDefaultChunkBytes : Int = 32 * 1024

///|
const LiveOutputMaxChunkBytes : Int = 64 * 1024

///|
const LiveOutputRetryAfterMs : Int = 100

///|
fn live_output_root(config : ExecutorConfig) -> String {
  "\{config.retention_root}/live-output"
}

///|
async fn live_output_root_is_private(config : ExecutorConfig) -> Bool {
  let root = live_output_root(config)
  try
    @fs.realpath(root) == root &&
    @fs.kind(root, follow_symlink=false) is Directory &&
    private_directory(root)
  catch {
    _ => false
  }
}

///|
fn live_output_stream_id(
  approval_id : String,
  config : ExecutorConfig,
) -> String {
  @crypto.bytes_to_hex_string(
    @crypto.hmac(
      @crypto.SHA256::new(),
      @utf8.encode(config.artifact_signing_key),
      @utf8.encode(LiveOutputContract + "\napproval\n" + approval_id),
    ),
  )
}

///|
fn live_output_signature_payload(
  reference : LiveOutputReference,
  approval_id : String,
  approval_digest : String,
) -> String {
  [
    LiveOutputContract,
    reference.stream_id,
    reference.run_id,
    reference.status,
    reference.size_bytes.to_string(),
    reference.sha256,
    reference.expires_at_ms.to_string(),
    reference.key_id,
    approval_id,
    approval_digest,
  ].join("\n")
}

///|
fn sign_live_output_reference(
  reference : LiveOutputReference,
  approval_id : String,
  approval_digest : String,
  config : ExecutorConfig,
) -> LiveOutputReference {
  {
    ..reference,
    signature: @crypto.bytes_to_hex_string(
      @crypto.hmac(
        @crypto.SHA256::new(),
        @utf8.encode(config.artifact_signing_key),
        @utf8.encode(
          live_output_signature_payload(reference, approval_id, approval_digest),
        ),
      ),
    ),
  }
}

///|
fn live_output_reference_valid(
  record : LiveOutputRecord,
  config : ExecutorConfig,
) -> Bool {
  let reference = record.reference
  let expected = sign_live_output_reference(
    { ..reference, signature: "" },
    record.approval_id,
    record.approval_digest,
    config,
  )
  reference.stream_id == live_output_stream_id(record.approval_id, config) &&
  safe_identifier(reference.run_id) &&
  ["running", "exited", "killed", "failed"].contains(reference.status) &&
  reference.size_bytes >= 0L &&
  reference.size_bytes <= config.limits.max_output_bytes.to_int64() &&
  sha256_digest(reference.sha256) &&
  reference.expires_at_ms > 0L &&
  reference.key_id == config.artifact_key_id &&
  sha256_digest(record.approval_digest) &&
  constant_time_string_equal(reference.signature, expected.signature)
}

///|
async fn write_live_output_record(
  record : LiveOutputRecord,
  replace : Bool,
  config : ExecutorConfig,
) -> Unit {
  guard live_output_root_is_private(config) &&
    live_output_reference_valid(record, config) else {
    fail("invalid live output record")
  }
  let root = live_output_root(config)
  let id = record.reference.stream_id
  let manifest = "\{root}/\{id}.json"
  let staging = "\{root}/.\{id}.\{record.reference.status}.tmp"
  let payload = record.to_json().stringify()
  guard @utf8.encode(payload).length() <= config.limits.max_protocol_bytes else {
    fail("live output manifest exceeds protocol policy")
  }
  ignore(@fs.remove(staging) catch { _ => () })
  @fs.write_file(
    staging,
    payload,
    create_mode=CreateNew,
    permission=0o600,
    sync=Full,
  )
  guard @fs.kind(staging, follow_symlink=false) is Regular &&
    @fs.realpath(staging) == staging &&
    protected_regular_file(staging) else {
    ignore(@fs.remove(staging) catch { _ => () })
    fail("live output manifest staging is unsafe")
  }
  @fs.rename(staging, manifest, replace~)
  guard sync_private_directory(root) else {
    fail("live output manifest directory could not be synchronized")
  }
}

///|
async fn begin_live_output(
  run_id : String,
  approval_id : String,
  approval_digest : String,
  config : ExecutorConfig,
) -> LiveOutputReference {
  guard live_output_root_is_private(config) &&
    safe_identifier(run_id) &&
    safe_identifier(approval_id) &&
    sha256_digest(approval_digest) &&
    retention_window_is_valid(config.limits.retention_ms) else {
    fail("live output request is invalid")
  }
  let now = @env.now().reinterpret_as_int64()
  guard now >= 0L &&
    config.limits.retention_ms <= 9_223_372_036_854_775_807L - now else {
    fail("live output lifetime is invalid")
  }
  let unsigned : LiveOutputReference = {
    stream_id: live_output_stream_id(approval_id, config),
    run_id,
    status: "running",
    size_bytes: 0L,
    sha256: @crypto.bytes_to_hex_string(@crypto.sha256(b"")),
    expires_at_ms: now + config.limits.retention_ms,
    key_id: config.artifact_key_id,
    signature: "",
  }
  let reference = sign_live_output_reference(
    unsigned, approval_id, approval_digest, config,
  )
  write_live_output_record(
    { reference, approval_id, approval_digest },
    false,
    config,
  )
  reference
}

///|
fn live_output_terminal_status(receipt : @sandbox.SandboxReceipt) -> String {
  match receipt.status {
    Exited => "exited"
    Killed => "killed"
    Failed | Created | Running => "failed"
  }
}

///|
async fn finalize_live_output(
  started : LiveOutputReference,
  approval_id : String,
  approval_digest : String,
  receipt : @sandbox.SandboxReceipt,
  config : ExecutorConfig,
) -> LiveOutputReference {
  let root = live_output_root(config)
  let blob = "\{root}/\{started.stream_id}.blob"
  if !(@fs.exists(blob) catch { _ => false }) {
    @fs.write_file(
      blob,
      b"",
      create_mode=CreateNew,
      permission=0o600,
      sync=Full,
    )
  }
  guard @fs.kind(blob, follow_symlink=false) is Regular &&
    @fs.realpath(blob) == blob &&
    protected_regular_file(blob) else {
    fail("live output blob is unavailable")
  }
  let size_file = @fs.open(blob, mode=ReadOnly)
  let size = size_file.size()
  size_file.close()
  let bytes = bounded_output_artifact_bytes(
    blob,
    size,
    config.limits.max_output_bytes,
  )
  let unsigned : LiveOutputReference = {
    ..started,
    status: live_output_terminal_status(receipt),
    size_bytes: size,
    sha256: @crypto.bytes_to_hex_string(@crypto.sha256(bytes)),
    signature: "",
  }
  let reference = sign_live_output_reference(
    unsigned, approval_id, approval_digest, config,
  )
  write_live_output_record(
    { reference, approval_id, approval_digest },
    true,
    config,
  )
  reference
}

///|
fn live_output_read_error(
  approval_id : String,
  code : String,
  message : String,
) -> LiveOutputReadResponse {
  {
    protocol_version: 1,
    approval_id,
    stream_id: "",
    run_id: "",
    offset: 0L,
    next_offset: 0L,
    available_bytes: 0L,
    content_base64: "",
    status: "unavailable",
    terminal: true,
    retry_after_ms: 0,
    error: Some({ code, message }),
  }
}

///|
pub async fn read_live_output(
  request : LiveOutputReadRequest,
  config : ExecutorConfig,
) -> LiveOutputReadResponse {
  if request.protocol_version != 1 ||
    !safe_identifier(request.approval_id) ||
    request.offset < 0L {
    return live_output_read_error(
      request.approval_id,
      "live-output-request-refused",
      "live output request is invalid",
    )
  }
  let chunk_limit = if request.max_bytes <= 0 {
    LiveOutputDefaultChunkBytes
  } else {
    request.max_bytes.min(LiveOutputMaxChunkBytes)
  }
  let id = live_output_stream_id(request.approval_id, config)
  let root = live_output_root(config)
  let manifest = "\{root}/\{id}.json"
  let record : LiveOutputRecord = @json.from_json(
    @json.parse(
      bounded_regular_file(manifest, config.limits.max_protocol_bytes),
    ),
  ) catch {
    _ =>
      return live_output_read_error(
        request.approval_id,
        "live-output-unavailable",
        "live output has not started or is no longer retained",
      )
  }
  if !live_output_reference_valid(record, config) ||
    record.approval_id != request.approval_id ||
    record.reference.expires_at_ms <= @env.now().reinterpret_as_int64() {
    return live_output_read_error(
      request.approval_id,
      "live-output-integrity-refused",
      "live output reference is invalid or expired",
    )
  }
  let blob = "\{root}/\{id}.blob"
  let available = if @fs.exists(blob) {
    guard @fs.kind(blob, follow_symlink=false) is Regular &&
      @fs.realpath(blob) == blob &&
      protected_regular_file(blob) else {
      return live_output_read_error(
        request.approval_id,
        "live-output-integrity-refused",
        "live output blob is unsafe",
      )
    }
    let file = @fs.open(blob, mode=ReadOnly)
    let size = file.size()
    file.close()
    size
  } else {
    0L
  }
  if available > config.limits.max_output_bytes.to_int64() ||
    request.offset > available {
    return live_output_read_error(
      request.approval_id,
      "live-output-cursor-refused",
      "live output cursor is outside the retained stream",
    )
  }
  if record.reference.status != "running" {
    if available != record.reference.size_bytes {
      return live_output_read_error(
        request.approval_id,
        "live-output-integrity-refused",
        "terminal live output size does not match its signed reference",
      )
    }
    let complete = bounded_output_artifact_bytes(
      blob,
      available,
      config.limits.max_output_bytes,
    ) catch {
      _ =>
        return live_output_read_error(
          request.approval_id,
          "live-output-integrity-refused",
          "terminal live output could not be validated",
        )
    }
    if !constant_time_string_equal(
        @crypto.bytes_to_hex_string(@crypto.sha256(complete)),
        record.reference.sha256,
      ) {
      return live_output_read_error(
        request.approval_id,
        "live-output-integrity-refused",
        "terminal live output digest mismatch",
      )
    }
  }
  let count = (available - request.offset).min(chunk_limit.to_int64()).to_int()
  let bytes = if count == 0 {
    b""
  } else {
    let file = @fs.open(blob, mode=ReadOnly)
    defer file.close()
    file.read_exactly_at(count, position=request.offset)
  }
  let next = request.offset + bytes.length().to_int64()
  let terminal = record.reference.status != "running" && next == available
  {
    protocol_version: 1,
    approval_id: request.approval_id,
    stream_id: record.reference.stream_id,
    run_id: record.reference.run_id,
    offset: request.offset,
    next_offset: next,
    available_bytes: available,
    content_base64: @base64.encode(bytes),
    status: record.reference.status,
    terminal,
    retry_after_ms: if terminal || bytes.length() > 0 {
      0
    } else {
      LiveOutputRetryAfterMs
    },
    error: None,
  }
}

///|
async fn sweep_expired_live_output(config : ExecutorConfig) -> Int {
  guard live_output_root_is_private(config) else { return 0 }
  let root = live_output_root(config)
  let now = @env.now().reinterpret_as_int64()
  let mut removed = 0
  for name in @fs.readdir(root, sort=true) {
    guard name.has_suffix(".json") else { continue }
    let id = name[:name.length() - 5].to_owned()
    let record : LiveOutputRecord = @json.from_json(
      @json.parse(
        bounded_regular_file(
          "\{root}/\{name}",
          config.limits.max_protocol_bytes,
        ),
      ),
    ) catch {
      _ => continue
    }
    guard id == record.reference.stream_id &&
      live_output_reference_valid(record, config) &&
      record.reference.expires_at_ms <= now else {
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
    @fs.remove("\{root}/\{name}") catch {
      _ => continue
    }
    removed += 1
  }
  removed
}
