///|
const ControlTimeoutMs : Int = 30_000

///|
/// One fail-closed AgentENV lifecycle controller. It never owns a local-process
/// fallback. A transport or protocol error is raised and moves the controller
/// to `Refused`.
pub struct AenBackend[T] {
  priv transport : T
  priv api_key : String
  priv executor_image_ref : String
  priv workspace_lease : AenWorkspaceLease
  priv expected_vcpu_count : Int
  priv expected_root_disk_mib : Int
  priv guest_workspace : String
  priv guest_scratch : String
  priv guest_attester : String
  priv guest_supervisor : String
  priv executor_root_digest : String
  priv guest_attester_digest : String
  priv guest_supervisor_digest : String
  priv tool_registry_digest : String
  priv require_guest_attestation : Bool
  priv warm_snapshot_compat : Bool
  priv guest_tools : Map[String, String]
  priv profile : @sandbox.SandboxProfile
  priv digest : String
  priv mut create_in_flight : Bool
  priv mut sandbox_id : String?
  priv pending_child_ids : Array[String]
  priv mut state : AenLifecycleState
}

///|
fn[T] AenBackend::new(
  transport : T,
  api_key~ : String,
  snapshot_id? : String,
  executor_image_ref? : String = "registry.invalid/moonfort/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  workspace_lease? : AenWorkspaceLease,
  expected_vcpu_count~ : Int,
  expected_root_disk_mib? : Int = 0,
  guest_workspace? : String = "/workspace",
  guest_scratch? : String = "/scratch",
  guest_attester? : String = "/opt/moonfort/bin/attester",
  guest_supervisor? : String = "/opt/moonfort/bin/supervisor",
  executor_root_digest? : String = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  guest_attester_digest? : String = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  guest_supervisor_digest? : String = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  tool_registry_digest? : String = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
  require_guest_attestation? : Bool = false,
  guest_tools~ : Map[String, String],
  profile~ : @sandbox.SandboxProfile,
) -> AenBackend[T] raise AenBackendError {
  let warm_snapshot_compat = snapshot_id is Some(_)
  let executor_image_ref = match snapshot_id {
    Some(value) if !require_guest_attestation => value
    _ => executor_image_ref
  }
  let expected_root_disk_mib = if expected_root_disk_mib == 0 &&
    !require_guest_attestation {
    profile.limits.disk_mib
  } else {
    expected_root_disk_mib
  }
  let workspace_lease = match workspace_lease {
    Some(value) => value
    None =>
      {
        protocol_version: ProvisionerProtocolVersion,
        lease_id: "wbtest-lease",
        run_id: profile.run_id,
        workspace_id: "wbtest-workspace",
        profile_digest: @sandbox.profile_digest(profile),
        workspace_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        image_ref: "registry.invalid/moonfort/workspace@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        entry_count: 0,
        total_bytes: 0L,
        staging_cleanup_verified: true,
        receipt_key_id: "wbtest-key",
        receipt_mac: "wbtest",
      }
  }
  guard profile.backend is MicroVm else {
    raise InvalidConfiguration("AEN requires the MicroVm backend kind")
  }
  let rejection = @sandbox.profile_rejection(profile)
  guard rejection == "" else { raise InvalidConfiguration(rejection) }
  guard api_key.trim() != "" else {
    raise InvalidConfiguration("AEN API key is required")
  }
  guard !require_guest_attestation ||
    immutable_oci_reference(executor_image_ref) else {
    raise InvalidConfiguration(
      "AEN executor image must use an immutable sha256 OCI reference",
    )
  }
  guard workspace_lease.run_id == profile.run_id &&
    workspace_lease.profile_digest == @sandbox.profile_digest(profile) &&
    immutable_oci_reference(workspace_lease.image_ref) else {
    raise InvalidConfiguration(
      "AEN workspace lease is not bound to this profile",
    )
  }
  guard canonical_guest_path(guest_workspace) else {
    raise InvalidConfiguration("guest workspace must be canonical absolute")
  }
  guard expected_vcpu_count > 0 else {
    raise InvalidConfiguration("AEN expected vCPU count must be positive")
  }
  guard !require_guest_attestation ||
    (expected_root_disk_mib >= 1_024 && expected_root_disk_mib % 1_024 == 0) else {
    raise InvalidConfiguration(
      "AEN root disk size must be at least 1024 MiB and GiB-aligned",
    )
  }
  guard canonical_guest_path(guest_scratch) &&
    !guest_paths_overlap(guest_workspace, guest_scratch) else {
    raise InvalidConfiguration(
      "guest scratch must be canonical absolute and disjoint",
    )
  }
  for capability in profile.allowed_commands {
    guard guest_tools.get(capability) is Some(path) && path.has_prefix("/") else {
      raise InvalidConfiguration(
        "AEN guest tool \{capability} needs an absolute trusted binding",
      )
    }
  }
  guard canonical_guest_path(guest_attester) &&
    canonical_guest_path(guest_supervisor) &&
    guest_attester != guest_supervisor else {
    raise InvalidConfiguration(
      "AEN guest attester and supervisor need distinct absolute paths",
    )
  }
  guard !require_guest_attestation ||
    (
      sha256_digest(executor_root_digest) &&
      sha256_digest(guest_attester_digest) &&
      sha256_digest(guest_supervisor_digest) &&
      sha256_digest(tool_registry_digest)
    ) else {
    raise InvalidConfiguration(
      "AEN guest runtime identities must be lowercase SHA-256 digests",
    )
  }
  {
    transport,
    api_key,
    executor_image_ref,
    workspace_lease,
    expected_vcpu_count,
    expected_root_disk_mib,
    guest_workspace,
    guest_scratch,
    guest_attester,
    guest_supervisor,
    executor_root_digest,
    guest_attester_digest,
    guest_supervisor_digest,
    tool_registry_digest,
    require_guest_attestation,
    warm_snapshot_compat,
    guest_tools,
    profile,
    digest: @sandbox.profile_digest(profile),
    create_in_flight: false,
    sandbox_id: None,
    pending_child_ids: [],
    state: Created,
  }
}

