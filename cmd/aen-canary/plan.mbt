///|
struct CanaryPlan {
  case : CanaryCase
  command : @sandbox.SandboxCommand
  allowed_commands : Array[String]
  network : @sandbox.SandboxNetworkMode
  limits : @sandbox.SandboxLimits
} derive(Debug, Eq)

///|
fn shell_quote(value : String) -> String {
  "'" + value.replace_all(old="'", new="'\"'\"'") + "'"
}

///|
fn baseline_limits(config : CanaryConfig) -> @sandbox.SandboxLimits {
  {
    wall_clock_ms: config.limits.baseline_wall_clock_ms,
    cpu_seconds: config.limits.cpu_seconds,
    memory_mib: config.limits.memory_mib,
    disk_mib: config.limits.disk_mib,
    processes: config.limits.processes,
    output_bytes: config.limits.output_bytes,
  }
}

///|
fn shell_plan(
  case : CanaryCase,
  script : String,
  limits : @sandbox.SandboxLimits,
) -> CanaryPlan {
  {
    case,
    command: Shell(script~),
    allowed_commands: [@sandbox.shell_compatibility_command_label()],
    network: Deny,
    limits,
  }
}

///|
fn repeated_text(text : String, count : Int) -> String {
  let output = StringBuilder()
  for _ in 0..<count {
    output.write_string(text)
  }
  output.to_string()
}

///|
fn build_plans(
  config : CanaryConfig,
  backend : @trusted_executor.TrustedAenConfig,
) -> Array[CanaryPlan] {
  let limits = baseline_limits(config)
  let target = shell_quote(
    "\{backend.guest_workspace}/\{config.mutation_target_relative_path}",
  )
  let chunk = repeated_text("0123456789abcdef", 64)
  let disk_blocks = config.limits.disk_mib * 1_024 + 1
  let process_count = config.limits.processes * 4 + 8
  let timeout_limits = {
    ..limits,
    wall_clock_ms: config.limits.timeout_wall_clock_ms,
  }
  [
    shell_plan(
      CanonicalMutation,
      "printf moonfort-aen-canary > \{target}",
      limits,
    ),
    {
      case: NetworkPositiveControl,
      command: Exec(tool=NetworkProofCapability, args=[NetworkProofArgument]),
      allowed_commands: [NetworkProofCapability],
      network: Unrestricted,
      limits,
    },
    {
      case: NetworkEgress,
      command: Exec(tool=NetworkProofCapability, args=[NetworkProofArgument]),
      allowed_commands: [NetworkProofCapability],
      network: Deny,
      limits,
    },
    shell_plan(
      OutputFlood,
      "while :; do printf 0123456789abcdef0123456789abcdef; done",
      limits,
    ),
    shell_plan(
      ProcessExplosion,
      "i=0; while [ \"$i\" -lt \{process_count} ]; do (while :; do :; done) & i=$((i + 1)); done; wait",
      limits,
    ),
    shell_plan(
      AggregateDisk,
      "i=0; chunk=\{shell_quote(chunk)}; while [ \"$i\" -lt \{disk_blocks} ]; do printf %s \"$chunk\" >> moonfort-canary-disk.bin || exit $?; i=$((i + 1)); done",
      limits,
    ),
    shell_plan(
      TimeoutDescendants,
      "(while :; do :; done) & while :; do :; done",
      timeout_limits,
    ),
    shell_plan(SecretEnvRead, "env", limits),
    {
      case: SymlinkTraversal,
      command: Exec(tool=SymlinkProofCapability, args=[
        SymlinkProofArgument,
        config.mutation_target_relative_path,
      ]),
      allowed_commands: [SymlinkProofCapability],
      network: Deny,
      limits,
    },
  ]
}

///|
fn make_grant(
  plan : CanaryPlan,
  config : CanaryConfig,
  approval_id : String,
  request_id : String,
) -> @trusted_executor.ExecutionGrant {
  {
    protocol_version: 3,
    approval_id,
    request_id,
    workspace_id: config.workspace_id,
    backend: MicroVm,
    enforcement_requirement: RequireEnforced,
    network: plan.network,
    allowed_egress: [],
    allowed_commands: plan.allowed_commands.copy(),
    limits: plan.limits,
    working_directory: "",
    command: plan.command,
    backend_config_id: config.backend_config_id,
    expires_at_ms: @env.now().reinterpret_as_int64() + 300_000L,
  }
}
