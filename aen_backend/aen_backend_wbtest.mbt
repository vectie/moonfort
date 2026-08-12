///|
struct FakeTransport {
  responses : Array[AenResponse]
  stream_chunks : Array[Bytes]
  requests : Array[AenRequest]
  mut response_index : Int
}

///|
fn FakeTransport::new(
  responses : Array[AenResponse],
  stream_chunks? : Array[Bytes] = [],
) -> FakeTransport {
  { responses, stream_chunks, requests: [], response_index: 0 }
}

///|
impl AenTransport for FakeTransport with fn request(self, request) {
  self.requests.push(request)
  guard self.response_index < self.responses.length() else {
    raise TransportFailure("fake transport response queue exhausted")
  }
  let response = self.responses[self.response_index]
  self.response_index += 1
  response
}

///|
impl AenTransport for FakeTransport with fn stream(self, request, consume~) {
  self.requests.push(request)
  for chunk in self.stream_chunks {
    if consume(chunk) is StopStream {
      return
    }
  }
}

///|
struct CancellationTransport {
  requests : Array[AenRequest]
}

///|
impl AenTransport for CancellationTransport with fn request(self, request) {
  self.requests.push(request)
  if request.verb is Post && request.path == "/sandboxes" {
    return json_response(201, { "sandboxID": "sbx-cancel" })
  }
  if request.verb is Get && request.path == "/sandboxes/sbx-cancel" {
    @async.sleep(60_000)
    return { status: 500, body: b"unreachable" }
  }
  if request.verb is Delete && request.path == "/sandboxes/sbx-cancel" {
    return { status: 204, body: b"" }
  }
  raise TransportFailure("unexpected cancellation-test request")
}

///|
impl AenTransport for CancellationTransport with fn stream(
  _self,
  _request,
  consume~,
) {
  ignore(consume)
  raise TransportFailure("cancellation transport does not stream")
}

///|
fn test_profile(output_bytes? : Int = 256) -> @sandbox.SandboxProfile {
  {
    run_id: "run-aen-1",
    workspace_root: "/canonical/book",
    scratch_root: "/isolated/scratch",
    backend: MicroVm,
    enforcement_requirement: RequireEnforced,
    network: Deny,
    read_only_roots: ["/canonical/book"],
    allowed_egress: [],
    allowed_commands: ["moon"],
    limits: {
      wall_clock_ms: 5_000,
      cpu_seconds: 2,
      memory_mib: 256,
      disk_mib: 512,
      processes: 64,
      output_bytes,
    },
    read_only_workspace: true,
  }
}

///|
fn json_response(status : Int, value : Json) -> AenResponse {
  { status, body: @utf8.encode(value.stringify()) }
}

///|
fn attested_detail(profile : @sandbox.SandboxProfile) -> Json {
  let digest = @sandbox.profile_digest(profile)
  {
    "sandboxID": "sbx-1",
    "templateID": "snapshot-1",
    "state": "running",
    "cpuCount": 2,
    "memoryMB": profile.limits.memory_mib,
    "diskSizeMB": profile.limits.disk_mib,
    "metadata": {
      "moonfort.enforced_profile_digest": digest,
      "moonfort.enforcement_contract": "moonfort-aen-v1",
      "moonfort.cpu_seconds": profile.limits.cpu_seconds.to_string(),
      "moonfort.read_only_source_snapshot": "snapshot-1",
      "moonfort.guest_workspace": "/workspace",
      "moonfort.guest_scratch": "/scratch",
      "moonfort.disk_limit_mib": profile.limits.disk_mib.to_string(),
      "moonfort.process_limit": profile.limits.processes.to_string(),
      "moonfort.output_limit_bytes": profile.limits.output_bytes.to_string(),
      "moonfort.tool_bindings_digest": tool_bindings_digest({
        "moon": "/opt/moon/bin/moon",
      }),
    },
    "network": {
      "allowPublicTraffic": false,
      "allowOut": [],
      "denyOut": ["0.0.0.0/0"],
    },
    "lifecycle": { "onTimeout": "kill" },
  }
}