///|
fn sha256_digest(value : String) -> Bool {
  value.length() == 64 &&
  value.all(character => {
    (character >= '0' && character <= '9') ||
    (character >= 'a' && character <= 'f')
  })
}

///|
fn canonical_guest_path(path : String) -> Bool {
  path.has_prefix("/") &&
  path != "/" &&
  !path.contains("//") &&
  !path.contains("\\") &&
  !path.contains("\u{0}") &&
  !path.split("/").any(component => component == "." || component == "..") &&
  !path.has_suffix("/")
}

///|
fn guest_paths_overlap(left : String, right : String) -> Bool {
  left == right || left.has_prefix(right + "/") || right.has_prefix(left + "/")
}

///|
fn safe_provider_identifier(value : String) -> Bool {
  value.length() >= 1 &&
  value.length() <= 128 &&
  value.all(character => {
    (character >= 'a' && character <= 'z') ||
    (character >= 'A' && character <= 'Z') ||
    (character >= '0' && character <= '9') ||
    character == '-' ||
    character == '_' ||
    character == '.' ||
    character == ':'
  })
}

///|
fn opaque_provider_identifier(value : String) -> String {
  if safe_provider_identifier(value) {
    value
  } else {
    "sha256-" + @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(value)))
  }
}

///|
fn tool_bindings_digest(bindings : Map[String, String]) -> String {
  let labels = bindings.keys().collect()
  labels.sort()
  let rows : Array[Json] = [
    for label in labels => { "label": label, "path": bindings[label] }
  ]
  @crypto.bytes_to_hex_string(
    @crypto.sha256(@utf8.encode(rows.to_json().stringify())),
  )
}

///|
pub fn[T] AenBackend::state(self : AenBackend[T]) -> AenLifecycleState {
  self.state
}

///|
pub fn[T] AenBackend::sandbox_id(self : AenBackend[T]) -> String? {
  self.sandbox_id
}

///|
fn[T] AenBackend::refuse(
  self : AenBackend[T],
  message : String,
) -> AenBackendError {
  self.state = Refused
  TransportFailure(message)
}

