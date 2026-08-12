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
fn canonical_absolute_path(path : String) -> Bool {
  path.has_prefix("/") &&
  !path.contains("//") &&
  !path.contains("\u{0}") &&
  !path.split("/").any(component => component == "." || component == "..") &&
  (path == "/" || !path.has_suffix("/"))
}

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
fn sha256_digest(value : String) -> Bool {
  value.length() == 64 &&
  value.all(character => {
    (character >= '0' && character <= '9') ||
    (character >= 'a' && character <= 'f')
  })
}

///|
fn immutable_oci_repository(value : String) -> Bool {
  value.length() >= 3 &&
  value.length() <= 1024 &&
  !value.has_prefix("/") &&
  !value.has_suffix("/") &&
  !value.contains("//") &&
  !value.contains("@") &&
  !value.contains("://") &&
  !value.contains(" ") &&
  !value.contains("\n") &&
  !value.contains("\r") &&
  !value.contains("\t") &&
  !value.split("/").any(component => component == "." || component == "..") &&
  value.all(character => {
    character.is_ascii_alphabetic() ||
    character.is_ascii_digit() ||
    character == '.' ||
    character == '_' ||
    character == '-' ||
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
fn safe_relative_directory(path : String) -> Bool {
  path == "" ||
  (
    !path.has_prefix("/") &&
    !path.has_suffix("/") &&
    !path.contains("//") &&
    !path.contains("\u{0}") &&
    @utf8.encode(path).length() <= 4096 &&
    !path.split("/").any(component => component == "." || component == "..")
  )
}

///|
fn path_contains(root : String, candidate : String) -> Bool {
  root == candidate ||
  (if root == "/" {
    candidate.has_prefix("/")
  } else {
    candidate.has_prefix(root + "/")
  })
}

///|
fn paths_overlap(left : String, right : String) -> Bool {
  path_contains(left, right) || path_contains(right, left)
}

///|
fn subset(values : Array[String], allowed : Array[String]) -> Bool {
  values.all(value => allowed.contains(value))
}

///|
fn unique(values : Array[String]) -> Bool {
  let seen : Map[String, Unit] = Map([])
  for value in values {
    if seen.contains(value) {
      return false
    }
    seen[value] = ()
  }
  true
}

///|
fn command_shape_error(
  command : @sandbox.SandboxCommand,
  limits : ExecutorLimits,
) -> String {
  match command {
    Exec(tool~, args~) => {
      if !safe_identifier(tool) && tool != "shell-compat" {
        return "unsafe command capability label"
      }
      if args.length() > limits.max_command_args {
        return "command argument count exceeds deployment limit"
      }
      for arg in args {
        if arg.contains("\u{0}") ||
          @utf8.encode(arg).length() > limits.max_argument_bytes {
          return "command argument exceeds deployment limit"
        }
      }
      ""
    }
    Shell(script~) =>
      if script.contains("\u{0}") ||
        @utf8.encode(script).length() > limits.max_argument_bytes {
        "shell script exceeds deployment limit"
      } else {
        ""
      }
  }
}

///|
fn grant_capability(command : @sandbox.SandboxCommand) -> String {
  match command {
    Exec(tool~, ..) => tool
    Shell(..) => @sandbox.shell_compatibility_command_label()
  }
}

///|
fn validate_limits(
  requested : @sandbox.SandboxLimits,
  ceiling : ExecutorLimits,
) -> String {
  if requested.wall_clock_ms <= 0 ||
    requested.wall_clock_ms > ceiling.max_wall_clock_ms {
    "wall clock limit is outside deployment policy"
  } else if requested.cpu_seconds <= 0 ||
    requested.cpu_seconds > ceiling.max_cpu_seconds {
    "CPU limit is outside deployment policy"
  } else if requested.memory_mib <= 0 ||
    requested.memory_mib > ceiling.max_memory_mib {
    "memory limit is outside deployment policy"
  } else if requested.disk_mib <= 0 || requested.disk_mib > ceiling.max_disk_mib {
    "disk limit is outside deployment policy"
  } else if requested.processes <= 0 ||
    requested.processes > ceiling.max_processes {
    "process limit is outside deployment policy"
  } else if requested.output_bytes <= 0 ||
    requested.output_bytes > ceiling.max_output_bytes {
    "output limit is outside deployment policy"
  } else {
    ""
  }
}

///|
fn validate_grant(
  grant : ExecutionGrant,
  invocation : SandboxInvocation,
  config : ExecutorConfig,
) -> String {
  if grant.protocol_version != 3 {
    return "unsupported grant protocol version"
  }
  if grant.approval_id != invocation.approval_id {
    return "grant approval ID does not match invocation"
  }
  if !safe_identifier(grant.request_id) || !safe_identifier(grant.workspace_id) {
    return "grant request or workspace ID is invalid"
  }
  if grant.expires_at_ms <= @env.now().reinterpret_as_int64() {
    return "grant is expired"
  }
  guard config.workspaces.get(grant.workspace_id) is Some(workspace) else {
    return "grant names an unknown workspace"
  }
  if !workspace.allowed_backends.contains(grant.backend) {
    return "backend is not authorized for workspace"
  }
  if !workspace.allowed_networks.contains(grant.network) {
    return "network mode is not authorized for workspace"
  }
  if !unique(grant.allowed_egress) ||
    !subset(grant.allowed_egress, workspace.allowed_egress) {
    return "egress set is not authorized for workspace"
  }
  if !unique(grant.allowed_commands) ||
    !subset(grant.allowed_commands, workspace.allowed_commands) {
    return "command capability set is not authorized for workspace"
  }
  let capability = grant_capability(grant.command)
  if !grant.allowed_commands.contains(capability) {
    return "command is not included in approved capabilities"
  }
  if grant.enforcement_requirement is AllowDegraded && !workspace.allow_degraded {
    return "degraded execution is not authorized for workspace"
  }
  let limit_error = validate_limits(grant.limits, config.limits)
  if limit_error != "" {
    return limit_error
  }
  if !safe_relative_directory(grant.working_directory) {
    return "working directory is not a safe workspace-relative path"
  }
  let command_error = command_shape_error(grant.command, config.limits)
  if command_error != "" {
    return command_error
  }
  match grant.backend {
    LocalOs => {
      if grant.backend_config_id != "local" {
        return "local grant must select the local deployment"
      }
      for label in grant.allowed_commands {
        let effective = if label == @sandbox.shell_compatibility_command_label() {
          "/bin/sh"
        } else {
          config.local_tools.get(label).unwrap_or("")
        }
        if !canonical_absolute_path(effective) {
          return "approved local capability has no trusted executable"
        }
      }
    }
    MicroVm =>
      if !safe_identifier(grant.backend_config_id) ||
        !config.aen_backends.contains(grant.backend_config_id) {
        return "grant names an unknown AEN deployment"
      }
    Unavailable => return "grant cannot select an unavailable backend"
  }
  ""
}
