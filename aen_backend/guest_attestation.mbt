///|
const GuestAttestationContract : String = "moonfort-guest-v1"

///|
async fn[T : AenTransport] AenBackend::run_fixed_guest_json(
  self : AenBackend[T],
  sandbox_id : String,
  executable : String,
  arguments : Array[String],
  cwd : String,
  max_bytes? : Int = 65_536,
) -> Json {
  guard max_bytes > 0 && max_bytes <= 4_194_304 else {
    raise InvalidConfiguration("fixed guest output limit is invalid")
  }
  let decoder = ConnectDecoder::new(max_frame_bytes=max_bytes + 65_536)
  let output = @buffer.Buffer(size_hint=8_192)
  let mut pid : Int? = None
  let mut exit_code : Int? = None
  let mut connect_error = false
  let request = envd_start_request(
    self.api_key,
    sandbox_id,
    encode_start_request(executable, arguments, cwd),
    ControlTimeoutMs,
    max_bytes + 131_072,
  )
  self.transport.stream(request, consume=chunk => {
    let events = decoder.feed(chunk) catch {
      _ => {
        connect_error = true
        return StopStream
      }
    }
    for event in events {
      match event {
        ProcessStarted(value) => pid = Some(value)
        Stdout(bytes) => {
          if output.length() + bytes.length() > max_bytes {
            connect_error = true
            return StopStream
          }
          output.write_bytes(bytes)
        }
        Stderr(_) => {
          connect_error = true
          return StopStream
        }
        ProcessExited(code, _) => exit_code = Some(code)
        ConnectEnded(error) => {
          connect_error = error is Some(_)
          return StopStream
        }
      }
    }
    ContinueStream
  }) catch {
    error => {
      ignore(self.signal_process(pid))
      raise TransportFailure("AEN fixed guest process failed: \{error}")
    }
  }
  guard !connect_error && decoder.ended() && exit_code == Some(0) else {
    ignore(self.signal_process(pid))
    raise ProtocolFailure("AEN fixed guest process did not exit cleanly")
  }
  @json.parse(@utf8.decode(output.to_bytes())) catch {
    _ => raise ProtocolFailure("AEN fixed guest process returned invalid JSON")
  }
}

///|
fn required_bool(
  object : Map[String, Json],
  key : String,
) -> Bool raise AenBackendError {
  match object.get(key) {
    Some(True) => true
    Some(False) => false
    _ => raise ProtocolFailure("guest attestation is missing boolean \{key}")
  }
}

///|
/// Verify the mounted workspace, tool image, scratch topology, and guest
/// supervisor policy from inside the VM. This is not caller metadata: the
/// executable is part of the immutable executor OCI image whose digest AEN
/// independently returns in `templateID`.
async fn[T : AenTransport] AenBackend::verify_guest_attestation(
  self : AenBackend[T],
  sandbox_id : String,
) -> Unit {
  let detail = self.run_fixed_guest_json(
    sandbox_id,
    self.guest_attester,
    [
      "prepare-and-attest",
      "--contract",
      GuestAttestationContract,
      "--workspace",
      self.guest_workspace,
      "--workspace-digest",
      self.workspace_lease.workspace_digest,
      "--scratch",
      self.guest_scratch,
      "--profile-digest",
      self.digest,
      "--tool-bindings-digest",
      tool_bindings_digest(self.guest_tools),
      "--supervisor",
      self.guest_supervisor,
      "--executor-root-digest",
      self.executor_root_digest,
      "--attester-digest",
      self.guest_attester_digest,
      "--supervisor-digest",
      self.guest_supervisor_digest,
      "--tool-registry-digest",
      self.tool_registry_digest,
      "--cpu-seconds",
      self.profile.limits.cpu_seconds.to_string(),
      "--process-limit",
      self.profile.limits.processes.to_string(),
      "--scratch-disk-mib",
      self.profile.limits.disk_mib.to_string(),
    ],
    "/",
  )
  let object = json_object(detail, "guest attestation")
  guard required_string(object, "contract") == GuestAttestationContract &&
    required_string(object, "profileDigest") == self.digest &&
    required_string(object, "executorRootDigest") == self.executor_root_digest &&
    required_string(object, "guestAttesterDigest") == self.guest_attester_digest &&
    required_string(object, "guestSupervisorDigest") ==
    self.guest_supervisor_digest &&
    required_string(object, "workspaceDigest") ==
    self.workspace_lease.workspace_digest &&
    required_string(object, "workspacePath") == self.guest_workspace &&
    required_bool(object, "workspaceReadOnly") &&
    required_string(object, "scratchPath") == self.guest_scratch &&
    required_bool(object, "scratchWritable") &&
    required_bool(object, "scratchIsolated") &&
    required_bool(object, "scratchOverlay") &&
    required_string(object, "scratchLowerDigest") ==
    self.workspace_lease.workspace_digest &&
    required_string(object, "scratchBaselineDigest") ==
    self.workspace_lease.workspace_digest &&
    required_int(object, "scratchBaselineEntries") ==
    self.workspace_lease.entry_count &&
    required_string(object, "scratchBaselineBytes") ==
    self.workspace_lease.total_bytes.to_string() &&
    required_string(object, "toolRegistryDigest") == self.tool_registry_digest &&
    required_string(object, "supervisorPath") == self.guest_supervisor &&
    required_int(object, "cpuSeconds") == self.profile.limits.cpu_seconds &&
    required_int(object, "processLimit") == self.profile.limits.processes &&
    required_int(object, "scratchDiskMiB") == self.profile.limits.disk_mib else {
    raise ProtocolFailure("AEN guest attestation does not match the profile")
  }
}