///|
fn[T] AenBackend::retained_vm_id(self : AenBackend[T]) -> String? {
  let ids = self.pending_child_ids.copy()
  match self.sandbox_id {
    Some(id) => ids.push(id)
    None => ()
  }
  ids.sort()
  if ids.is_empty() {
    None
  } else {
    Some("aen-vms:\{ids.map(opaque_provider_identifier).join(",")}")
  }
}

///|
fn cleanup_suffix(cleanup_verified : Bool) -> String {
  if cleanup_verified {
    "VM cleanup verified"
  } else {
    "VM cleanup unverified"
  }
}

///|
fn[T] AenBackend::refused_after_cleanup(
  self : AenBackend[T],
  reason : String,
  cleanup_verified : Bool,
) -> @sandbox.SandboxReceipt {
  self.state = Refused
  {
    ..@sandbox.refused_receipt(
      self.profile.run_id,
      MicroVm,
      self.digest,
      "\{reason}; \{cleanup_suffix(cleanup_verified)}",
    ),
    cleanup_verified,
    retention_id: if cleanup_verified {
      None
    } else {
      self.retained_vm_id()
    },
  }
}

///|
async fn[T : AenTransport] AenBackend::discard_protected(
  self : AenBackend[T],
) -> Bool {
  @async.protect_from_cancel(
    () => self.discard_checked(),
    resume_on_cancel=true,
  ) catch {
    _ => false
  }
}

///|
async fn[T : AenTransport] AenBackend::raise_after_cleanup(
  self : AenBackend[T],
  operation : String,
  original : Error,
) -> Unit {
  let cleanup_verified = self.discard_protected()
  self.state = Refused
  if @async.is_cancellation_error(original) {
    raise original
  }
  raise TransportFailure(
    "AEN \{operation} failed; \{cleanup_suffix(cleanup_verified)}",
  )
}

///|
fn[T] AenBackend::base_receipt(
  self : AenBackend[T],
  status : @sandbox.SandboxRunStatus,
) -> @sandbox.SandboxReceipt {
  {
    run_id: self.profile.run_id,
    approval_id: "",
    approval_digest: "",
    command_digest: "",
    backend: MicroVm,
    enforcement: Enforced,
    status,
    profile_digest: self.digest,
    exit_code: None,
    output: "",
    output_truncated: false,
    limit_reason: None,
    unverified_limits: [],
    changed_paths: [],
    changes: [],
    artifacts: [],
    denial_reason: None,
    cleanup_verified: false,
    retention_id: self.retained_vm_id(),
  }
}

///|
fn network_json(profile : @sandbox.SandboxProfile) -> Json {
  match profile.network {
    Deny =>
      { "allowPublicTraffic": false, "allowOut": [], "denyOut": ["0.0.0.0/0"] }
    AllowList =>
      {
        "allowPublicTraffic": false,
        "allowOut": profile.allowed_egress,
        "denyOut": ["0.0.0.0/0"],
      }
    Unrestricted =>
      { "allowPublicTraffic": false, "allowOut": [], "denyOut": [] }
  }
}

///|
fn requested_metadata(
  profile : @sandbox.SandboxProfile,
  digest : String,
) -> Map[String, Json] {
  {
    "moonfort.requested_profile_digest": digest,
    "moonfort.run_id": profile.run_id,
  }
}

///|
/// Compatibility-only fixture attestation for the private lifecycle tests.
/// Production construction always enables immutable in-guest attestation and
/// never relies on these caller-visible metadata keys.
fn[T] AenBackend::compat_required_attestation(
  self : AenBackend[T],
) -> Map[String, Json] {
  {
    "moonfort.enforced_profile_digest": self.digest,
    "moonfort.enforcement_contract": "moonfort-aen-v1",
    "moonfort.cpu_seconds": self.profile.limits.cpu_seconds.to_string(),
    "moonfort.read_only_source_snapshot": self.executor_image_ref,
    "moonfort.guest_workspace": self.guest_workspace,
    "moonfort.guest_scratch": self.guest_scratch,
    "moonfort.disk_limit_mib": self.profile.limits.disk_mib.to_string(),
    "moonfort.process_limit": self.profile.limits.processes.to_string(),
    "moonfort.output_limit_bytes": self.profile.limits.output_bytes.to_string(),
    "moonfort.tool_bindings_digest": tool_bindings_digest(self.guest_tools),
  }
}

