///|
pub let provisioner_protocol_version : Int = 2

///|
fn safe_identifier(value : String) -> Bool {
  value.length() > 0 &&
  value.length() <= 128 &&
  value.all(character => {
    (character >= 'a' && character <= 'z') ||
    (character >= 'A' && character <= 'Z') ||
    (character >= '0' && character <= '9') ||
    character == '-' ||
    character == '_' ||
    character == '.'
  })
}

///|
fn lowercase_sha256(value : String) -> Bool {
  value.length() == 64 &&
  value.all(character => {
    (character >= '0' && character <= '9') ||
    (character >= 'a' && character <= 'f')
  })
}

///|
fn immutable_repository(value : String) -> Bool {
  value.length() > 0 &&
  value.length() <= 1024 &&
  value[0] != '/' &&
  value[value.length() - 1] != '/' &&
  !value.contains("@") &&
  !value.contains("://") &&
  !value.contains("//") &&
  !value.contains("/../") &&
  !value.contains("/./") &&
  value.all(character => {
    (character >= 'a' && character <= 'z') ||
    (character >= 'A' && character <= 'Z') ||
    (character >= '0' && character <= '9') ||
    character == '.' ||
    character == '_' ||
    character == '-' ||
    character == '/' ||
    character == ':'
  })
}

///|
fn safe_absolute_path(value : String) -> Bool {
  guard value.length() > 1 &&
    value.length() <= 4096 &&
    value[0] == '/' &&
    value[value.length() - 1] != '/' &&
    !value.contains("//") &&
    !value.contains("\u0000") else {
    return false
  }
  for component in value[1:].split("/") {
    if component == "" || component == "." || component == ".." {
      return false
    }
  }
  true
}

///|
fn roots_disjoint(left : String, right : String) -> Bool {
  left != right &&
  !left.has_prefix(right + "/") &&
  !right.has_prefix(left + "/")
}

///|
fn valid_bind_address(value : String) -> Bool {
  guard value.has_prefix("127.0.0.1:") && value.find(":") == value.rev_find(":") else {
    return false
  }
  let parsed : Int = @strconv.from_str(value[10:]) catch { _ => return false }
  parsed > 0 && parsed <= 65535
}

///|
pub fn validate_config(
  config : ProvisionerConfig,
) -> Unit raise ProvisionerError {
  guard valid_bind_address(config.bind_address) &&
    config.api_key.length() >= 32 &&
    config.api_key.length() <= 4096 &&
    safe_identifier(config.receipt_key_id) &&
    config.receipt_key.length() >= 32 &&
    config.receipt_key.length() <= 4096 &&
    immutable_repository(config.registry_repository) else {
    raise InvalidConfiguration(
      "invalid identity, secret, bind, or repository configuration",
    )
  }
  let roots = [config.staging_root, config.artifact_root, config.lease_root]
  for root in roots {
    guard safe_absolute_path(root) else {
      raise InvalidConfiguration("provisioner storage root is not canonical")
    }
  }
  for index in 0..<roots.length() {
    for other in (index + 1)..<roots.length() {
      guard roots_disjoint(roots[index], roots[other]) else {
        raise InvalidConfiguration("provisioner storage roots overlap")
      }
    }
  }
  guard config.limits.max_request_bytes > 0 &&
    config.limits.max_request_bytes <= 65_536 &&
    config.limits.max_response_bytes >= 1024 &&
    config.limits.max_response_bytes <= 65_536 &&
    config.limits.request_timeout_ms > 0 &&
    config.limits.request_timeout_ms <= 30_000 &&
    config.limits.snapshot_timeout_ms > 0 &&
    config.limits.snapshot_timeout_ms <= 600_000 &&
    config.limits.max_connections > 0 &&
    config.limits.max_connections <= 32 &&
    !config.workspaces.is_empty() else {
    raise InvalidConfiguration(
      "invalid provisioner limits or empty workspace registry",
    )
  }
  for workspace_id, workspace in config.workspaces {
    guard safe_identifier(workspace_id) &&
      safe_absolute_path(workspace.root) &&
      workspace.max_bytes > 0L &&
      workspace.max_bytes <= 1_099_511_627_776L &&
      workspace.max_entries > 0 &&
      workspace.max_entries <= 1_000_000 &&
      workspace.max_file_bytes > 0L &&
      workspace.max_file_bytes <= workspace.max_bytes &&
      roots.all(root => roots_disjoint(root, workspace.root)) else {
      raise InvalidConfiguration("invalid trusted workspace registry entry")
    }
  }
}

///|
fn validate_request(
  request : ProvisionWorkspaceRequest,
  config : ProvisionerConfig,
) -> ProvisionerWorkspace raise ProvisionerError {
  guard request.protocol_version == provisioner_protocol_version &&
    safe_identifier(request.run_id) &&
    safe_identifier(request.workspace_id) &&
    lowercase_sha256(request.profile_digest) &&
    request.max_bytes > 0L &&
    request.reject_symlinks &&
    request.require_immutable_image_digest else {
    raise InvalidRequest(
      "request identity, bounds, or mandatory policy is invalid",
    )
  }
  guard config.workspaces.get(request.workspace_id) is Some(workspace) else {
    raise WorkspaceRefused("workspace ID is not registered")
  }
  guard request.max_bytes <= workspace.max_bytes else {
    raise WorkspaceRefused(
      "requested workspace ceiling exceeds registry policy",
    )
  }
  workspace
}

///|
fn constant_time_equal(left : String, right : String) -> Bool {
  let left = @utf8.encode(left)
  let right = @utf8.encode(right)
  let length = left.length().max(right.length())
  let mut mismatch = left.length() ^ right.length()
  for index in 0..<length {
    let left_byte = if index < left.length() { left[index].to_int() } else { 0 }
    let right_byte = if index < right.length() {
      right[index].to_int()
    } else {
      0
    }
    mismatch = mismatch | (left_byte ^ right_byte)
  }
  mismatch == 0
}