///|
fn attested_detail_for(
  profile : @sandbox.SandboxProfile,
  sandbox_id : String,
) -> Json {
  let value = attested_detail(profile)
  match value {
    Object(object) => {
      object["sandboxID"] = sandbox_id.to_json()
      value
    }
    _ => abort("test fixture detail must be an object")
  }
}

///|
fn echoed_detail(profile : @sandbox.SandboxProfile) -> Json {
  let value = attested_detail(profile)
  match value {
    Object(object) => {
      object["metadata"] = {
        "moonfort.requested_profile_digest": @sandbox.profile_digest(profile),
        "moonfort.run_id": profile.run_id,
      }
      value
    }
    _ => abort("test fixture detail must be an object")
  }
}

///|
fn start_response_event(field : Int, body : Bytes) -> Bytes {
  let process_event = @buffer.Buffer()
  write_length_delimited(process_event, field, body)
  let response = @buffer.Buffer()
  write_length_delimited(response, 1, process_event.to_bytes())
  response.to_bytes()
}

///|
fn process_started(pid : Int) -> Bytes {
  let body = @buffer.Buffer()
  write_key(body, 1, 0)
  write_varint(body, pid)
  start_response_event(1, body.to_bytes())
}

///|
fn stdout_event(bytes : Bytes) -> Bytes {
  let body = @buffer.Buffer()
  write_length_delimited(body, 1, bytes)
  start_response_event(2, body.to_bytes())
}

///|
fn process_exited(code : Int) -> Bytes {
  let body = @buffer.Buffer()
  write_key(body, 1, 0)
  write_varint(body, (code << 1) ^ (code >> 31))
  write_key(body, 2, 0)
  write_varint(body, 1)
  write_string_field(body, 3, "exited")
  start_response_event(3, body.to_bytes())
}

///|
fn exec_stream(output : Bytes, code : Int) -> Array[Bytes] {
  [
    connect_envelope(0, process_started(42)),
    connect_envelope(0, stdout_event(output)),
    connect_envelope(0, process_exited(code)),
    connect_envelope(2, b"{}"),
  ]
}

///|
fn test_workspace_lease(
  profile : @sandbox.SandboxProfile,
  receipt_key : String,
) -> AenWorkspaceLease {
  let unsigned : AenWorkspaceLease = {
    protocol_version: ProvisionerProtocolVersion,
    lease_id: "lease-1",
    run_id: profile.run_id,
    workspace_id: "workspace-main",
    profile_digest: @sandbox.profile_digest(profile),
    workspace_digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    image_ref: "registry.test/workspace@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    entry_count: 3,
    total_bytes: 42L,
    staging_cleanup_verified: true,
    receipt_key_id: "test-key-1",
    receipt_mac: "",
  }
  {
    ..unsigned,
    receipt_mac: receipt_mac(receipt_key, provisioner_receipt_payload(unsigned)),
  }
}

///|
async test "trusted provisioner request uses workspace identity and verifies its MAC" {
  let profile = test_profile()
  let key = "0123456789abcdef0123456789abcdef"
  let lease = test_workspace_lease(profile, key)
  let transport = FakeTransport::new([json_response(201, lease.to_json())])
  let actual = provision_workspace(
    transport,
    api_key="secret",
    receipt_key=key,
    receipt_key_id="test-key-1",
    registry_repository="registry.test/workspace",
    workspace_id="workspace-main",
    max_workspace_bytes=1024L,
    profile~,
  )
  assert_eq(actual.workspace_digest, lease.workspace_digest)
  guard transport.requests[0].body is JsonBody(Object(body)) else {
    fail("provision request must be JSON")
  }
  assert_eq(body.get("workspaceID"), Some("workspace-main".to_json()))
  assert_eq(body.get("runID"), Some(profile.run_id.to_json()))
  assert_false(body.contains("workspaceRoot"))
  assert_eq(body.get("rejectSymlinks"), Some(true.to_json()))
}

