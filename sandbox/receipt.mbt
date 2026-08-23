///|
pub(all) enum SandboxEnforcement {
  Enforced
  Degraded
  Refused
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxRunStatus {
  Created
  Running
  Exited
  Killed
  Failed
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Opaque executor-owned reference to the complete merged command output that
/// was captured within the approved output-byte ceiling. The executor verifies
/// the signature and content digest before returning artifact bytes; consumers
/// must never turn `artifact_id` into a host path themselves.
pub(all) struct CommandOutputArtifactRef {
  artifact_id : String
  run_id : String
  sha256 : String
  size_bytes : Int64
  media_type : String
  expires_at_ms : Int64
  key_id : String
  signature : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxReceipt {
  run_id : String
  approval_id : String
  approval_digest : String
  command_digest : String
  backend : SandboxBackendKind
  enforcement : SandboxEnforcement
  status : SandboxRunStatus
  profile_digest : String
  exit_code : Int?
  output : String
  output_truncated : Bool
  output_artifact : CommandOutputArtifactRef?
  limit_reason : String?
  unverified_limits : Array[String]
  changed_paths : Array[String]
  changes : Array[ScratchDiffEntry]
  artifacts : Array[String]
  denial_reason : String?
  cleanup_verified : Bool
  retention_id : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn refused_receipt(
  run_id : String,
  backend : SandboxBackendKind,
  profile_digest : String,
  reason : String,
) -> SandboxReceipt {
  {
    run_id,
    approval_id: "",
    approval_digest: "",
    command_digest: "",
    backend,
    enforcement: Refused,
    status: Failed,
    profile_digest,
    exit_code: None,
    output: "",
    output_truncated: false,
    output_artifact: None,
    limit_reason: None,
    unverified_limits: [],
    changed_paths: [],
    changes: [],
    artifacts: [],
    denial_reason: Some(reason),
    cleanup_verified: false,
    retention_id: None,
  }
}

///|
pub fn exited_receipt(
  run_id : String,
  backend : SandboxBackendKind,
  enforcement : SandboxEnforcement,
  profile_digest : String,
  exit_code : Int,
  output : String,
) -> SandboxReceipt {
  {
    run_id,
    approval_id: "",
    approval_digest: "",
    command_digest: "",
    backend,
    enforcement,
    status: Exited,
    profile_digest,
    exit_code: Some(exit_code),
    output,
    output_truncated: false,
    output_artifact: None,
    limit_reason: None,
    unverified_limits: [],
    changed_paths: [],
    changes: [],
    artifacts: [],
    denial_reason: None,
    cleanup_verified: false,
    retention_id: None,
  }
}

///|
pub fn killed_receipt(
  run_id : String,
  backend : SandboxBackendKind,
  enforcement : SandboxEnforcement,
  profile_digest : String,
  output : String,
  output_truncated : Bool,
  limit_reason : String,
) -> SandboxReceipt {
  {
    run_id,
    approval_id: "",
    approval_digest: "",
    command_digest: "",
    backend,
    enforcement,
    status: Killed,
    profile_digest,
    exit_code: None,
    output,
    output_truncated,
    output_artifact: None,
    limit_reason: Some(limit_reason),
    unverified_limits: [],
    changed_paths: [],
    changes: [],
    artifacts: [],
    denial_reason: None,
    cleanup_verified: false,
    retention_id: None,
  }
}

///|
pub fn failed_receipt(
  run_id : String,
  backend : SandboxBackendKind,
  enforcement : SandboxEnforcement,
  profile_digest : String,
  reason : String,
) -> SandboxReceipt {
  {
    run_id,
    approval_id: "",
    approval_digest: "",
    command_digest: "",
    backend,
    enforcement,
    status: Failed,
    profile_digest,
    exit_code: None,
    output: "",
    output_truncated: false,
    output_artifact: None,
    limit_reason: None,
    unverified_limits: [],
    changed_paths: [],
    changes: [],
    artifacts: [],
    denial_reason: Some(reason),
    cleanup_verified: false,
    retention_id: None,
  }
}

///|
/// Replace the model-facing output with a bounded projection while binding the
/// full retained bytes through an opaque executor-owned artifact reference.
pub fn SandboxReceipt::with_output_artifact(
  self : SandboxReceipt,
  output : String,
  artifact : CommandOutputArtifactRef,
) -> SandboxReceipt {
  { ..self, output, output_artifact: Some(artifact) }
}

///|
/// Bind a backend receipt to the single-use approval and complete approved
/// command manifest that selected it.
pub fn SandboxReceipt::with_approval_binding(
  self : SandboxReceipt,
  approval_id~ : String,
  approval_digest~ : String,
  command_digest~ : String,
  cleanup_verified~ : Bool,
  retention_id? : String,
) -> SandboxReceipt {
  {
    ..self,
    approval_id,
    approval_digest,
    command_digest,
    cleanup_verified,
    retention_id,
  }
}
