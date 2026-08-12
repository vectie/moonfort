///|
const MaxCanaryConfigBytes : Int = 262_144

///|
fn canonical_absolute_path(path : String) -> Bool {
  path.has_prefix("/") &&
  !path.contains("//") &&
  !path.contains("\u{0}") &&
  !path.split("/").any(component => component == "." || component == "..") &&
  (path == "/" || !path.has_suffix("/"))
}

///|
fn safe_identifier(value : String) -> Bool {
  value.length() >= 1 &&
  value.length() <= 128 &&
  value.all(character => {
    character.is_ascii_alphabetic() ||
    character.is_ascii_digit() ||
    character == '-' ||
    character == '_'
  })
}

///|
fn safe_relative_path(path : String) -> Bool {
  path != "" &&
  !path.has_prefix("/") &&
  !path.has_suffix("/") &&
  !path.contains("//") &&
  !path.contains("\\") &&
  !path.contains("\u{0}") &&
  @utf8.encode(path).length() <= 4_096 &&
  path
  .split("/")
  .all(component => component != "" && component != "." && component != "..")
}

///|
fn immutable_oci_reference(value : String) -> Bool {
  guard value.rev_find("@sha256:") is Some(index) else { return false }
  let digest = value[index + 8:]
  index > 0 &&
  digest.length() == 64 &&
  digest.all(character => {
    (character >= '0' && character <= '9') ||
    (character >= 'a' && character <= 'f')
  }) &&
  !value.contains(" ") &&
  !value.contains("\n") &&
  !value.contains("\r") &&
  !value.contains("\t")
}

///|
fn immutable_repository(value : String) -> Bool {
  value.length() >= 3 &&
  value.length() <= 512 &&
  !value.has_prefix("/") &&
  !value.has_suffix("/") &&
  !value.contains("//") &&
  !value.contains("@") &&
  !value.contains("://") &&
  !value.contains("..") &&
  value.all(character => {
    character.is_ascii_alphabetic() ||
    character.is_ascii_digit() ||
    character == '.' ||
    character == '-' ||
    character == '_' ||
    character == '/' ||
    character == ':'
  })
}

///|
fn canonical_https_origin(value : String) -> Bool {
  guard value.has_prefix("https://") else { return false }
  let authority = value[8:]
  authority != "" &&
  !authority.contains("/") &&
  !authority.contains("?") &&
  !authority.contains("#") &&
  !authority.contains("@")
}

///|
fn decode_canary_config(text : String) -> CanaryConfig raise {
  @json.from_json(@json.parse(text))
}

///|
fn validate_static_config(config : CanaryConfig) -> Unit raise {
  guard config.protocol_version == CanaryProtocolVersion else {
    fail("unsupported canary configuration protocol")
  }
  guard config.real_aen_acknowledgement == RealAenAcknowledgement else {
    fail("real AEN hostile-run acknowledgement is missing")
  }
  guard canonical_absolute_path(config.executor_config_path) else {
    fail("executor configuration path is not canonical absolute")
  }
  guard safe_identifier(config.workspace_id) &&
    safe_identifier(config.backend_config_id) else {
    fail("canary workspace or backend identity is invalid")
  }
  guard canonical_https_origin(config.expected_aen_origin) &&
    canonical_https_origin(config.expected_provisioner_origin) else {
    fail("pinned AEN endpoints are missing or invalid")
  }
  guard immutable_oci_reference(config.expected_executor_image_ref) else {
    fail("pinned immutable executor image is missing or invalid")
  }
  guard immutable_repository(config.expected_workspace_registry_repository) else {
    fail("pinned workspace registry repository is missing or invalid")
  }
  guard safe_relative_path(config.mutation_target_relative_path) else {
    fail("mutation target is not a safe workspace-relative path")
  }
  let seen_env : Map[String, Unit] = Map([])
  for name in config.secret_env_names {
    guard safe_identifier(name) && !seen_env.contains(name) else {
      fail("secret environment name list is invalid")
    }
    seen_env[name] = ()
  }
  let limits = config.limits
  guard limits.baseline_wall_clock_ms >= 2_000 &&
    limits.baseline_wall_clock_ms <= 120_000 &&
    limits.timeout_wall_clock_ms >= 1_000 &&
    limits.timeout_wall_clock_ms < limits.baseline_wall_clock_ms &&
    limits.cpu_seconds >= 1 &&
    limits.cpu_seconds <= 60 &&
    limits.memory_mib >= 64 &&
    limits.memory_mib <= 4_096 &&
    limits.disk_mib >= 1 &&
    limits.disk_mib <= 1_024 &&
    limits.processes >= 2 &&
    limits.processes <= 64 &&
    limits.output_bytes >= 256 &&
    limits.output_bytes <= 65_536 &&
    limits.max_diff_entries >= 1 &&
    limits.max_diff_entries <= 4_096 &&
    limits.max_path_bytes >= 16 &&
    limits.max_path_bytes <= 4_096 &&
    limits.max_sentinel_bytes >= 1 &&
    limits.max_sentinel_bytes <= 16_777_216 else {
    fail("canary resource or report bounds are invalid")
  }
}

