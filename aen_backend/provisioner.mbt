///|
const ProvisionerProtocolVersion : Int = 1

///|
const ProvisionerTimeoutMs : Int = 300_000

///|
fn immutable_oci_reference(value : String) -> Bool {
  guard !value.contains(" ") &&
    !value.contains("\n") &&
    !value.contains("\r") &&
    !value.contains("\t") else {
    return false
  }
  guard value.rev_find("@sha256:") is Some(index) else { return false }
  let digest = value[index + 8:]
  index > 0 &&
  digest.length() == 64 &&
  digest.all(character => {
    (character >= '0' && character <= '9') ||
    (character >= 'a' && character <= 'f')
  })
}

///|
fn provisioner_receipt_payload(lease : AenWorkspaceLease) -> String {
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
  ].join("\n")
}

///|
fn receipt_mac(key : String, payload : String) -> String {
  @crypto.bytes_to_hex_string(
    @crypto.hmac(
      @crypto.SHA256::new(),
      @utf8.encode(key),
      @utf8.encode(payload),
    ),
  )
}

///|
fn equal_mac(left : String, right : String) -> Bool {
  let left_bytes = @utf8.encode(left)
  let right_bytes = @utf8.encode(right)
  if left_bytes.length() != right_bytes.length() {
    return false
  }
  let mut mismatch = 0
  for index in 0..<left_bytes.length() {
    mismatch = mismatch |
      (left_bytes[index].to_int() ^ right_bytes[index].to_int())
  }
  mismatch == 0
}

///|
fn validate_workspace_lease(
  lease : AenWorkspaceLease,
  receipt_key : String,
  workspace_id : String,
  profile : @sandbox.SandboxProfile,
  max_workspace_bytes : Int64,
) -> Unit raise AenBackendError {
  guard lease.protocol_version == ProvisionerProtocolVersion &&
    safe_provider_identifier(lease.lease_id) &&
    lease.run_id == profile.run_id &&
    lease.workspace_id == workspace_id &&
    lease.profile_digest == @sandbox.profile_digest(profile) else {
    raise ProtocolFailure("workspace lease is not bound to this execution")
  }
  guard lease.workspace_digest.length() == 64 &&
    lease.workspace_digest.all(character => {
      (character >= '0' && character <= '9') ||
      (character >= 'a' && character <= 'f')
    }) &&
    immutable_oci_reference(lease.image_ref) else {
    raise ProtocolFailure("workspace lease is not content addressed")
  }
  guard lease.entry_count >= 0 &&
    lease.entry_count <= 1_000_000 &&
    lease.total_bytes >= 0L &&
    lease.total_bytes <= max_workspace_bytes else {
    raise ProtocolFailure("workspace lease exceeds its executor-owned bound")
  }
  guard lease.staging_cleanup_verified else {
    raise ProtocolFailure("workspace provisioner did not clean staging data")
  }
  let expected = receipt_mac(receipt_key, provisioner_receipt_payload(lease))
  guard equal_mac(expected, lease.receipt_mac) else {
    raise ProtocolFailure("workspace provisioner receipt MAC mismatch")
  }
}

///|
/// Ask a trusted provisioner to snapshot the executor-owned workspace ID into
/// a content-addressed OCI drive. The provisioner owns the workspace registry;
/// no host path or file bytes come from an untrusted invocation.
async fn[T : AenTransport] provision_workspace(
  transport : T,
  api_key~ : String,
  receipt_key~ : String,
  workspace_id~ : String,
  max_workspace_bytes~ : Int64,
  profile~ : @sandbox.SandboxProfile,
) -> AenWorkspaceLease {
  guard api_key.trim() != "" &&
    receipt_key.length() >= 32 &&
    safe_provider_identifier(workspace_id) &&
    max_workspace_bytes > 0L else {
    raise InvalidConfiguration("invalid workspace provisioner configuration")
  }
  let response = transport.request({
    verb: Post,
    path: "/v1/workspaces",
    headers: [
      { name: "X-API-Key", value: api_key },
      { name: "Content-Type", value: "application/json" },
    ],
    body: JsonBody({
      "protocolVersion": ProvisionerProtocolVersion,
      "runID": profile.run_id,
      "workspaceID": workspace_id,
      "profileDigest": @sandbox.profile_digest(profile),
      "maxBytes": max_workspace_bytes.to_string(),
      "rejectSymlinks": true,
      "requireImmutableImageDigest": true,
    }),
    timeout_ms: ProvisionerTimeoutMs,
    response_bytes: 65_536,
  })
  guard response.status == 201 else {
    raise TransportFailure(
      "workspace provisioner returned HTTP \{response.status}",
    )
  }
  let value = @json.parse(@utf8.decode(response.body)) catch {
    _ => raise ProtocolFailure("workspace provisioner returned invalid JSON")
  }
  let lease : AenWorkspaceLease = @json.from_json(value) catch {
    _ => raise ProtocolFailure("workspace provisioner receipt is malformed")
  }
  validate_workspace_lease(
    lease, receipt_key, workspace_id, profile, max_workspace_bytes,
  )
  lease
}

///|
/// Release the provisioner's per-run registry lease and transient source
/// material. A 404 is idempotent success; any other response is unverified.
async fn[T : AenTransport] release_workspace(
  transport : T,
  api_key~ : String,
  lease_id~ : String,
) -> Bool {
  guard api_key.trim() != "" && safe_provider_identifier(lease_id) else {
    return false
  }
  let response = transport.request({
    verb: Delete,
    path: "/v1/workspaces/\{url_segment(lease_id)}",
    headers: [{ name: "X-API-Key", value: api_key }],
    body: EmptyBody,
    timeout_ms: ControlTimeoutMs,
    response_bytes: 65_536,
  }) catch {
    _ => return false
  }
  response.status == 204 || response.status == 404
}