///|
fn required_string(
  object : Map[String, Json],
  key : String,
) -> String raise AenBackendError {
  match object.get(key) {
    Some(String(value)) if value != "" => value
    _ => raise ProtocolFailure("AgentENV response is missing \{key}")
  }
}

///|
fn required_int(
  object : Map[String, Json],
  key : String,
) -> Int raise AenBackendError {
  match object.get(key) {
    Some(Number(value, ..)) => value.to_int()
    _ => raise ProtocolFailure("AgentENV response is missing numeric \{key}")
  }
}

///|
fn required_object(
  object : Map[String, Json],
  key : String,
) -> Map[String, Json] raise AenBackendError {
  match object.get(key) {
    Some(Object(value)) => value
    _ => raise ProtocolFailure("AgentENV response is missing object \{key}")
  }
}

///|
fn json_object(
  value : Json,
  context : String,
) -> Map[String, Json] raise AenBackendError {
  match value {
    Object(object) => object
    _ => raise ProtocolFailure("AgentENV \{context} response must be an object")
  }
}

///|
fn string_array(
  object : Map[String, Json],
  key : String,
) -> Array[String] raise AenBackendError {
  match object.get(key) {
    Some(Array(values)) =>
      values.map(value => {
        match value {
          String(text) => text
          _ => raise ProtocolFailure("AgentENV \{key} must contain strings")
        }
      })
    None => []
    _ => raise ProtocolFailure("AgentENV \{key} must be an array")
  }
}

///|
fn same_strings(left : Array[String], right : Array[String]) -> Bool {
  let left = left.copy()
  let right = right.copy()
  left.sort()
  right.sort()
  left == right
}

///|
fn verify_network_attestation(
  profile : @sandbox.SandboxProfile,
  detail : Map[String, Json],
) -> Unit raise AenBackendError {
  let expected_internet_access = profile.network is Unrestricted
  guard required_bool(detail, "allowInternetAccess") == expected_internet_access else {
    raise ProtocolFailure(
      "AgentENV top-level internet policy does not match the profile",
    )
  }
  let network = required_object(detail, "network")
  guard !required_bool(network, "allowPublicTraffic") else {
    raise ProtocolFailure("AgentENV sandbox traffic is not confirmed private")
  }
  let expected = json_object(network_json(profile), "expected network")
  guard same_strings(
      string_array(network, "allowOut"),
      string_array(expected, "allowOut"),
    ) &&
    same_strings(
      string_array(network, "denyOut"),
      string_array(expected, "denyOut"),
    ) else {
    raise ProtocolFailure(
      "AgentENV network attestation does not match the profile",
    )
  }
}

///|
/// Stock AEN's egress chain is implemented with IPv4 iptables. Before a
/// denied-network profile can become Enforced, independently verify from the
/// immutable guest image that every present IPv6 interface has IPv6 disabled.
/// This fixed command runs before any caller-controlled process.
async fn[T : AenTransport] AenBackend::verify_guest_ipv6_disabled(
  self : AenBackend[T],
  sandbox_id : String,
) -> Unit {
  if self.profile.network is Unrestricted {
    return
  }
  let probe_script =
    #|if [ -d /proc/sys/net/ipv6/conf ]; then
    #|  found=false
    #|  for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    #|    [ -f "$path" ] || exit 91
    #|    found=true
    #|    IFS= read -r value < "$path"
    #|    [ "$value" = 1 ] || exit 92
    #|  done
    #|  [ "$found" = true ] || exit 93
    #|fi
    #|printf '%s\n' '{"ipv6Disabled":true}'
    #|
  let detail = self.run_fixed_guest_json(
    sandbox_id,
    "/bin/sh",
    ["-eu", "-c", probe_script],
    "/",
    max_bytes=1_024,
  )
  let object = json_object(detail, "guest IPv6 attestation")
  guard required_bool(object, "ipv6Disabled") else {
    raise ProtocolFailure("AEN guest IPv6 is not confirmed disabled")
  }
}

