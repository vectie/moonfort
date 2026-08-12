///|
fn profile_for_grant(
  grant : ExecutionGrant,
  workspace : WorkspacePolicy,
  scratch : String,
) -> @sandbox.SandboxProfile {
  {
    run_id: grant.request_id,
    workspace_root: workspace.root,
    scratch_root: scratch,
    backend: grant.backend,
    enforcement_requirement: grant.enforcement_requirement,
    network: grant.network,
    read_only_roots: workspace.read_only_roots.copy(),
    allowed_egress: grant.allowed_egress.copy(),
    allowed_commands: grant.allowed_commands.copy(),
    limits: grant.limits,
    read_only_workspace: true,
  }
}

///|
async fn local_bindings(
  grant : ExecutionGrant,
  config : ExecutorConfig,
) -> (Map[String, String], Array[@sandbox.LocalSandboxTool]) {
  let selected : Map[String, String] = Map([])
  let bindings : Array[@sandbox.LocalSandboxTool] = []
  for label in grant.allowed_commands {
    if label == @sandbox.shell_compatibility_command_label() {
      continue
    }
    guard config.local_tools.get(label) is Some(configured) else {
      fail("trusted local capability disappeared")
    }
    let actual = @fs.realpath(configured)
    guard actual == configured &&
      @fs.kind(configured, follow_symlink=false) is Regular else {
      fail("trusted local executable changed before launch")
    }
    selected[label] = configured
    bindings.push({ capability_label: label, executable_path: configured })
  }
  (selected, bindings)
}

///|
fn trusted_aen_execution_config(
  trusted : TrustedAenConfig,
  workspace_id : String,
) -> @aen_backend.AenExecutionConfig {
  {
    base_url: trusted.base_url,
    api_key: trusted.api_key,
    executor_image_ref: trusted.executor_image_ref,
    expected_vcpu_count: trusted.expected_vcpu_count,
    expected_root_disk_mib: trusted.expected_root_disk_mib,
    provisioner_url: trusted.provisioner_url,
    provisioner_api_key: trusted.provisioner_api_key,
    provisioner_receipt_key: trusted.provisioner_receipt_key,
    workspace_id,
    max_workspace_bytes: trusted.max_workspace_bytes,
    guest_workspace: trusted.guest_workspace,
    guest_scratch: trusted.guest_scratch,
    guest_attester: trusted.guest_attester,
    guest_supervisor: trusted.guest_supervisor,
    guest_tools: trusted.guest_tools,
  }
}

///|
/// Run one atomically consumed, executor-owned approval grant.
pub async fn execute_invocation(
  invocation : SandboxInvocation,
  config : ExecutorConfig,
) -> ExecutorResponse {
  ignore(sweep_expired_retentions(config) catch { _ => 0 })
  let grant = consume_grant(invocation, config) catch {
    _ =>
      return rejected_response(
        invocation.approval_id,
        "approval-refused",
        "approval is unknown, invalid, expired, or already consumed",
      )
  }
  let rejection = validate_grant(grant, invocation, config)
  if rejection != "" {
    return rejected_response(invocation.approval_id, "grant-refused", rejection)
  }
  guard config.workspaces.get(grant.workspace_id) is Some(workspace) else {
    return rejected_response(
      invocation.approval_id,
      "workspace-refused",
      "trusted workspace registry changed",
    )
  }
  let (scratch, retention_id) = allocate_scratch(grant.request_id, config) catch {
    _ =>
      return rejected_response(
        invocation.approval_id,
        "scratch-refused",
        "executor-owned scratch could not be created",
      )
  }
  let profile = profile_for_grant(grant, workspace, scratch)
  let approval_digest = grant_digest(grant)
  let mut selected_tools : Map[String, String] = Map([])
  let mut backend_binding_digest = ""
  let raw_receipt = match grant.backend {
    LocalOs => {
      let bindings = local_bindings(grant, config) catch {
        _ => {
          ignore(@sandbox.discard_scratch_tree(scratch))
          return rejected_response(
            invocation.approval_id,
            "tool-registry-refused",
            "trusted local executable binding could not be verified",
          )
        }
      }
      selected_tools = bindings.0
      backend_binding_digest = trusted_local_binding_digest(selected_tools)
      @sandbox.run_local_sandbox(
        profile,
        grant.command,
        bindings.1,
        working_directory=grant.working_directory,
      )
    }
    MicroVm => {
      guard config.aen_backends.get(grant.backend_config_id) is Some(trusted) else {
        ignore(@sandbox.discard_scratch_tree(scratch))
        return rejected_response(
          invocation.approval_id,
          "backend-refused",
          "trusted AEN deployment disappeared",
        )
      }
      backend_binding_digest = trusted_aen_binding_digest(trusted)
      @aen_backend.execute_aen_sandbox(
        profile,
        grant.command,
        trusted_aen_execution_config(trusted, grant.workspace_id),
        working_directory=grant.working_directory,
      )
    }
    Unavailable =>
      @sandbox.refused_receipt(
        grant.request_id,
        Unavailable,
        @sandbox.profile_digest(profile),
        "unavailable backend cannot execute",
      )
  }
  let command_digest = command_digest(
    grant,
    profile,
    selected_tools,
    grant.backend_config_id,
    backend_binding_digest,
  )
  let retain_local = grant.backend is LocalOs &&
    raw_receipt.status is Exited &&
    raw_receipt.enforcement is Degraded &&
    !raw_receipt.changed_paths.is_empty() &&
    raw_receipt.changed_paths.length() <= config.limits.max_changed_paths
  let retained = if retain_local {
    retain_scratch(
      scratch, retention_id, approval_digest, command_digest, config,
    )
  } else {
    false
  }
  let host_cleanup_verified = if retained {
    true
  } else {
    @sandbox.discard_scratch_tree(scratch) is Ok(_)
  }
  // Backend cleanup uncertainty is sticky. Local terminal receipts normally
  // leave this false because verified supervisor cleanup is represented by a
  // terminal kind, so accept host scratch cleanup only for ordinary local
  // terminal results; never upgrade a refusal/failure from the supervisor.
  let backend_terminal_cleanup = match grant.backend {
    MicroVm => raw_receipt.cleanup_verified
    LocalOs =>
      raw_receipt.enforcement is Degraded &&
      (raw_receipt.status is Exited || raw_receipt.status is Killed)
    Unavailable => false
  }
  let cleanup_verified = backend_terminal_cleanup && host_cleanup_verified
  let receipt = if raw_receipt.changed_paths.length() >
    config.limits.max_changed_paths {
    @sandbox.refused_receipt(
      grant.request_id,
      grant.backend,
      @sandbox.profile_digest(profile),
      "changed path count exceeds deployment limit",
    )
  } else {
    raw_receipt
  }
  completed_response(
    invocation.approval_id,
    receipt.with_approval_binding(
      approval_id=invocation.approval_id,
      approval_digest~,
      command_digest~,
      cleanup_verified~,
      retention_id?=if retained {
        Some(retention_id)
      } else {
        raw_receipt.retention_id
      },
    ),
  )
}
