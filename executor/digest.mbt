///|
fn sorted_map_entries(values : Map[String, String]) -> Array[Json] {
  let keys = values.keys().collect()
  keys.sort()
  [
    for key in keys => { "label": key, "path": values[key] }
  ]
}

///|
fn grant_digest(grant : ExecutionGrant) -> String {
  let allowed_egress = grant.allowed_egress.copy()
  let allowed_commands = grant.allowed_commands.copy()
  allowed_egress.sort()
  allowed_commands.sort()
  let canonical = { ..grant, allowed_egress, allowed_commands }
  @crypto.bytes_to_hex_string(
    @crypto.sha256(@utf8.encode(canonical.to_json().stringify())),
  )
}

///|
fn command_digest(
  grant : ExecutionGrant,
  profile : @sandbox.SandboxProfile,
  local_tools : Map[String, String],
  backend_config_id : String,
  backend_binding_digest : String,
) -> String {
  let manifest : Json = {
    "approval_id": grant.approval_id,
    "request_id": grant.request_id,
    "profile_digest": @sandbox.profile_digest(profile),
    "working_directory": grant.working_directory,
    "command": grant.command,
    "local_tools": sorted_map_entries(local_tools),
    "backend_config_id": backend_config_id,
    "backend_binding_digest": backend_binding_digest,
  }
  @crypto.bytes_to_hex_string(
    @crypto.sha256(@utf8.encode(manifest.stringify())),
  )
}

///|
fn trusted_aen_binding_digest(config : TrustedAenConfig) -> String {
  let manifest : Json = {
    "base_url": config.base_url,
    "executor_image_ref": config.executor_image_ref,
    "expected_vcpu_count": config.expected_vcpu_count,
    "expected_root_disk_mib": config.expected_root_disk_mib,
    "provisioner_url": config.provisioner_url,
    "provisioner_key_id": config.provisioner_key_id,
    "workspace_registry_repository": config.workspace_registry_repository,
    "max_workspace_bytes": config.max_workspace_bytes,
    "guest_workspace": config.guest_workspace,
    "guest_scratch": config.guest_scratch,
    "guest_attester": config.guest_attester,
    "guest_supervisor": config.guest_supervisor,
    "executor_root_digest": config.executor_root_digest,
    "guest_attester_digest": config.guest_attester_digest,
    "guest_supervisor_digest": config.guest_supervisor_digest,
    "tool_registry_digest": config.tool_registry_digest,
    "guest_tools": sorted_map_entries(config.guest_tools),
  }
  @crypto.bytes_to_hex_string(
    @crypto.sha256(@utf8.encode(manifest.stringify())),
  )
}

///|
fn trusted_local_binding_digest(bindings : Map[String, String]) -> String {
  @crypto.bytes_to_hex_string(
    @crypto.sha256(
      @utf8.encode(sorted_map_entries(bindings).to_json().stringify()),
    ),
  )
}

///|
fn workspace_root_binding_digest(
  workspace_id : String,
  workspace_root : String,
) -> String? {
  guard directory_identity(workspace_root) is Some(native_identity) else {
    return None
  }
  let binding : Json = {
    "schema": "moonfort-workspace-root-binding-v1",
    "workspace_id": workspace_id,
    "canonical_root": workspace_root,
    "native_identity": native_identity,
  }
  Some(
    @crypto.bytes_to_hex_string(
      @crypto.sha256(@utf8.encode(binding.stringify())),
    ),
  )
}
