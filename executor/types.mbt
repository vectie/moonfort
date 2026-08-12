///|
/// The only cross-process request accepted by the production executor. All
/// executable policy is loaded from a single-use grant in the trusted store.
pub(all) struct SandboxInvocation {
  protocol_version : Int
  approval_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Request accepted only by the trusted grant publisher, never the executor.
pub(all) struct GrantPublicationRequest {
  protocol_version : Int
  grant : ExecutionGrant
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GrantPublicationResponse {
  protocol_version : Int
  approval_id : String
  approval_digest : String
  published : Bool
  error : ExecutorProtocolError?
} derive(Debug, Eq, ToJson)

///|
/// Explicit review-time promotion request. The opaque retention ID and both
/// execution digests must match the executor-owned record before any canonical
/// workspace write is attempted.
pub(all) struct RetentionPromotionRequest {
  protocol_version : Int
  retention_id : String
  workspace_id : String
  approval_digest : String
  command_digest : String
  items : Array[@sandbox.SandboxPromotionRequest]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RetentionPromotionResponse {
  protocol_version : Int
  retention_id : String
  workspace_id : String
  approval_digest : String
  command_digest : String
  promoted_paths : Array[String]
  completed : Bool
  error : ExecutorProtocolError?
} derive(Debug, Eq, ToJson)

///|
pub(all) struct ExecutionGrant {
  protocol_version : Int
  approval_id : String
  request_id : String
  workspace_id : String
  backend : @sandbox.SandboxBackendKind
  enforcement_requirement : @sandbox.SandboxEnforcementRequirement
  network : @sandbox.SandboxNetworkMode
  allowed_egress : Array[String]
  allowed_commands : Array[String]
  limits : @sandbox.SandboxLimits
  working_directory : String
  command : @sandbox.SandboxCommand
  backend_config_id : String
  expires_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ExecutorLimits {
  max_protocol_bytes : Int
  max_wall_clock_ms : Int
  max_cpu_seconds : Int
  max_memory_mib : Int
  max_disk_mib : Int
  max_processes : Int
  max_output_bytes : Int
  max_command_args : Int
  max_argument_bytes : Int
  max_changed_paths : Int
  retention_ms : Int64
} derive(FromJson)

///|
pub(all) struct WorkspacePolicy {
  root : String
  read_only_roots : Array[String]
  allowed_backends : Array[@sandbox.SandboxBackendKind]
  allowed_networks : Array[@sandbox.SandboxNetworkMode]
  allowed_egress : Array[String]
  allowed_commands : Array[String]
  allow_degraded : Bool
} derive(FromJson)

///|
/// Trusted AEN deployment configuration. It deliberately does not derive
/// `Debug` or `ToJson`, so API keys cannot enter logs or protocol responses via
/// generic rendering.
pub(all) struct TrustedAenConfig {
  base_url : String
  api_key : String
  executor_image_ref : String
  expected_vcpu_count : Int
  expected_root_disk_mib : Int
  provisioner_url : String
  provisioner_api_key : String
  provisioner_receipt_key : String
  provisioner_key_id : String
  max_workspace_bytes : Int64
  guest_workspace : String
  guest_scratch : String
  guest_attester : String
  guest_supervisor : String
  guest_tools : Map[String, String]
} derive(FromJson)

///|
/// Executor-owned configuration loaded from a canonical, regular file. A
/// request cannot select paths, executable bindings, origins, or credentials
/// except through the opaque IDs authorized in its trusted grant.
pub(all) struct ExecutorConfig {
  approval_root : String
  scratch_root : String
  retention_root : String
  workspaces : Map[String, WorkspacePolicy]
  local_tools : Map[String, String]
  aen_backends : Map[String, TrustedAenConfig]
  limits : ExecutorLimits
} derive(FromJson)

///|
struct RetentionRecord {
  retention_id : String
  scratch_path : String
  expires_at_ms : Int64
  workspace_id : String
  approval_digest : String
  command_digest : String
} derive(ToJson, FromJson)

///|
pub(all) struct ExecutorProtocolError {
  code : String
  message : String
} derive(Debug, Eq, ToJson)

///|
/// Constructors keep the success/error fields mutually exclusive.
pub struct ExecutorResponse {
  protocol_version : Int
  approval_id : String
  receipt : @sandbox.SandboxReceipt?
  error : ExecutorProtocolError?
} derive(Debug, Eq, ToJson)

///|
pub fn ExecutorResponse::receipt(
  self : ExecutorResponse,
) -> @sandbox.SandboxReceipt? {
  self.receipt
}

///|
pub fn ExecutorResponse::error(
  self : ExecutorResponse,
) -> ExecutorProtocolError? {
  self.error
}

///|
pub fn completed_response(
  approval_id : String,
  receipt : @sandbox.SandboxReceipt,
) -> ExecutorResponse {
  { protocol_version: 3, approval_id, receipt: Some(receipt), error: None }
}

///|
pub fn rejected_response(
  approval_id : String,
  code : String,
  message : String,
) -> ExecutorResponse {
  {
    protocol_version: 3,
    approval_id,
    receipt: None,
    error: Some({ code, message }),
  }
}
