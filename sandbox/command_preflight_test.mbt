///|
fn test_profile(
  backend? : SandboxBackendKind = MicroVm,
  enforcement_requirement? : SandboxEnforcementRequirement = RequireEnforced,
  allowed_commands? : Array[String] = ["moon", "git"],
) -> SandboxProfile {
  {
    run_id: "run-preflight-1",
    workspace_root: "/workspace/book",
    scratch_root: "/scratch/run-preflight-1",
    backend,
    enforcement_requirement,
    network: Deny,
    read_only_roots: ["/workspace/book"],
    allowed_egress: [],
    allowed_commands,
    limits: default_limits(),
    read_only_workspace: true,
  }
}

///|
fn refusal_code(result : SandboxPreparation) -> String raise {
  match result.refusal() {
    Some(reason) => reason.code()
    None => fail("expected preparation refusal")
  }
}

///|
test "Exec preserves a pre-tokenized argv" {
  let arguments = ["test", "--filter", "name with spaces", "$(not-a-shell)"]
  let result = prepare_sandbox_command(
    test_profile(),
    Exec(tool="moon", args=arguments),
    BackendEnforced,
  )
  guard result.prepared() is Some(prepared) else {
    fail("expected prepared command")
  }
  assert_eq(prepared.capability_label(), "moon")
  assert_true(prepared.enforcement() is Enforced)
  assert_eq(prepared.profile_digest(), profile_digest(test_profile()))
  debug_inspect(
    prepared.command(),
    content=(
      #|Exec(
      #|  tool="moon",
      #|  args=["test", "--filter", "name with spaces", "$(not-a-shell)"],
      #|)
    ),
  )
}

///|
test "empty Exec and Shell commands are refused" {
  let profile = test_profile(allowed_commands=[
    "moon",
    shell_compatibility_command_label(),
  ])
  assert_eq(
    refusal_code(
      prepare_sandbox_command(
        profile,
        Exec(tool="  ", args=[]),
        BackendEnforced,
      ),
    ),
    "empty-command",
  )
  assert_eq(
    refusal_code(
      prepare_sandbox_command(profile, Shell(script="\n\t"), BackendEnforced),
    ),
    "empty-command",
  )
}

///|
test "Exec allow-list matching is exact and rejects host paths" {
  let profile = test_profile(allowed_commands=["moon"])
  assert_eq(
    refusal_code(
      prepare_sandbox_command(
        profile,
        Exec(tool="git", args=["status"]),
        BackendEnforced,
      ),
    ),
    "command-not-allowed",
  )
  assert_eq(
    refusal_code(
      prepare_sandbox_command(
        profile,
        Exec(tool="/usr/bin/moon", args=["check"]),
        BackendEnforced,
      ),
    ),
    "invalid-exec-tool-label",
  )
}

///|
test "Shell compatibility requires its explicit capability" {
  let denied = prepare_sandbox_command(
    test_profile(),
    Shell(script="moon check && git status"),
    BackendEnforced,
  )
  assert_eq(refusal_code(denied), "command-not-allowed")
  let allowed = prepare_sandbox_command(
    test_profile(allowed_commands=[shell_compatibility_command_label()]),
    Shell(script="moon check && git status"),
    BackendEnforced,
  )
  assert_true(allowed.is_prepared())
}

///|
test "degraded enforcement is refused without explicit operator opt-in" {
  let strict = prepare_sandbox_command(
    test_profile(backend=LocalOs),
    Exec(tool="moon", args=["check"]),
    BackendDegraded("local backend does not enforce every resource limit"),
  )
  assert_eq(refusal_code(strict), "degraded-not-allowed")
  let opted_in = prepare_sandbox_command(
    test_profile(backend=LocalOs, enforcement_requirement=AllowDegraded),
    Exec(tool="moon", args=["check"]),
    BackendDegraded("local backend does not enforce every resource limit"),
  )
  guard opted_in.prepared() is Some(prepared) else {
    fail("expected opted-in degraded preparation")
  }
  assert_true(prepared.enforcement() is Degraded)
}

///|
test "local backend cannot overclaim full enforcement" {
  let result = prepare_sandbox_command(
    test_profile(backend=LocalOs, enforcement_requirement=AllowDegraded),
    Exec(tool="moon", args=["check"]),
    BackendEnforced,
  )
  assert_eq(refusal_code(result), "local-backend-cannot-claim-enforced")
}

///|
test "unavailable backend has no executable fallback" {
  let result = prepare_sandbox_command(
    test_profile(enforcement_requirement=AllowDegraded),
    Exec(tool="moon", args=["check"]),
    BackendUnavailable("microVM service is offline"),
  )
  assert_false(result.is_prepared())
  assert_true(result.prepared() is None)
  assert_eq(refusal_code(result), "backend-unavailable")
}

///|
test "prepared command owns copies of mutable command and profile arrays" {
  let allowed = ["moon"]
  let arguments = ["check"]
  let result = prepare_sandbox_command(
    test_profile(allowed_commands=allowed),
    Exec(tool="moon", args=arguments),
    BackendEnforced,
  )
  allowed[0] = "git"
  arguments[0] = "publish"
  guard result.prepared() is Some(prepared) else {
    fail("expected prepared command")
  }
  assert_eq(prepared.profile().allowed_commands[0], "moon")
  debug_inspect(
    prepared.command(),
    content=(
      #|Exec(tool="moon", args=["check"])
    ),
  )
}
