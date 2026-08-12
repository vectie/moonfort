///|
/// Enforcement guarantees reported by a backend before a command is launched.
/// This describes preparation only; it does not execute a host process.
pub(all) enum SandboxBackendReadiness {
  BackendEnforced
  BackendDegraded(String)
  BackendUnavailable(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Structured refusal reasons are stable across local-OS and microVM adapters.
pub(all) enum SandboxPreparationRefusal {
  InvalidProfile(String)
  EmptyCommand(SandboxCommandKind)
  InvalidExecToolLabel(String)
  CommandContainsNul(kind~ : SandboxCommandKind, argument_index~ : Int)
  CommandNotAllowed(String)
  BackendUnavailable(backend~ : SandboxBackendKind, reason~ : String)
  LocalBackendCannotClaimEnforced
  DegradedNotAllowed(backend~ : SandboxBackendKind, reason~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// An opaque, policy-checked command description. Backends can inspect copies
/// of the profile and command but cannot obtain a host process from this value.
pub struct PreparedSandboxCommand {
  profile : SandboxProfile
  profile_digest : String
  command : SandboxCommand
  capability_label : String
  enforcement : SandboxEnforcement
} derive(Debug, Eq)

///|
/// Preparation is fail-closed: callers receive either an opaque prepared value
/// or a refusal with no executable fallback embedded in the result.
pub enum SandboxPreparation {
  Prepared(PreparedSandboxCommand)
  Refused(SandboxPreparationRefusal)
} derive(Debug, Eq)

///|
pub fn SandboxBackendReadiness::label(self : SandboxBackendReadiness) -> String {
  match self {
    BackendEnforced => "enforced"
    BackendDegraded(_) => "degraded"
    BackendUnavailable(_) => "unavailable"
  }
}

///|
pub fn SandboxPreparationRefusal::code(
  self : SandboxPreparationRefusal,
) -> String {
  match self {
    InvalidProfile(_) => "invalid-profile"
    EmptyCommand(_) => "empty-command"
    InvalidExecToolLabel(_) => "invalid-exec-tool-label"
    CommandContainsNul(..) => "command-contains-nul"
    CommandNotAllowed(_) => "command-not-allowed"
    BackendUnavailable(..) => "backend-unavailable"
    LocalBackendCannotClaimEnforced => "local-backend-cannot-claim-enforced"
    DegradedNotAllowed(..) => "degraded-not-allowed"
  }
}

///|
pub fn SandboxPreparationRefusal::message(
  self : SandboxPreparationRefusal,
) -> String {
  match self {
    InvalidProfile(reason) => "invalid sandbox profile: \{reason}"
    EmptyCommand(kind) => "\{kind.label()} command must not be empty"
    InvalidExecToolLabel(label) =>
      "exec tool must be a safe allow-list label, got \{label}"
    CommandContainsNul(kind~, argument_index~) =>
      "\{kind.label()} command contains NUL at argument \{argument_index}"
    CommandNotAllowed(label) => "command capability is not allowed: \{label}"
    BackendUnavailable(backend~, reason~) =>
      "\{backend_label(backend)} backend unavailable: \{reason}"
    LocalBackendCannotClaimEnforced =>
      "local OS backend cannot claim full profile enforcement"
    DegradedNotAllowed(backend~, reason~) =>
      "degraded \{backend_label(backend)} backend requires operator opt-in: \{reason}"
  }
}

///|
pub fn SandboxPreparation::is_prepared(self : SandboxPreparation) -> Bool {
  self is Prepared(_)
}

///|
pub fn SandboxPreparation::prepared(
  self : SandboxPreparation,
) -> PreparedSandboxCommand? {
  match self {
    Prepared(command) => Some(command)
    Refused(_) => None
  }
}

///|
pub fn SandboxPreparation::refusal(
  self : SandboxPreparation,
) -> SandboxPreparationRefusal? {
  match self {
    Prepared(_) => None
    Refused(reason) => Some(reason)
  }
}

///|
pub fn PreparedSandboxCommand::profile(
  self : PreparedSandboxCommand,
) -> SandboxProfile {
  copy_profile(self.profile)
}

///|
pub fn PreparedSandboxCommand::profile_digest(
  self : PreparedSandboxCommand,
) -> String {
  self.profile_digest
}

///|
pub fn PreparedSandboxCommand::command(
  self : PreparedSandboxCommand,
) -> SandboxCommand {
  self.command.copy()
}

///|
pub fn PreparedSandboxCommand::capability_label(
  self : PreparedSandboxCommand,
) -> String {
  self.capability_label
}

///|
pub fn PreparedSandboxCommand::enforcement(
  self : PreparedSandboxCommand,
) -> SandboxEnforcement {
  self.enforcement
}

///|
fn copy_profile(profile : SandboxProfile) -> SandboxProfile {
  {
    ..profile,
    read_only_roots: profile.read_only_roots.copy(),
    allowed_egress: profile.allowed_egress.copy(),
    allowed_commands: profile.allowed_commands.copy(),
  }
}

///|
fn command_capability(
  command : SandboxCommand,
) -> Result[String, SandboxPreparationRefusal] {
  match command {
    Exec(tool~, args~) =>
      if tool.trim() == "" {
        Err(EmptyCommand(ExecCommand))
      } else if !exec_tool_label_is_safe(tool) {
        Err(InvalidExecToolLabel(tool))
      } else {
        for index, argument in args {
          if argument.contains("\u{0}") {
            return Err(
              CommandContainsNul(kind=ExecCommand, argument_index=index),
            )
          }
        }
        Ok(tool)
      }
    Shell(script~) =>
      if script.trim() == "" {
        Err(EmptyCommand(ShellCompatibilityCommand))
      } else if script.contains("\u{0}") {
        Err(
          CommandContainsNul(kind=ShellCompatibilityCommand, argument_index=0),
        )
      } else {
        Ok(shell_compatibility_command_label())
      }
  }
}

///|
fn preparation_enforcement(
  backend : SandboxBackendKind,
  readiness : SandboxBackendReadiness,
  requirement : SandboxEnforcementRequirement,
) -> Result[SandboxEnforcement, SandboxPreparationRefusal] {
  if backend is Unavailable {
    return Err(
      BackendUnavailable(
        backend=Unavailable,
        reason="no execution backend selected",
      ),
    )
  }
  match readiness {
    BackendUnavailable(reason) =>
      Err(BackendUnavailable(backend~, reason=normalized_reason(reason)))
    BackendEnforced =>
      if backend is LocalOs {
        Err(LocalBackendCannotClaimEnforced)
      } else {
        Ok(Enforced)
      }
    BackendDegraded(reason) => {
      let reason = normalized_reason(reason)
      match requirement {
        RequireEnforced => Err(DegradedNotAllowed(backend~, reason~))
        AllowDegraded => Ok(Degraded)
      }
    }
  }
}

///|
fn normalized_reason(reason : String) -> String {
  if reason.trim() == "" {
    "backend supplied no reason"
  } else {
    reason
  }
}

///|
pub fn prepare_sandbox_command(
  profile : SandboxProfile,
  command : SandboxCommand,
  readiness : SandboxBackendReadiness,
) -> SandboxPreparation {
  let invalid_profile = profile_rejection(profile)
  if invalid_profile != "" {
    return Refused(InvalidProfile(invalid_profile))
  }
  let capability = match command_capability(command) {
    Err(reason) => return Refused(reason)
    Ok(label) => label
  }
  if !profile.allowed_commands.contains(capability) {
    return Refused(CommandNotAllowed(capability))
  }
  match
    preparation_enforcement(
      profile.backend,
      readiness,
      profile.enforcement_requirement,
    ) {
    Err(reason) => Refused(reason)
    Ok(enforcement) => {
      let profile_snapshot = copy_profile(profile)
      Prepared({
        profile: profile_snapshot,
        profile_digest: profile_digest(profile_snapshot),
        command: command.copy(),
        capability_label: capability,
        enforcement,
      })
    }
  }
}