///|
/// Obtain a bounded, content-hashed final scratch inventory from the immutable
/// guest helper. The writable overlay starts from the read-only workspace
/// lower layer, so the helper reports only upper-layer changes.
async fn[T : AenTransport] AenBackend::inventory_guest_changes(
  self : AenBackend[T],
  sandbox_id : String,
) -> @sandbox.ScratchDiff {
  let detail = self.run_fixed_guest_json(
    sandbox_id,
    self.guest_attester,
    [
      "inventory",
      "--contract",
      GuestAttestationContract,
      "--scratch",
      self.guest_scratch,
      "--profile-digest",
      self.digest,
      "--disk-mib",
      self.profile.limits.disk_mib.to_string(),
      "--max-entries",
      "4096",
      "--baseline-bytes",
      self.workspace_lease.total_bytes.max(1L).to_string(),
      "--baseline-entries",
      self.workspace_lease.entry_count.max(1).to_string(),
    ],
    "/",
    max_bytes=4_194_304,
  )
  let object = json_object(detail, "guest inventory")
  guard required_string(object, "contract") == GuestAttestationContract &&
    required_string(object, "profileDigest") == self.digest else {
    raise ProtocolFailure("guest inventory is not bound to this profile")
  }
  let baseline_json = match object.get("baseline") {
    Some(value) => value
    None => raise ProtocolFailure("guest inventory omitted baseline")
  }
  let inventory_json = match object.get("inventory") {
    Some(value) => value
    None => raise ProtocolFailure("guest inventory omitted inventory")
  }
  let baseline : @sandbox.ScratchInventory = @json.from_json(baseline_json) catch {
    _ => raise ProtocolFailure("guest baseline inventory is malformed")
  }
  let inventory : @sandbox.ScratchInventory = @json.from_json(inventory_json) catch {
    _ => raise ProtocolFailure("guest inventory is malformed")
  }
  guard baseline.entries.length() == self.workspace_lease.entry_count &&
    inventory.entries.length() <= 4_096 &&
    baseline.total_bytes == self.workspace_lease.total_bytes &&
    inventory.total_bytes <=
    self.profile.limits.disk_mib.to_int64() * 1_048_576L else {
    raise ProtocolFailure("guest inventory exceeds the profile bound")
  }
  for entry in [..baseline.entries, ..inventory.entries] {
    guard @sandbox.scratch_relative_path_is_safe(entry.relative_path) &&
      entry.size_bytes >= 0L &&
      entry.fingerprint.length() <= 256 else {
      raise ProtocolFailure("guest inventory contains an unsafe entry")
    }
  }
  @sandbox.diff_scratch(baseline, inventory)
}
