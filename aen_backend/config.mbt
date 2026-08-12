///|
/// Configuration for one AEN-backed execution request. Production callers
/// must populate this from executor-owned configuration, never from an
/// untrusted execution request. The type intentionally has no debug or JSON
/// serialization implementation so API keys are not accidentally reflected.
pub(all) struct AenExecutionConfig {
  base_url : String
  api_key : String
  executor_image_ref : String
  expected_vcpu_count : Int
  expected_root_disk_mib : Int
  provisioner_url : String
  provisioner_api_key : String
  provisioner_receipt_key : String
  provisioner_key_id : String
  workspace_registry_repository : String
  workspace_id : String
  max_workspace_bytes : Int64
  guest_workspace : String
  guest_scratch : String
  guest_attester : String
  guest_supervisor : String
  executor_root_digest : String
  guest_attester_digest : String
  guest_supervisor_digest : String
  tool_registry_digest : String
  guest_tools : Map[String, String]
} derive(Eq)

///|
fn with_lease_cleanup_handle(
  receipt : @sandbox.SandboxReceipt,
  lease_released : Bool,
  lease_id : String,
) -> @sandbox.SandboxReceipt {
  if lease_released {
    return receipt
  }
  let lease_handle = "aen-lease:\{opaque_provider_identifier(lease_id)}"
  {
    ..receipt,
    retention_id: Some(
      match receipt.retention_id {
        Some(vm_handle) => "aen-cleanup:\{vm_handle}|\{lease_handle}"
        None => lease_handle
      },
    ),
  }
}

///|
fn refused_with_lease_cleanup(
  backend : AenBackend[AenHttpTransport],
  reason : String,
  vm_cleanup : Bool,
  lease_released : Bool,
  lease_id : String,
) -> @sandbox.SandboxReceipt {
  let receipt = backend.refused_after_cleanup(
    reason,
    vm_cleanup && lease_released,
  )
  with_lease_cleanup_handle(receipt, lease_released, lease_id)
}

///|
/// Run one prepared command in a newly attested AEN sandbox and delete the VM
/// afterward. Any configuration, attestation, execution, or cleanup failure
/// produces a refused receipt; this function has no local-process fallback.
pub async fn execute_aen_sandbox(
  profile : @sandbox.SandboxProfile,
  command : @sandbox.SandboxCommand,
  config : AenExecutionConfig,
  working_directory? : String = "",
) -> @sandbox.SandboxReceipt {
  let digest = @sandbox.profile_digest(profile)
  let provisioner = AenHttpTransport::new(config.provisioner_url) catch {
    error =>
      return @sandbox.refused_receipt(
        profile.run_id,
        MicroVm,
        digest,
        "invalid AEN provisioner configuration: \{Repr(error)}",
      )
  }
  let lease = provision_workspace(
    provisioner,
    api_key=config.provisioner_api_key,
    receipt_key=config.provisioner_receipt_key,
    receipt_key_id=config.provisioner_key_id,
    registry_repository=config.workspace_registry_repository,
    workspace_id=config.workspace_id,
    max_workspace_bytes=config.max_workspace_bytes,
    profile~,
  ) catch {
    _ =>
      return @sandbox.refused_receipt(
        profile.run_id,
        MicroVm,
        digest,
        "trusted AEN workspace provisioning failed",
      )
  }
  let backend = AenBackend::new(
    AenHttpTransport::new(config.base_url),
    api_key=config.api_key,
    executor_image_ref=config.executor_image_ref,
    workspace_lease=lease,
    expected_vcpu_count=config.expected_vcpu_count,
    expected_root_disk_mib=config.expected_root_disk_mib,
    guest_workspace=config.guest_workspace,
    guest_scratch=config.guest_scratch,
    guest_attester=config.guest_attester,
    guest_supervisor=config.guest_supervisor,
    executor_root_digest=config.executor_root_digest,
    guest_attester_digest=config.guest_attester_digest,
    guest_supervisor_digest=config.guest_supervisor_digest,
    tool_registry_digest=config.tool_registry_digest,
    require_guest_attestation=true,
    guest_tools=config.guest_tools,
    profile~,
  ) catch {
    error => {
      let released = release_workspace(
        provisioner,
        api_key=config.provisioner_api_key,
        lease_id=lease.lease_id,
      ) catch {
        _ => false
      }
      let receipt = {
        ..@sandbox.refused_receipt(
          profile.run_id,
          MicroVm,
          digest,
          "invalid AEN backend configuration: \{Repr(error)}",
        ),
        cleanup_verified: released,
        retention_id: None,
      }
      return with_lease_cleanup_handle(receipt, released, lease.lease_id)
    }
  }
  let started = backend.start()
  if !(started.enforcement is Enforced) {
    let released = release_workspace(
      provisioner,
      api_key=config.provisioner_api_key,
      lease_id=lease.lease_id,
    ) catch {
      _ => false
    }
    let receipt = {
      ..started,
      cleanup_verified: started.cleanup_verified && released,
    }
    return with_lease_cleanup_handle(receipt, released, lease.lease_id)
  }
  let preparation = @sandbox.prepare_sandbox_command(
    profile,
    command,
    BackendEnforced,
  )
  guard preparation.prepared() is Some(prepared) else {
    let reason = match preparation.refusal() {
      Some(value) => value.message()
      None => "AEN command preparation failed without a reason"
    }
    let cleanup = backend.discard()
    let released = release_workspace(
      provisioner,
      api_key=config.provisioner_api_key,
      lease_id=lease.lease_id,
    ) catch {
      _ => false
    }
    return refused_with_lease_cleanup(
      backend,
      reason,
      cleanup,
      released,
      lease.lease_id,
    )
  }
  let receipt = backend.exec(prepared, working_directory~)
  let receipt = if receipt.enforcement is Enforced &&
    receipt.status is Running &&
    !receipt.changed_paths.is_empty() {
    guard backend.sandbox_id() is Some(sandbox_id) else {
      let cleanup = backend.discard()
      let released = release_workspace(
        provisioner,
        api_key=config.provisioner_api_key,
        lease_id=lease.lease_id,
      ) catch {
        _ => false
      }
      return refused_with_lease_cleanup(
        backend,
        "AEN changed run lost its sandbox identity",
        cleanup,
        released,
        lease.lease_id,
      )
    }
    let artifacts = backend.materialize_guest_changes(
      sandbox_id,
      receipt.changes,
    ) catch {
      _ => {
        let cleanup = backend.discard()
        let released = release_workspace(
          provisioner,
          api_key=config.provisioner_api_key,
          lease_id=lease.lease_id,
        ) catch {
          _ => false
        }
        return refused_with_lease_cleanup(
          backend,
          "AEN could not export changed regular files",
          cleanup,
          released,
          lease.lease_id,
        )
      }
    }
    { ..receipt, artifacts, retention_id: None }
  } else {
    receipt
  }
  let cleanup = backend.discard()
  let released = release_workspace(
    provisioner,
    api_key=config.provisioner_api_key,
    lease_id=lease.lease_id,
  ) catch {
    _ => false
  }
  if cleanup && released {
    {
      ..receipt,
      status: if receipt.status is Running {
        Exited
      } else {
        receipt.status
      },
      cleanup_verified: true,
      retention_id: None,
    }
  } else {
    refused_with_lease_cleanup(
      backend,
      "AEN VM or workspace lease cleanup could not be verified after execution",
      cleanup,
      released,
      lease.lease_id,
    )
  }
}