///|
async fn load_canary_config(path : String) -> CanaryConfig {
  guard canonical_absolute_path(path) &&
    @fs.realpath(path) == path &&
    @fs.kind(path, follow_symlink=false) is Regular else {
    fail("canary configuration is not a canonical regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size >= 0L && size <= MaxCanaryConfigBytes.to_int64() else {
    fail("canary configuration exceeds its byte bound")
  }
  let output = @buffer.Buffer(size_hint=size.to_int().min(8_192))
  for ;; {
    guard file.read_some(
        max_len=(MaxCanaryConfigBytes - output.length() + 1).min(8_192),
      )
      is Some(chunk) else {
      break
    }
    guard output.length() + chunk.length() <= MaxCanaryConfigBytes else {
      fail("canary configuration exceeds its byte bound")
    }
    output.write_bytes(chunk)
  }
  guard file.size() == size &&
    @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.realpath(path) == path else {
    fail("canary configuration changed during read")
  }
  let config = decode_canary_config(@utf8.decode(output.to_bytes()))
  validate_static_config(config)
  config
}

///|
fn validate_deployment(
  canary : CanaryConfig,
  executor : @trusted_executor.ExecutorConfig,
) -> Unit raise {
  guard executor.workspaces.get(canary.workspace_id) is Some(workspace) else {
    fail("pinned canary workspace is absent from the executor registry")
  }
  guard workspace.allowed_backends.contains(MicroVm) &&
    workspace.allowed_networks.contains(Deny) &&
    workspace.allowed_networks.contains(Unrestricted) &&
    !workspace.allow_degraded &&
    workspace.allowed_commands.contains(
      @sandbox.shell_compatibility_command_label(),
    ) &&
    workspace.allowed_commands.contains(NetworkProofCapability) &&
    workspace.allowed_commands.contains(SymlinkProofCapability) else {
    fail("canary workspace policy does not authorize the hostile probe profile")
  }
  guard executor.aen_backends.get(canary.backend_config_id) is Some(backend) else {
    fail("pinned AEN backend is absent from the executor registry")
  }
  guard backend.base_url == canary.expected_aen_origin &&
    backend.provisioner_url == canary.expected_provisioner_origin &&
    backend.executor_image_ref == canary.expected_executor_image_ref &&
    backend.workspace_registry_repository ==
    canary.expected_workspace_registry_repository else {
    fail(
      "trusted AEN endpoint or immutable image does not match the canary pins",
    )
  }
  guard backend.guest_tools.contains(
      @sandbox.shell_compatibility_command_label(),
    ) &&
    backend.guest_tools.contains(NetworkProofCapability) &&
    backend.guest_tools.contains(SymlinkProofCapability) else {
    fail("trusted AEN guest tool registry is missing canary capabilities")
  }
  guard backend.guest_workspace == "/workspace" &&
    backend.guest_scratch == "/scratch" &&
    backend.guest_tools.get(NetworkProofCapability) ==
    Some("/opt/moonfort/tools/network-proof") &&
    backend.guest_tools.get(SymlinkProofCapability) ==
    Some("/opt/moonfort/tools/symlink-proof") else {
    fail("trusted AEN canary guest paths do not match the fixed probe contract")
  }
  guard backend.api_key.trim() != "" &&
    backend.provisioner_api_key.trim() != "" &&
    backend.provisioner_receipt_key.length() >= 32 else {
    fail("trusted AEN endpoint credentials are missing")
  }
  let limits = canary.limits
  guard limits.baseline_wall_clock_ms <= executor.limits.max_wall_clock_ms &&
    limits.cpu_seconds <= executor.limits.max_cpu_seconds &&
    limits.memory_mib <= executor.limits.max_memory_mib &&
    limits.disk_mib <= executor.limits.max_disk_mib &&
    limits.processes <= executor.limits.max_processes &&
    limits.output_bytes <= executor.limits.max_output_bytes &&
    limits.max_diff_entries <= executor.limits.max_changed_paths else {
    fail("canary bounds exceed executor deployment ceilings")
  }
}