///|
fn[T] AenBackend::verify_attestation(
  self : AenBackend[T],
  detail : Json,
  sandbox_id : String,
) -> Unit raise AenBackendError {
  let object = json_object(detail, "sandbox detail")
  guard required_string(object, "sandboxID") == sandbox_id else {
    raise ProtocolFailure("AgentENV attested a different sandbox ID")
  }
  guard required_string(object, "templateID") == self.executor_image_ref else {
    raise ProtocolFailure("AgentENV did not start the immutable executor image")
  }
  guard required_string(object, "state") == "running" else {
    raise ProtocolFailure("AgentENV sandbox is not running")
  }
  guard required_int(object, "cpuCount") == self.expected_vcpu_count else {
    raise ProtocolFailure("AgentENV CPU allocation does not match the profile")
  }
  guard required_int(object, "memoryMB") == self.profile.limits.memory_mib else {
    raise ProtocolFailure(
      "AgentENV memory allocation does not match the profile",
    )
  }
  guard required_int(object, "diskSizeMB") == self.expected_root_disk_mib else {
    raise ProtocolFailure("AgentENV root disk allocation does not match")
  }
  if self.warm_snapshot_compat {
    let metadata = required_object(object, "metadata")
    for key, expected in self.compat_required_attestation() {
      guard metadata.get(key) == Some(expected) else {
        raise ProtocolFailure(
          "AgentENV fixture attestation mismatch for \{key}",
        )
      }
    }
  }
  verify_network_attestation(self.profile, object)
  let lifecycle = required_object(object, "lifecycle")
  guard lifecycle.get("onTimeout") is Some(String("kill")) else {
    raise ProtocolFailure("AgentENV TTL must kill, not pause")
  }
}

///|
/// Create a stock AEN cold sandbox from an immutable executor image and attach
/// the provisioned workspace OCI image as a read-only drive. Canonical host
/// files are never mounted into the VM. `Enforced` is returned only after AEN
/// control-plane readback and an in-guest attester both match.
async fn[T : AenTransport] AenBackend::start_checked(
  self : AenBackend[T],
) -> @sandbox.SandboxReceipt {
  guard self.state is Created || self.state is Stopped else {
    raise self.refuse("AEN start requires Created or Stopped state")
  }
  let ttl_seconds = (self.profile.limits.wall_clock_ms + 999) / 1000
  let cold_body : Json = {
    "image": self.executor_image_ref,
    "timeout": ttl_seconds,
    "autoPause": false,
    "autoResume": { "enabled": false },
    "allowInternetAccess": self.profile.network is Unrestricted,
    "network": network_json(self.profile),
    "metadata": requested_metadata(self.profile, self.digest),
    "envVars": {},
    "cpuCount": self.expected_vcpu_count,
    "memoryMB": self.profile.limits.memory_mib,
    "diskSizeMB": self.expected_root_disk_mib,
    "attachedDrives": [
      {
        "driveID": "moonfort-workspace",
        "readOnly": true,
        "mountPath": self.guest_workspace,
        "source": { "image": self.workspace_lease.image_ref },
      },
    ],
  }
  let body : Json = if self.warm_snapshot_compat {
    {
      "templateID": self.executor_image_ref,
      "timeout": ttl_seconds,
      "autoPause": false,
      "autoResume": { "enabled": false },
      "secure": true,
      "allow_internet_access": self.profile.network is Unrestricted,
      "network": network_json(self.profile),
      "metadata": requested_metadata(self.profile, self.digest),
      "envVars": {},
    }
  } else {
    cold_body
  }
  // From this point until a sandbox ID is parsed, a transport interruption can
  // leave a provider-side VM that this client cannot address. Never claim
  // cleanup verification for that ambiguous interval.
  self.create_in_flight = true
  let response = self.transport.request(
    control_request(
      self.api_key,
      Post,
      if self.warm_snapshot_compat {
        "/sandboxes"
      } else {
        "/sandboxes-cold"
      },
      body~,
      timeout_ms=ControlTimeoutMs,
    ),
  )
  let created = response_json(response, 201) catch {
    _ => raise self.refuse("AEN create refused")
  }
  let id = required_string(json_object(created, "create"), "sandboxID") catch {
    _ => raise self.refuse("AEN create protocol failed")
  }
  self.sandbox_id = Some(id)
  guard safe_provider_identifier(id) else {
    raise self.refuse("AEN create returned an invalid sandbox ID")
  }
  let detail_response = self.transport.request(
    control_request(
      self.api_key,
      Get,
      "/sandboxes/\{url_segment(id)}",
      timeout_ms=ControlTimeoutMs,
    ),
  )
  let detail = response_json(detail_response, 200) catch {
    _ => raise self.refuse("AEN attestation refused")
  }
  self.verify_attestation(detail, id) catch {
    _ => raise self.refuse("AEN attestation mismatch")
  }
  if self.require_guest_attestation {
    self.verify_guest_attestation(id) catch {
      _ => raise self.refuse("AEN guest attestation mismatch")
    }
    self.verify_guest_ipv6_disabled(id) catch {
      _ => raise self.refuse("AEN guest IPv6 attestation mismatch")
    }
  }
  self.state = Running
  self.base_receipt(Running)
}