///|
async test "workspace lease release is bounded and idempotent" {
  let transport = FakeTransport::new([{ status: 404, body: b"" }])
  assert_true(
    release_workspace(transport, api_key="secret", lease_id="lease-1"),
  )
  assert_eq(transport.requests[0].verb, Delete)
  assert_eq(transport.requests[0].path, "/v1/workspaces/lease-1")
  assert_eq(transport.requests[0].timeout_ms, ControlTimeoutMs)
}

///|
test "workspace lease rejects tampering and mutable image references" {
  let profile = test_profile()
  let key = "0123456789abcdef0123456789abcdef"
  let lease = test_workspace_lease(profile, key)
  try
    validate_workspace_lease(
      { ..lease, total_bytes: 43L },
      key,
      "test-key-1",
      "registry.test/workspace",
      "workspace-main",
      profile,
      1024L,
    )
  catch {
    ProtocolFailure(_) => ()
    error => fail("unexpected tamper error: \{Repr(error)}")
  } noraise {
    _ => fail("tampered lease unexpectedly verified")
  }
  try
    validate_workspace_lease(
      { ..lease, image_ref: "registry.test/workspace:latest" },
      key,
      "test-key-1",
      "registry.test/workspace",
      "workspace-main",
      profile,
      1024L,
    )
  catch {
    ProtocolFailure(_) => ()
    error => fail("unexpected mutable-ref error: \{Repr(error)}")
  } noraise {
    _ => fail("mutable image reference unexpectedly verified")
  }
  try
    validate_workspace_lease(
      lease, key, "test-key-1", "registry.test/other-workspace", "workspace-main",
      profile, 1024L,
    )
  catch {
    ProtocolFailure(_) => ()
    error => fail("unexpected repository-pin error: \{Repr(error)}")
  } noraise {
    _ => fail("lease from substituted repository unexpectedly verified")
  }
  try
    validate_workspace_lease(
      lease, key, "retired-key", "registry.test/workspace", "workspace-main", profile,
      1024L,
    )
  catch {
    ProtocolFailure(_) => ()
    error => fail("unexpected key-ID error: \{Repr(error)}")
  } noraise {
    _ => fail("mismatched receipt key ID unexpectedly verified")
  }
}

