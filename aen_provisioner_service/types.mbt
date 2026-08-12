///|
pub(all) suberror ProvisionerError {
  InvalidConfiguration(String)
  AuthenticationFailed
  InvalidRequest(String)
  WorkspaceRefused(String)
  StorageFailure(String)
} derive(Debug, ToJson)

///|
pub(all) struct ProvisionerWorkspace {
  root : String
  max_bytes : Int64
  max_entries : Int
  max_file_bytes : Int64
} derive(FromJson)

///|
pub(all) struct ProvisionerLimits {
  max_request_bytes : Int
  max_response_bytes : Int
  request_timeout_ms : Int
  snapshot_timeout_ms : Int
  max_connections : Int
} derive(FromJson)

///|
pub(all) struct ProvisionerConfig {
  bind_address : String
  api_key : String
  receipt_key_id : String
  receipt_key : String
  staging_root : String
  artifact_root : String
  lease_root : String
  registry_repository : String
  workspaces : Map[String, ProvisionerWorkspace]
  limits : ProvisionerLimits
} derive(FromJson)

///|
pub(all) struct ProvisionWorkspaceRequest {
  protocol_version : Int
  run_id : String
  workspace_id : String
  profile_digest : String
  max_bytes : Int64
  reject_symlinks : Bool
  require_immutable_image_digest : Bool
} derive(Debug, Eq, FromJson, ToJson)

///|
pub(all) struct ProvisionedWorkspace {
  workspace_digest : String
  image_ref : String
  image_manifest_digest : String
  entry_count : Int
  total_bytes : Int64
  staging_cleanup_verified : Bool
} derive(Debug, Eq, FromJson, ToJson)

///|
pub(all) struct ProvisionerLease {
  protocol_version : Int
  lease_id : String
  run_id : String
  workspace_id : String
  profile_digest : String
  workspace_digest : String
  image_ref : String
  entry_count : Int
  total_bytes : Int64
  staging_cleanup_verified : Bool
  receipt_key_id : String
  receipt_mac : String
} derive(Debug, Eq, FromJson, ToJson)

///|
pub(all) struct ProvisionerHttpResult {
  status : Int
  reason : String
  body : String
} derive(Debug, Eq)