///|
/// Fail-closed start facade. Configuration errors are raised by `new`; any
/// runtime/control-plane/attestation failure becomes a refused receipt and a
/// sticky `Refused` state, never a local-process fallback.
pub async fn[T : AenTransport] AenBackend::start(
  self : AenBackend[T],
) -> @sandbox.SandboxReceipt {
  self.start_checked() catch {
    error => {
      let cleanup_verified = self.discard_protected()
      if @async.is_cancellation_error(error) {
        self.state = Refused
        raise error
      }
      self.refused_after_cleanup("AEN start failed", cleanup_verified)
    }
  }
}

///|
pub async fn[T : AenTransport] AenBackend::stop(
  self : AenBackend[T],
) -> @sandbox.SandboxReceipt {
  try {
    guard self.sandbox_id is Some(id) &&
      (self.state is Running || self.state is Paused) else {
      raise self.refuse("AEN stop requires a running or paused sandbox")
    }
    let response = self.transport.request(
      control_request(
        self.api_key,
        Delete,
        "/sandboxes/\{url_segment(id)}",
        timeout_ms=ControlTimeoutMs,
      ),
    )
    expect_status(response, 204)
    self.create_in_flight = false
    self.sandbox_id = None
    self.state = Stopped
    { ..self.base_receipt(Killed), cleanup_verified: true, retention_id: None }
  } catch {
    error => {
      self.raise_after_cleanup("stop", error)
      abort("unreachable after AEN stop failure")
    }
  }
}

///|
async fn[T : AenTransport] AenBackend::delete_known_id(
  self : AenBackend[T],
  id : String,
) -> Bool {
  let response = self.transport.request(
    control_request(
      self.api_key,
      Delete,
      "/sandboxes/\{url_segment(id)}",
      timeout_ms=ControlTimeoutMs,
    ),
  ) catch {
    _ => return false
  }
  response.status == 204 || response.status == 404
}

///|
/// Delete the backing VM regardless of the controller's current state. This
/// is the one-shot executor's final fail-closed cleanup path after protocol or
/// command refusal. `true` means deletion was verified or no VM existed.
async fn[T : AenTransport] AenBackend::discard_checked(
  self : AenBackend[T],
) -> Bool {
  let mut verified = true
  let remaining_children : Array[String] = []
  for child_id in self.pending_child_ids.copy() {
    if !self.delete_known_id(child_id) {
      verified = false
      remaining_children.push(child_id)
    }
  }
  self.pending_child_ids.clear()
  self.pending_child_ids.append(remaining_children)
  match self.sandbox_id {
    Some(id) =>
      if self.delete_known_id(id) {
        self.create_in_flight = false
        self.sandbox_id = None
      } else {
        verified = false
      }
    None =>
      if self.create_in_flight {
        // A create request may have reached AEN without returning a usable ID.
        // TTL remains the provider backstop, but deletion cannot be verified.
        verified = false
      }
  }
  if verified {
    self.state = Stopped
  }
  verified
}