///|
async test "stock AEN cold start attaches the provisioned workspace read-only and guest-attests" {
  let profile = test_profile()
  let key = "0123456789abcdef0123456789abcdef"
  let lease = test_workspace_lease(profile, key)
  let executor_image = "registry.test/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let detail : Json = {
    "sandboxID": "sbx-strong",
    "templateID": executor_image,
    "state": "running",
    "cpuCount": 2,
    "memoryMB": profile.limits.memory_mib,
    "diskSizeMB": 1024,
    "metadata": {},
    "network": {
      "allowPublicTraffic": false,
      "allowOut": [],
      "denyOut": ["0.0.0.0/0"],
    },
    "lifecycle": { "onTimeout": "kill" },
  }
  let guest : Json = {
    "contract": GuestAttestationContract,
    "profileDigest": @sandbox.profile_digest(profile),
    "executorRootDigest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "guestAttesterDigest": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "guestSupervisorDigest": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "workspaceDigest": lease.workspace_digest,
    "workspacePath": "/workspace",
    "workspaceReadOnly": true,
    "scratchPath": "/scratch",
    "scratchWritable": true,
    "scratchIsolated": true,
    "scratchOverlay": true,
    "scratchLowerDigest": lease.workspace_digest,
    "scratchBaselineDigest": lease.workspace_digest,
    "scratchBaselineEntries": lease.entry_count,
    "scratchBaselineBytes": lease.total_bytes.to_string(),
    "toolRegistryDigest": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "supervisorPath": "/opt/moonfort/bin/supervisor",
    "cpuSeconds": profile.limits.cpu_seconds,
    "processLimit": profile.limits.processes,
    "scratchDiskMiB": profile.limits.disk_mib,
  }
  let transport = FakeTransport::new(
    [
      json_response(201, { "sandboxID": "sbx-strong" }),
      json_response(200, detail),
      { status: 204, body: b"" },
    ],
    stream_chunks=exec_stream(@utf8.encode(guest.stringify()), 0),
  )
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    executor_image_ref=executor_image,
    workspace_lease=lease,
    expected_vcpu_count=2,
    expected_root_disk_mib=1024,
    guest_attester="/opt/moonfort/bin/attester",
    guest_supervisor="/opt/moonfort/bin/supervisor",
    require_guest_attestation=true,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  let receipt = backend.start()
  assert_eq(receipt.enforcement, Enforced)
  assert_eq(transport.requests[0].path, "/sandboxes-cold")
  guard transport.requests[0].body is JsonBody(Object(body)) else {
    fail("cold start must use JSON")
  }
  assert_eq(body.get("image"), Some(executor_image.to_json()))
  guard body.get("attachedDrives") is Some(Array([Object(drive)])) else {
    fail("cold start must attach exactly one workspace drive")
  }
  assert_eq(drive.get("readOnly"), Some(true.to_json()))
  assert_eq(drive.get("mountPath"), Some("/workspace".to_json()))
  assert_true(backend.discard())
}

///|
async test "guest attestation mismatch deletes the cold-start VM" {
  let profile = test_profile()
  let key = "0123456789abcdef0123456789abcdef"
  let lease = test_workspace_lease(profile, key)
  let executor_image = "registry.test/executor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let detail : Json = {
    "sandboxID": "sbx-mismatch",
    "templateID": executor_image,
    "state": "running",
    "cpuCount": 2,
    "memoryMB": profile.limits.memory_mib,
    "diskSizeMB": 1024,
    "metadata": {},
    "network": {
      "allowPublicTraffic": true,
      "allowOut": [],
      "denyOut": ["0.0.0.0/0"],
    },
    "lifecycle": { "onTimeout": "kill" },
  }
  let guest : Json = {
    "contract": GuestAttestationContract,
    "profileDigest": @sandbox.profile_digest(profile),
    "executorRootDigest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "guestAttesterDigest": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    "guestSupervisorDigest": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "workspaceDigest": lease.workspace_digest,
    "workspacePath": "/workspace",
    "workspaceReadOnly": false,
    "scratchPath": "/scratch",
    "scratchWritable": true,
    "scratchIsolated": true,
    "scratchOverlay": true,
    "scratchLowerDigest": lease.workspace_digest,
    "scratchBaselineDigest": lease.workspace_digest,
    "scratchBaselineEntries": lease.entry_count,
    "scratchBaselineBytes": lease.total_bytes.to_string(),
    "toolRegistryDigest": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "supervisorPath": "/opt/moonfort/bin/supervisor",
    "cpuSeconds": profile.limits.cpu_seconds,
    "processLimit": profile.limits.processes,
    "scratchDiskMiB": profile.limits.disk_mib,
  }
  let transport = FakeTransport::new(
    [
      json_response(201, { "sandboxID": "sbx-mismatch" }),
      json_response(200, detail),
      { status: 204, body: b"" },
    ],
    stream_chunks=exec_stream(@utf8.encode(guest.stringify()), 0),
  )
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    executor_image_ref=executor_image,
    workspace_lease=lease,
    expected_vcpu_count=2,
    expected_root_disk_mib=1024,
    guest_attester="/opt/moonfort/bin/attester",
    guest_supervisor="/opt/moonfort/bin/supervisor",
    require_guest_attestation=true,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  let receipt = backend.start()
  assert_eq(receipt.enforcement, Refused)
  assert_true(receipt.cleanup_verified)
  assert_eq(transport.requests[3].verb, Delete)
}

