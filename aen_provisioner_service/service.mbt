///|
fn receipt_payload(lease : ProvisionerLease) -> String {
  [
    lease.protocol_version.to_string(),
    lease.lease_id,
    lease.run_id,
    lease.workspace_id,
    lease.profile_digest,
    lease.workspace_digest,
    lease.image_ref,
    lease.entry_count.to_string(),
    lease.total_bytes.to_string(),
    lease.staging_cleanup_verified.to_string(),
    lease.receipt_key_id,
  ].join("\n")
}

///|
fn receipt_mac(key : String, lease : ProvisionerLease) -> String {
  @crypto.bytes_to_hex_string(
    @crypto.hmac(
      @crypto.SHA256::new(),
      @utf8.encode(key),
      @utf8.encode(receipt_payload(lease)),
    ),
  )
}

///|
fn request_from_json(
  value : Json,
) -> ProvisionWorkspaceRequest raise ProvisionerError {
  guard value
    is {
      "protocolVersion": Number(protocol, repr=_),
      "runID": String(run_id),
      "workspaceID": String(workspace_id),
      "profileDigest": String(profile_digest),
      "maxBytes": String(max_bytes),
      "rejectSymlinks": reject_symlinks,
      "requireImmutableImageDigest": require_immutable,
      ..
    } else {
    raise InvalidRequest("request JSON does not match the provisioner protocol")
  }
  let protocol_version = protocol.to_int()
  guard protocol == protocol_version.to_double() else {
    raise InvalidRequest("protocol version is invalid")
  }
  let max_bytes : Int64 = @strconv.from_str(max_bytes) catch {
    _ => raise InvalidRequest("maxBytes is invalid")
  }
  let reject_symlinks = match reject_symlinks {
    True => true
    False => false
    _ => raise InvalidRequest("rejectSymlinks must be boolean")
  }
  let require_immutable_image_digest = match require_immutable {
    True => true
    False => false
    _ => raise InvalidRequest("requireImmutableImageDigest must be boolean")
  }
  {
    protocol_version,
    run_id,
    workspace_id,
    profile_digest,
    max_bytes,
    reject_symlinks,
    require_immutable_image_digest,
  }
}

///|
fn error_result(
  status : Int,
  reason : String,
  code : String,
) -> ProvisionerHttpResult {
  {
    status,
    reason,
    body: Json::object({ "error": code.to_json() }).stringify(),
  }
}

///|
fn authenticated(api_key : String, config : ProvisionerConfig) -> Bool {
  constant_time_equal(api_key, config.api_key)
}

///|
pub fn provision(
  api_key : String,
  body : String,
  config : ProvisionerConfig,
) -> ProvisionerHttpResult {
  validate_config(config) catch {
    _ =>
      return error_result(500, "Internal Server Error", "configuration-failure")
  }
  if !authenticated(api_key, config) {
    return error_result(401, "Unauthorized", "authentication-failed")
  }
  if @utf8.encode(body).length() > config.limits.max_request_bytes {
    return error_result(413, "Payload Too Large", "request-too-large")
  }
  let request = try {
    let value = @json.parse(body)
    request_from_json(value)
  } catch {
    _ => return error_result(400, "Bad Request", "invalid-request")
  }
  let workspace = validate_request(request, config) catch {
    InvalidRequest(_) =>
      return error_result(400, "Bad Request", "invalid-request")
    WorkspaceRefused(_) =>
      return error_result(403, "Forbidden", "workspace-refused")
    _ =>
      return error_result(500, "Internal Server Error", "configuration-failure")
  }
  guard @env.rand(16) is Some(random) else {
    return error_result(503, "Service Unavailable", "entropy-unavailable")
  }
  let lease_id = @crypto.bytes_to_hex_string(random)
  let provisioned = secure_snapshot(
    workspace.root,
    config.staging_root,
    config.artifact_root,
    config.registry_repository,
    lease_id,
    request.max_bytes.min(workspace.max_bytes),
    workspace.max_entries,
    workspace.max_file_bytes,
    config.limits.snapshot_timeout_ms,
  ) catch {
    _ => return error_result(422, "Unprocessable Content", "snapshot-refused")
  }
  let unsigned : ProvisionerLease = {
    protocol_version: provisioner_protocol_version,
    lease_id,
    run_id: request.run_id,
    workspace_id: request.workspace_id,
    profile_digest: request.profile_digest,
    workspace_digest: provisioned.workspace_digest,
    image_ref: provisioned.image_ref,
    entry_count: provisioned.entry_count,
    total_bytes: provisioned.total_bytes,
    staging_cleanup_verified: provisioned.staging_cleanup_verified,
    receipt_key_id: config.receipt_key_id,
    receipt_mac: "",
  }
  let lease = {
    ..unsigned,
    receipt_mac: receipt_mac(config.receipt_key, unsigned),
  }
  let encoded = lease.to_json().stringify()
  if encoded.length() > config.limits.max_response_bytes ||
    !write_lease(config.lease_root, lease_id, encoded) {
    return error_result(503, "Service Unavailable", "lease-storage-failed")
  }
  { status: 201, reason: "Created", body: encoded }
}