///|
pub async fn[T : AenTransport] AenBackend::discard(
  self : AenBackend[T],
) -> Bool {
  @async.protect_from_cancel(() => self.discard_checked())
}

///|
async fn[T : AenTransport] AenBackend::pause_checked(
  self : AenBackend[T],
) -> @sandbox.SandboxReceipt {
  guard self.sandbox_id is Some(id) && self.state is Running else {
    raise self.refuse("AEN pause requires a running sandbox")
  }
  let response = self.transport.request(
    control_request(
      self.api_key,
      Post,
      "/sandboxes/\{url_segment(id)}/pause",
      timeout_ms=ControlTimeoutMs,
    ),
  )
  expect_status(response, 204) catch {
    _ => raise self.refuse("AEN pause refused")
  }
  self.state = Paused
  self.base_receipt(Running)
}

///|
pub async fn[T : AenTransport] AenBackend::pause(
  self : AenBackend[T],
) -> @sandbox.SandboxReceipt {
  self.pause_checked() catch {
    error => {
      self.raise_after_cleanup("pause", error)
      abort("unreachable after AEN pause failure")
    }
  }
}

///|
/// AEN marks the explicit resume endpoint deprecated, but it is the only
/// control-plane operation whose response can be followed by independent
/// detail attestation without opening an envd connection first.
async fn[T : AenTransport] AenBackend::resume_checked(
  self : AenBackend[T],
) -> @sandbox.SandboxReceipt {
  guard self.sandbox_id is Some(id) && self.state is Paused else {
    raise self.refuse("AEN resume requires a paused sandbox")
  }
  let ttl_seconds = (self.profile.limits.wall_clock_ms + 999) / 1000
  let response = self.transport.request(
    control_request(
      self.api_key,
      Post,
      "/sandboxes/\{url_segment(id)}/resume",
      body={ "timeout": ttl_seconds },
      timeout_ms=ControlTimeoutMs,
    ),
  )
  ignore(response_json(response, 201)) catch {
    _ => raise self.refuse("AEN resume refused")
  }
  let detail_response = self.transport.request(
    control_request(
      self.api_key,
      Get,
      "/sandboxes/\{url_segment(id)}",
      timeout_ms=ControlTimeoutMs,
    ),
  )
  let detail = response_json(detail_response, 200) catch {
    _ => raise self.refuse("AEN resume attestation refused")
  }
  self.verify_attestation(detail, id) catch {
    _ => raise self.refuse("AEN resume attestation mismatch")
  }
  if self.require_guest_attestation {
    self.verify_guest_attestation(id) catch {
      _ => raise self.refuse("AEN resume guest attestation mismatch")
    }
    self.verify_guest_ipv6_disabled(id) catch {
      _ => raise self.refuse("AEN resume guest IPv6 attestation mismatch")
    }
  }
  self.state = Running
  self.base_receipt(Running)
}

///|
pub async fn[T : AenTransport] AenBackend::resume_sandbox(
  self : AenBackend[T],
) -> @sandbox.SandboxReceipt {
  self.resume_checked() catch {
    error => {
      self.raise_after_cleanup("resume", error)
      abort("unreachable after AEN resume failure")
    }
  }
}

///|
/// Reset is delete plus a fresh start from the original read-only snapshot.
pub async fn[T : AenTransport] AenBackend::reset(
  self : AenBackend[T],
) -> @sandbox.SandboxReceipt {
  ignore(self.stop())
  self.start()
}

