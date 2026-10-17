///|
/// A correction for the next failed policy check. Rechecking after correction
/// uses the same validator as publication; this is never approval evidence.
pub(all) struct GrantCorrection {
  field : String
  message : String
  next_step : String
} derive(Debug, Eq, ToJson)

///|
pub(all) struct GrantRehearsal {
  protocol_version : Int
  ready_for_review : Bool
  review_digest : String
  candidate : ExecutionGrant?
  correction : GrantCorrection?
  notice : String
} derive(Debug, Eq, ToJson)

///|
fn grant_correction(reason : String) -> GrantCorrection {
  let field = if reason.contains("protocol") {
    "protocol_version"
  } else if reason.contains("approval") {
    "approval_id"
  } else if reason.contains("expired") {
    "expires_at_ms"
  } else if reason.contains("request or workspace") {
    "request_id / workspace_id"
  } else if reason.contains("unknown workspace") {
    "workspace_id"
  } else if reason.contains("egress") {
    "allowed_egress"
  } else if reason.contains("network") {
    "network"
  } else if reason.contains("wall-clock") {
    "limits.wall_clock_ms"
  } else if reason.contains("CPU") {
    "limits.cpu_seconds"
  } else if reason.contains("memory") {
    "limits.memory_mib"
  } else if reason.contains("disk") {
    "limits.disk_mib"
  } else if reason.contains("process limit") {
    "limits.processes"
  } else if reason.contains("output limit") {
    "limits.output_bytes"
  } else if reason.contains("working directory") {
    "working_directory"
  } else if reason.contains("degraded") {
    "enforcement_requirement"
  } else if reason.contains("backend") ||
    reason.contains("AEN deployment") ||
    reason.contains("local deployment") {
    "backend / backend_config_id"
  } else {
    "command / allowed_commands"
  }
  {
    field,
    message: reason,
    next_step: "Correct this candidate field within the existing trusted policy, then run --check again. Do not weaken policy to make it pass.",
  }
}

///|
/// Bind both the exact candidate and the trusted scope displayed indirectly by
/// its workspace identity. No secret or host path is returned to the caller.
fn grant_review_digest(
  grant : ExecutionGrant,
  config : ExecutorConfig,
) -> String {
  guard config.workspaces.get(grant.workspace_id) is Some(workspace) else {
    return ""
  }
  let backend = match grant.backend {
    MicroVm =>
      match config.aen_backends.get(grant.backend_config_id) {
        Some(value) => trusted_aen_binding_digest(value)
        None => ""
      }
    _ => trusted_local_binding_digest(config.local_tools)
  }
  let manifest : Json = {
    "schema": "moonfort-grant-review-v1",
    "grant_digest": grant_digest(grant),
    "workspace_root": workspace.root,
    "read_only_roots": workspace.read_only_roots,
    "allowed_backends": workspace.allowed_backends,
    "allowed_networks": workspace.allowed_networks,
    "allowed_egress": workspace.allowed_egress,
    "allowed_commands": workspace.allowed_commands,
    "allow_degraded": workspace.allow_degraded,
    "backend_binding": backend,
  }
  @crypto.bytes_to_hex_string(
    @crypto.sha256(@utf8.encode(manifest.stringify())),
  )
}

///|
/// Read-only rehearsal. This performs policy validation, not a backend probe,
/// grant publication, grant consumption, or a containment qualification.
pub fn rehearse_grant(
  request : GrantPublicationRequest,
  config : ExecutorConfig,
) -> GrantRehearsal {
  let grant = request.grant
  let reason = if request.protocol_version != 3 {
    "unsupported publication protocol"
  } else if !safe_identifier(grant.approval_id) {
    "invalid approval identity"
  } else {
    validate_grant(
      grant,
      { protocol_version: 3, approval_id: grant.approval_id, },
      config,
    )
  }
  let ready = reason == ""
  {
    protocol_version: 1,
    ready_for_review: ready,
    review_digest: if ready {
      grant_review_digest(grant, config)
    } else {
      ""
    },
    candidate: if ready {
      Some(grant)
    } else {
      None
    },
    correction: if ready {
      None
    } else {
      Some(grant_correction(reason))
    },
    notice: "Check only: nothing published or executed. Review this exact candidate with the named approver before --publish-reviewed. Backend availability and enforcement remain execution-time gates.",
  }
}

///|
/// The review digest detects stale review; it is not a signature or authority.
/// Only the already-trusted publisher may call this after human approval.
pub async fn publish_reviewed_grant(
  request : GrantPublicationRequest,
  expected_review_digest : String,
  config : ExecutorConfig,
) -> GrantPublicationResponse {
  let check = rehearse_grant(request, config)
  if !check.ready_for_review ||
    !sha256_digest(expected_review_digest) ||
    expected_review_digest != check.review_digest {
    return {
      protocol_version: 3,
      approval_id: request.grant.approval_id,
      approval_digest: "",
      published: false,
      error: Some({
        code: "review-stale",
        message: "Candidate or trusted scope changed, review is missing, or policy no longer permits it. Run --check and obtain fresh approval.",
      }),
    }
  }
  publish_grant(request, config)
}

///|
pub extend GrantCorrection with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend GrantCorrection with Eq::{not_equal, equal}

///|
pub extend GrantCorrection with ToJson::{to_json}

///|
pub extend GrantRehearsal with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend GrantRehearsal with Eq::{not_equal, equal}

///|
pub extend GrantRehearsal with ToJson::{to_json}
