///|
/// A command intent, kept independent from any host process API.
///
/// `Exec` preserves an already-tokenized argument vector. `Shell` is an
/// explicit compatibility mode and is never inferred from command text.
pub(all) enum SandboxCommand {
  Exec(tool~ : String, args~ : Array[String])
  Shell(script~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxCommandKind {
  ExecCommand
  ShellCompatibilityCommand
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The reserved allow-list entry required for `Shell` compatibility commands.
/// It cannot be used as an `Exec` tool label.
pub fn shell_compatibility_command_label() -> String {
  "shell-compat"
}

///|
pub fn SandboxCommand::kind(self : SandboxCommand) -> SandboxCommandKind {
  match self {
    Exec(..) => ExecCommand
    Shell(..) => ShellCompatibilityCommand
  }
}

///|
pub fn SandboxCommandKind::label(self : SandboxCommandKind) -> String {
  match self {
    ExecCommand => "exec"
    ShellCompatibilityCommand => "shell-compat"
  }
}

///|
fn exec_tool_label_is_safe(label : String) -> Bool {
  let valid_first = match label.get_char(0) {
    Some(first) => first.is_ascii_alphabetic() || first.is_ascii_digit()
    None => false
  }
  valid_first &&
  label.all(char => {
    char.is_ascii_alphabetic() ||
    char.is_ascii_digit() ||
    char == '_' ||
    char == '-' ||
    char == '.' ||
    char == '+'
  }) &&
  label != shell_compatibility_command_label()
}

///|
fn SandboxCommand::copy(self : SandboxCommand) -> SandboxCommand {
  match self {
    Exec(tool~, args~) => Exec(tool~, args=args.copy())
    Shell(script~) => Shell(script~)
  }
}