///|
async fn[T : AenTransport] AenBackend::snapshot_checked(
  self : AenBackend[T],
  name? : String,
) -> AenArtifactResult {
  guard self.sandbox_id is Some(id) && self.state is Running else {
    raise self.refuse("AEN snapshot requires a running sandbox")
  }
  let body : Json = match name {
    Some(value) => { "name": value }
    None => {}
  }
  let response = self.transport.request(
    control_request(
      self.api_key,
      Post,
      "/sandboxes/\{url_segment(id)}/snapshots",
      body~,
      timeout_ms=self.profile.limits.wall_clock_ms,
    ),
  )
  let object = json_object(response_json(response, 201), "snapshot") catch {
    _ => raise self.refuse("AEN snapshot refused")
  }
  let artifact = required_string(object, "snapshotID") catch {
    _ => raise self.refuse("AEN snapshot protocol failed")
  }
  guard safe_provider_identifier(artifact) else {
    raise self.refuse("AEN snapshot returned an invalid artifact ID")
  }
  let receipt = { ..self.base_receipt(Running), artifacts: [artifact] }
  { artifact_id: Some(artifact), receipt }
}

///|
pub async fn[T : AenTransport] AenBackend::snapshot(
  self : AenBackend[T],
  name? : String,
) -> AenArtifactResult {
  self.snapshot_checked(name?) catch {
    error => {
      self.raise_after_cleanup("snapshot", error)
      abort("unreachable after AEN snapshot failure")
    }
  }
}

///|
async fn[T : AenTransport] AenBackend::fork_checked(
  self : AenBackend[T],
  count : Int,
) -> AenForkResult {
  guard count >= 1 && count <= 16 else {
    raise InvalidConfiguration("AEN Firecracker fork count must be 1..16")
  }
  guard self.sandbox_id is Some(id) && self.state is Running else {
    raise self.refuse("AEN fork requires a running sandbox")
  }
  let ttl_seconds = (self.profile.limits.wall_clock_ms + 999) / 1000
  let response = self.transport.request(
    control_request(
      self.api_key,
      Post,
      "/sandboxes/\{url_segment(id)}/fork",
      body={ "count": count, "timeout": ttl_seconds },
      timeout_ms=self.profile.limits.wall_clock_ms,
    ),
  )
  let fork_json = response_json(response, 201) catch {
    _ => raise self.refuse("AEN fork refused")
  }
  let values = match fork_json {
    Array(values) => values
    _ => raise self.refuse("AEN fork response must be an array")
  }
  let ids : Array[String] = []
  for value in values {
    let item = json_object(value, "fork item") catch {
      _ => raise self.refuse("AEN fork protocol failed")
    }
    let child = match item.get("sandbox") {
      Some(Object(child)) => child
      _ => raise self.refuse("AEN fork returned a failed child")
    }
    let child_id = required_string(child, "sandboxID")
    ids.push(child_id)
    self.pending_child_ids.push(child_id)
    guard safe_provider_identifier(child_id) else {
      raise self.refuse("AEN fork returned an invalid child ID")
    }
  }
  guard ids.length() == count else {
    raise self.refuse("AEN fork returned the wrong child count")
  }
  for child_id in ids {
    let detail_response = self.transport.request(
      control_request(
        self.api_key,
        Get,
        "/sandboxes/\{url_segment(child_id)}",
        timeout_ms=ControlTimeoutMs,
      ),
    )
    let detail = response_json(detail_response, 200) catch {
      _ => raise self.refuse("AEN fork attestation refused")
    }
    self.verify_attestation(detail, child_id) catch {
      _ => raise self.refuse("AEN fork child attestation mismatch")
    }
    if self.require_guest_attestation {
      self.verify_guest_attestation(child_id) catch {
        _ => raise self.refuse("AEN fork child guest attestation mismatch")
      }
      self.verify_guest_ipv6_disabled(child_id) catch {
        _ => raise self.refuse("AEN fork child guest IPv6 attestation mismatch")
      }
    }
  }
  self.pending_child_ids.clear()
  {
    sandbox_ids: ids,
    receipt: { ..self.base_receipt(Running), artifacts: ids },
  }
}

///|
pub async fn[T : AenTransport] AenBackend::fork(
  self : AenBackend[T],
  count : Int,
) -> AenForkResult {
  self.fork_checked(count) catch {
    error => {
      self.raise_after_cleanup("fork", error)
      abort("unreachable after AEN fork failure")
    }
  }
}