///|
fn watcher_created(id : String) -> AenResponse {
  let body = @buffer.Buffer()
  write_string_field(body, 1, id)
  { status: 200, body: body.to_bytes() }
}

///|
fn watcher_events(paths : Array[String]) -> AenResponse {
  let body = @buffer.Buffer()
  for path in paths {
    let event = @buffer.Buffer()
    write_string_field(event, 1, path)
    write_key(event, 2, 0)
    write_varint(event, 2)
    write_length_delimited(body, 1, event.to_bytes())
  }
  { status: 200, body: body.to_bytes() }
}

///|
async test "attested AEN start and envd exec keep the live lifecycle non-terminal" {
  let profile = test_profile()
  let transport = FakeTransport::new(
    [
      json_response(201, { "sandboxID": "sbx-1" }),
      json_response(200, attested_detail(profile)),
      watcher_created("watcher-1"),
      watcher_events(["result.txt"]),
      { status: 200, body: b"" },
    ],
    stream_chunks=exec_stream(b"ok\n", 0),
  )
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  let started = backend.start()
  assert_eq(started.enforcement, Enforced)
  let prepared = @sandbox.prepare_sandbox_command(
      profile,
      Exec(tool="moon", args=["version"]),
      BackendEnforced,
    )
    .prepared()
    .unwrap()
  let receipt = backend.exec(prepared, working_directory="packages/app")
  assert_eq(receipt.status, Running)
  assert_eq(receipt.exit_code, Some(0))
  assert_eq(receipt.output, "ok\n")
  assert_eq(receipt.changed_paths, ["result.txt"])
  assert_eq(transport.requests[3].path, "/process.Process/Start")
  guard transport.requests[3].body is ConnectBody(body) else {
    fail("AEN exec must send a Connect request")
  }
  assert_true(@utf8.decode_lossy(body).contains("/scratch/packages/app"))
}

///|
async test "caller-echoed metadata cannot upgrade standard AEN to Enforced" {
  let profile = test_profile()
  let transport = FakeTransport::new([
    json_response(201, { "sandboxID": "sbx-1" }),
    json_response(200, echoed_detail(profile)),
    { status: 204, body: b"" },
  ])
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  let receipt = backend.start()
  assert_eq(receipt.enforcement, Refused)
  assert_eq(backend.state(), Refused)
  assert_eq(transport.requests[2].verb, Delete)
}

///|
async test "output limit closes stream, sends SIGKILL, and returns killed receipt" {
  let profile = test_profile(output_bytes=3)
  let transport = FakeTransport::new(
    [
      json_response(201, { "sandboxID": "sbx-1" }),
      json_response(200, attested_detail(profile)),
      watcher_created("watcher-1"),
      { status: 200, body: b"" },
      watcher_events([]),
      { status: 200, body: b"" },
      { status: 204, body: b"" },
    ],
    stream_chunks=exec_stream(b"abcdef", 0),
  )
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  ignore(backend.start())
  let prepared = @sandbox.prepare_sandbox_command(
      profile,
      Exec(tool="moon", args=[]),
      BackendEnforced,
    )
    .prepared()
    .unwrap()
  let receipt = backend.exec(prepared)
  assert_eq(receipt.status, Killed)
  assert_eq(receipt.output, "abc")
  assert_true(receipt.output_truncated)
  assert_eq(receipt.limit_reason, Some("output_bytes"))
  assert_eq(transport.requests[4].path, "/process.Process/SendSignal")
  assert_eq(transport.requests[7].path, "/sandboxes/sbx-1")
}