///|
pub fn release(
  api_key : String,
  lease_id : String,
  config : ProvisionerConfig,
) -> ProvisionerHttpResult {
  validate_config(config) catch {
    _ =>
      return error_result(500, "Internal Server Error", "configuration-failure")
  }
  if !authenticated(api_key, config) {
    return error_result(401, "Unauthorized", "authentication-failed")
  }
  if !safe_identifier(lease_id) {
    return error_result(400, "Bad Request", "invalid-lease-id")
  }
  match release_lease(config.lease_root, lease_id) {
    0 => { status: 204, reason: "No Content", body: "" }
    1 => error_result(404, "Not Found", "lease-not-found")
    _ => error_result(503, "Service Unavailable", "lease-release-failed")
  }
}

///|
async fn read_bounded_body(
  body : &@io.Reader,
  declared_length : Int,
  limit : Int,
) -> String {
  guard declared_length >= 0 && declared_length <= limit else {
    raise InvalidRequest("request body exceeds its bound")
  }
  let bytes = body.read_exactly(declared_length)
  @utf8.decode(bytes) catch {
    _ => raise InvalidRequest("request body is not UTF-8")
  }
}

///|
fn header_value(headers : Map[String, String], name : String) -> String? {
  headers.get(name.to_lower())
}

///|
async fn send_result(
  connection : @http.ServerConnection,
  result : ProvisionerHttpResult,
) -> Unit {
  let encoded = @utf8.encode(result.body)
  connection.send_response(result.status, result.reason, extra_headers={
    "Content-Type": "application/json",
    "Content-Length": encoded.length().to_string(),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  })
  if !encoded.is_empty() {
    connection.write(encoded)
  }
  connection.end_response()
}

///|
async fn handle_http_request(
  request : @http.Request,
  body : &@io.Reader,
  connection : @http.ServerConnection,
  config : ProvisionerConfig,
) -> Unit {
  let result = @async.with_timeout_opt(config.limits.request_timeout_ms, () => {
    let api_key = header_value(request.headers, "x-api-key").unwrap_or("")
    if request.headers.contains("transfer-encoding") {
      return error_result(400, "Bad Request", "streaming-body-refused")
    }
    match (request.meth, request.path) {
      (Post, "/v1/workspaces") => {
        guard header_value(request.headers, "content-length")
          is Some(raw_length) else {
          return error_result(411, "Length Required", "content-length-required")
        }
        let length : Int = @strconv.from_str(raw_length) catch {
          _ => return error_result(400, "Bad Request", "invalid-content-length")
        }
        let text = read_bounded_body(
          body,
          length,
          config.limits.max_request_bytes,
        ) catch {
          _ =>
            return error_result(413, "Payload Too Large", "request-too-large")
        }
        provision(api_key, text, config)
      }
      (Delete, [.. "/v1/workspaces/", .. lease_id]) =>
        release(api_key, lease_id.to_owned(), config)
      _ => error_result(404, "Not Found", "route-not-found")
    }
  })
  send_result(
    connection,
    result.unwrap_or_else(() => {
      error_result(408, "Request Timeout", "request-timeout")
    }),
  )
}

///|
pub async fn serve(config : ProvisionerConfig) -> Unit {
  validate_config(config)
  let address = @socket.Addr::parse(config.bind_address) catch {
    _ => raise InvalidConfiguration("bind address could not be parsed")
  }
  let server = @http.Server(address, dual_stack=false, reuse_addr=false)
  server.run_forever(
    (request, body, connection) => {
      handle_http_request(request, body, connection, config) catch {
        _ => connection.close()
      }
    },
    allow_failure=true,
    max_connections=config.limits.max_connections,
  )
}

///|
pub fn load_config(path : String) -> ProvisionerConfig raise ProvisionerError {
  guard safe_absolute_path(path) else {
    raise InvalidConfiguration("configuration file is not protected")
  }
  let bytes = read_protected_config(path, 1_048_576)
  guard !bytes.is_empty() else {
    raise InvalidConfiguration("configuration file size is invalid")
  }
  let text = @utf8.decode(bytes) catch {
    _ => raise InvalidConfiguration("configuration file is not UTF-8")
  }
  let config : ProvisionerConfig = @json.from_json(@json.parse(text)) catch {
    _ => raise InvalidConfiguration("configuration file is malformed")
  }
  validate_config(config)
  config
}
