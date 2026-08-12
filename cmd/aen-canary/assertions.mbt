///|
fn push_failure(
  failures : Array[String],
  condition : Bool,
  reason : String,
) -> Unit {
  if !condition {
    failures.push(reason)
  }
}

///|
fn nonzero_exit(receipt : @sandbox.SandboxReceipt) -> Bool {
  receipt.exit_code is Some(code) && code != 0
}

///|
fn secret_values(
  config : CanaryConfig,
  backend : @trusted_executor.TrustedAenConfig,
) -> Array[String] {
  let values = [
    backend.api_key,
    backend.provisioner_api_key,
    backend.provisioner_receipt_key,
  ]
  for name in config.secret_env_names {
    if @env.get_env_var(name) is Some(value) && value.length() >= 4 {
      values.push(value)
    }
  }
  values
}

///|
fn assert_common_receipt(
  receipt : @sandbox.SandboxReceipt,
  publication_digest : String,
  approval_id : String,
  config : CanaryConfig,
  backend : @trusted_executor.TrustedAenConfig,
  failures : Array[String],
) -> Unit {
  push_failure(
    failures,
    receipt.approval_id == approval_id &&
    receipt.approval_digest == publication_digest,
    "receipt is not bound to the published single-use grant digest",
  )
  push_failure(
    failures,
    receipt.command_digest.length() == 64,
    "receipt has no complete command digest binding",
  )
  push_failure(failures, receipt.backend is MicroVm, "receipt is not MicroVm")
  push_failure(
    failures,
    receipt.enforcement is Enforced,
    "receipt is not Enforced",
  )
  push_failure(
    failures,
    receipt.unverified_limits.is_empty(),
    "receipt contains unverified limits",
  )
  push_failure(
    failures,
    receipt.cleanup_verified,
    "VM and workspace lease cleanup are not verified",
  )
  push_failure(
    failures,
    receipt.changed_paths.length() <= config.limits.max_diff_entries &&
    receipt.changes.length() <= config.limits.max_diff_entries,
    "structured diff exceeds the canary entry bound",
  )
  for path in receipt.changed_paths {
    push_failure(
      failures,
      @utf8.encode(path).length() <= config.limits.max_path_bytes &&
      @sandbox.scratch_relative_path_is_safe(path),
      "changed path is unsafe or exceeds the canary byte bound",
    )
  }
  for change in receipt.changes {
    push_failure(
      failures,
      @utf8.encode(change.relative_path).length() <=
      config.limits.max_path_bytes &&
      @sandbox.scratch_relative_path_is_safe(change.relative_path),
      "structured diff path is unsafe or exceeds the canary byte bound",
    )
  }
  for value in secret_values(config, backend) {
    if value.length() >= 4 {
      push_failure(
        failures,
        !receipt.output.contains(value),
        "a trusted secret value appeared in guest output",
      )
    }
  }
}

///|
fn assert_case_receipt(
  case : CanaryCase,
  receipt : @sandbox.SandboxReceipt,
  publication_digest : String,
  approval_id : String,
  config : CanaryConfig,
  backend : @trusted_executor.TrustedAenConfig,
  sentinel_unchanged : Bool,
) -> CanaryCaseResult {
  let failures : Array[String] = []
  assert_common_receipt(
    receipt, publication_digest, approval_id, config, backend, failures,
  )
  match case {
    CanonicalMutation => {
      push_failure(
        failures,
        nonzero_exit(receipt),
        "canonical workspace mutation did not fail",
      )
      push_failure(
        failures, sentinel_unchanged, "canonical workspace sentinel changed on the host",
      )
    }
    NetworkPositiveControl =>
      push_failure(
        failures,
        receipt.status is Exited &&
        receipt.exit_code == Some(0) &&
        receipt.output == NetworkReachableMarker &&
        !receipt.output_truncated &&
        receipt.limit_reason is None,
        "network positive control did not return exact reachable evidence",
      )
    NetworkEgress =>
      push_failure(
        failures,
        receipt.status is Exited &&
        receipt.exit_code == Some(NetworkBlockedExitCode) &&
        receipt.output == NetworkBlockedMarker &&
        !receipt.output_truncated &&
        receipt.limit_reason is None,
        "deny-network probe did not return exact blocked-network evidence",
      )
    OutputFlood => {
      push_failure(
        failures,
        receipt.status is Killed &&
        receipt.output_truncated &&
        receipt.limit_reason == Some("output_bytes"),
        "output flood was not killed by the output byte limit",
      )
      push_failure(
        failures,
        @utf8.encode(receipt.output).length() <= config.limits.output_bytes,
        "retained output exceeds the approved byte limit",
      )
    }
    ProcessExplosion =>
      push_failure(
        failures,
        receipt.status is Killed &&
        receipt.exit_code is None &&
        receipt.limit_reason == Some("processes"),
        "process explosion did not hit the exact process limit",
      )
    AggregateDisk =>
      push_failure(
        failures,
        receipt.status is Killed &&
        receipt.exit_code is None &&
        receipt.limit_reason == Some("disk_mib"),
        "aggregate disk probe did not hit the exact disk limit",
      )
    TimeoutDescendants =>
      push_failure(
        failures,
        receipt.status is Killed &&
        receipt.limit_reason == Some("wall_clock_ms"),
        "timeout descendants were not killed by the wall-clock limit",
      )
    SecretEnvRead => {
      push_failure(
        failures,
        receipt.exit_code == Some(0),
        "guest environment read probe did not execute",
      )
      push_failure(
        failures,
        !receipt.output_truncated,
        "guest environment read exceeded the bounded evidence channel",
      )
    }
    SymlinkTraversal =>
      push_failure(
        failures,
        receipt.status is Exited &&
        receipt.exit_code == Some(SymlinkDeniedExitCode) &&
        receipt.output == SymlinkDeniedMarker &&
        !receipt.output_truncated &&
        receipt.limit_reason is None,
        "symlink traversal did not return exact policy-denial evidence",
      )
  }
  {
    name: case.name(),
    passed: failures.is_empty(),
    status: Some(receipt.status),
    enforcement: Some(receipt.enforcement),
    output_bytes: @utf8.encode(receipt.output).length(),
    output_truncated: receipt.output_truncated,
    limit_reason: receipt.limit_reason,
    changed_path_count: receipt.changed_paths.length(),
    change_count: receipt.changes.length(),
    artifact_count: receipt.artifacts.length(),
    cleanup_verified: receipt.cleanup_verified,
    failures,
  }
}

///|
fn protocol_failure(case : CanaryCase, reason : String) -> CanaryCaseResult {
  {
    name: case.name(),
    passed: false,
    status: None,
    enforcement: None,
    output_bytes: 0,
    output_truncated: false,
    limit_reason: None,
    changed_path_count: 0,
    change_count: 0,
    artifact_count: 0,
    cleanup_verified: false,
    failures: [reason],
  }
}