///|
async test "pause and deprecated explicit resume re-attest before Running" {
  let profile = test_profile()
  let transport = FakeTransport::new([
    json_response(201, { "sandboxID": "sbx-1" }),
    json_response(200, attested_detail(profile)),
    { status: 204, body: b"" },
    json_response(201, { "sandboxID": "sbx-1" }),
    json_response(200, attested_detail(profile)),
  ])
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  ignore(backend.start())
  ignore(backend.pause())
  assert_eq(backend.state(), Paused)
  let resumed = backend.resume_sandbox()
  assert_eq(resumed.enforcement, Enforced)
  assert_eq(backend.state(), Running)
  assert_eq(transport.requests[2].path, "/sandboxes/sbx-1/pause")
  assert_eq(transport.requests[3].path, "/sandboxes/sbx-1/resume")
  assert_eq(transport.requests[4].path, "/sandboxes/sbx-1")
}

///|
test "Connect decoder rejects an oversized frame before buffering its body" {
  let decoder = ConnectDecoder::new(max_frame_bytes=4)
  let message = try {
    ignore(decoder.feed(b"\x00\x00\x00\x00\x05"))
    ""
  } catch {
    error => "\{Repr(error)}"
  }
  assert_eq(
    message, "ProtocolFailure(\"Connect frame exceeded the configured limit\")",
  )
}

///|
test "AEN working directory accepts only normalized relative paths" {
  assert_true(safe_guest_working_directory(""))
  assert_true(safe_guest_working_directory("packages/app"))
  assert_false(safe_guest_working_directory("/packages/app"))
  assert_false(safe_guest_working_directory("packages/../outside"))
  assert_false(safe_guest_working_directory("packages//app"))
  assert_false(safe_guest_working_directory("packages/app/"))
}

///|
async test "one-shot AEN facade refuses invalid configuration without fallback" {
  let profile = test_profile()
  let config : AenExecutionConfig = {
    base_url: "file:///not-an-aen-origin",
    api_key: "secret",
    executor_image_ref: "registry.test/moonfort@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    expected_vcpu_count: 2,
    expected_root_disk_mib: 1024,
    provisioner_url: "file:///not-a-provisioner-origin",
    provisioner_api_key: "provisioner-secret",
    provisioner_receipt_key: "0123456789abcdef0123456789abcdef",
    provisioner_key_id: "test-key-1",
    workspace_registry_repository: "registry.test/workspace",
    workspace_id: "workspace-test",
    max_workspace_bytes: 1_048_576L,
    guest_workspace: "/workspace",
    guest_scratch: "/scratch",
    guest_attester: "/opt/moonfort/bin/attester",
    guest_supervisor: "/opt/moonfort/bin/supervisor",
    executor_root_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    guest_attester_digest: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    guest_supervisor_digest: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    tool_registry_digest: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    guest_tools: { "moon": "/opt/moon/bin/moon" },
  }
  let receipt = execute_aen_sandbox(
    profile,
    Exec(tool="moon", args=["version"]),
    config,
  )
  assert_eq(receipt.enforcement, Refused)
  assert_true(
    receipt.denial_reason is Some(reason) &&
    reason.contains("invalid AEN provisioner configuration"),
  )
  assert_true(
    receipt.denial_reason is Some(reason) && !reason.contains("secret"),
  )
}

///|
async test "start failure after receiving a sandbox ID verifies VM deletion" {
  let profile = test_profile()
  let transport = FakeTransport::new([
    json_response(201, { "sandboxID": "sbx-1" }),
    { status: 503, body: b"remote-secret-body" },
    { status: 204, body: b"" },
  ])
  let backend = AenBackend::new(
    transport,
    api_key="test-key-secret",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  let receipt = backend.start()
  assert_eq(receipt.enforcement, Refused)
  assert_true(receipt.cleanup_verified)
  assert_eq(receipt.retention_id, None)
  assert_eq(backend.sandbox_id(), None)
  assert_eq(transport.requests[2].verb, Delete)
  assert_true(
    receipt.denial_reason is Some(reason) &&
    !reason.contains("remote-secret-body") &&
    !reason.contains("test-key-secret"),
  )
}

///|
async test "failed create without a sandbox ID never claims cleanup verified" {
  let profile = test_profile()
  let transport = FakeTransport::new([
    { status: 503, body: b"provider-detail-must-not-reflect" },
  ])
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  let receipt = backend.start()
  assert_eq(receipt.enforcement, Refused)
  assert_false(receipt.cleanup_verified)
  assert_eq(receipt.retention_id, None)
  assert_eq(transport.requests.length(), 1)
  assert_true(
    receipt.denial_reason is Some(reason) &&
    !reason.contains("provider-detail-must-not-reflect"),
  )
}

///|
async test "unverified start cleanup returns an explicit retained VM ID" {
  let profile = test_profile()
  let transport = FakeTransport::new([
    json_response(201, { "sandboxID": "sbx-1" }),
    { status: 503, body: b"" },
    { status: 500, body: b"" },
  ])
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  let receipt = backend.start()
  assert_eq(receipt.enforcement, Refused)
  assert_false(receipt.cleanup_verified)
  assert_eq(receipt.retention_id, Some("aen-vms:sbx-1"))
  assert_eq(backend.sandbox_id(), Some("sbx-1"))
}

///|
async test "cancellation during post-create attestation waits for VM deletion" {
  let profile = test_profile()
  let transport : CancellationTransport = { requests: [] }
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  @async.with_task_group(group => {
    let task = group.spawn(allow_failure=true, () => backend.start())
    for attempts = 0; transport.requests.length() < 2 && attempts < 100; {
      @async.sleep(1)
      continue attempts + 1
    }
    assert_true(transport.requests.length() >= 2)
    task.cancel()
    try ignore(task.wait()) catch {
      error => assert_true(@async.is_cancellation_error(error))
    } noraise {
      _ => fail("cancelled AEN start unexpectedly completed")
    }
  })
  assert_eq(transport.requests.length(), 3)
  assert_eq(transport.requests[2].verb, Delete)
  assert_eq(backend.sandbox_id(), None)
}

///|
async test "watcher setup refusal deletes the already-attested VM" {
  let profile = test_profile()
  let transport = FakeTransport::new([
    json_response(201, { "sandboxID": "sbx-1" }),
    json_response(200, attested_detail(profile)),
    { status: 500, body: b"" },
    { status: 204, body: b"" },
  ])
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  ignore(backend.start())
  let prepared = @sandbox.prepare_sandbox_command(
      profile,
      Exec(tool="moon", args=[]),
      BackendEnforced,
    )
    .prepared()
    .unwrap()
  let receipt = backend.exec(prepared)
  assert_eq(receipt.enforcement, Refused)
  assert_true(receipt.cleanup_verified)
  assert_eq(transport.requests[3].verb, Delete)
}

///|
async test "terminal diff failure deletes the VM and cannot return Enforced" {
  let profile = test_profile()
  let transport = FakeTransport::new(
    [
      json_response(201, { "sandboxID": "sbx-1" }),
      json_response(200, attested_detail(profile)),
      watcher_created("watcher-1"),
      { status: 500, body: b"" },
      { status: 204, body: b"" },
    ],
    stream_chunks=exec_stream(b"ok", 0),
  )
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  ignore(backend.start())
  let prepared = @sandbox.prepare_sandbox_command(
      profile,
      Exec(tool="moon", args=[]),
      BackendEnforced,
    )
    .prepared()
    .unwrap()
  let receipt = backend.exec(prepared)
  assert_eq(receipt.enforcement, Refused)
  assert_true(receipt.cleanup_verified)
  assert_eq(transport.requests[5].verb, Delete)
}

///|
async test "resume attestation failure deletes the VM" {
  let profile = test_profile()
  let transport = FakeTransport::new([
    json_response(201, { "sandboxID": "sbx-1" }),
    json_response(200, attested_detail(profile)),
    { status: 204, body: b"" },
    json_response(201, { "sandboxID": "sbx-1" }),
    json_response(200, echoed_detail(profile)),
    { status: 204, body: b"" },
  ])
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  ignore(backend.start())
  ignore(backend.pause())
  try ignore(backend.resume_sandbox()) catch {
    error => assert_true("\{Repr(error)}".contains("VM cleanup verified"))
  } noraise {
    _ => fail("resume with invalid attestation unexpectedly succeeded")
  }
  assert_eq(transport.requests[5].verb, Delete)
  assert_eq(backend.sandbox_id(), None)
}

///|
async test "fork child attestation failure deletes every child and parent VM" {
  let profile = test_profile()
  let transport = FakeTransport::new([
    json_response(201, { "sandboxID": "sbx-1" }),
    json_response(200, attested_detail(profile)),
    json_response(201, [
      { "sandbox": { "sandboxID": "child-1" } },
      { "sandbox": { "sandboxID": "child-2" } },
    ]),
    json_response(200, attested_detail_for(profile, "child-1")),
    json_response(200, echoed_detail(profile)),
    { status: 204, body: b"" },
    { status: 204, body: b"" },
    { status: 204, body: b"" },
  ])
  let backend = AenBackend::new(
    transport,
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  ignore(backend.start())
  try ignore(backend.fork(2)) catch {
    error => assert_true("\{Repr(error)}".contains("VM cleanup verified"))
  } noraise {
    _ => fail("fork with invalid child attestation unexpectedly succeeded")
  }
  assert_eq(transport.requests[5].path, "/sandboxes/child-1")
  assert_eq(transport.requests[6].path, "/sandboxes/child-2")
  assert_eq(transport.requests[7].path, "/sandboxes/sbx-1")
  assert_eq(backend.sandbox_id(), None)
}

///|
test "guest workspace, scratch, and capability bindings remain disjoint" {
  let profile = test_profile()
  for scratch in ["/workspace", "/workspace/nested", "/"] {
    assert_true(
      try {
        ignore(
          AenBackend::new(
            FakeTransport::new([]),
            api_key="test-key",
            snapshot_id="snapshot-1",
            expected_vcpu_count=2,
            guest_scratch=scratch,
            guest_tools={ "moon": "/opt/moon/bin/moon" },
            profile~,
          ),
        )
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "changed paths are backend-neutral and reject unsafe watcher paths" {
  let profile = test_profile()
  let backend = AenBackend::new(
    FakeTransport::new([]),
    api_key="test-key",
    snapshot_id="snapshot-1",
    expected_vcpu_count=2,
    guest_tools={ "moon": "/opt/moon/bin/moon" },
    profile~,
  )
  assert_eq(backend.canonical_changed_path("/scratch/a/b.txt"), "a/b.txt")
  assert_eq(backend.canonical_changed_path("a/b.txt"), "a/b.txt")
  for candidate in ["", "/scratch", "../escape", "a\\b", "/other/file"] {
    assert_true(
      try {
        ignore(backend.canonical_changed_path(candidate))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "reserved fixed-supervisor exits map only to trusted limit reasons" {
  assert_eq(trusted_guest_limit_reason(201), Some("output_bytes"))
  assert_eq(trusted_guest_limit_reason(202), Some("wall_clock_ms"))
  assert_eq(trusted_guest_limit_reason(203), Some("cpu_seconds"))
  assert_eq(trusted_guest_limit_reason(204), Some("disk_mib"))
  assert_eq(trusted_guest_limit_reason(205), Some("processes"))
  assert_eq(trusted_guest_limit_reason(137), None)
  assert_eq(trusted_guest_limit_reason(200), None)
  assert_eq(trusted_guest_limit_reason(206), None)
}
