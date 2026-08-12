///|
const CanaryProtocolVersion : Int = 2

///|
const NetworkProofCapability : String = "moonfort-network-proof-v1"

///|
const NetworkProofArgument : String = "probe"

///|
const NetworkReachableMarker : String = "MOONFORT_NETWORK_REACHABLE_V1\n"

///|
const NetworkBlockedMarker : String = "MOONFORT_NETWORK_BLOCKED_V1\n"

///|
const NetworkBlockedExitCode : Int = 90

///|
const SymlinkProofCapability : String = "moonfort-symlink-proof-v1"

///|
const SymlinkProofArgument : String = "probe"

///|
const SymlinkDeniedMarker : String = "MOONFORT_SYMLINK_POLICY_DENIED_V1\n"

///|
const SymlinkDeniedExitCode : Int = 91

///|
const RealAenAcknowledgement : String = "I_UNDERSTAND_THIS_RUNS_HOSTILE_CODE_ON_REAL_AEN"

///|
struct CanaryLimits {
  baseline_wall_clock_ms : Int
  timeout_wall_clock_ms : Int
  cpu_seconds : Int
  memory_mib : Int
  disk_mib : Int
  processes : Int
  output_bytes : Int
  max_diff_entries : Int
  max_path_bytes : Int
  max_sentinel_bytes : Int
} derive(Debug, Eq, FromJson)

///|
struct CanaryConfig {
  protocol_version : Int
  real_aen_acknowledgement : String
  executor_config_path : String
  workspace_id : String
  backend_config_id : String
  expected_aen_origin : String
  expected_provisioner_origin : String
  expected_executor_image_ref : String
  expected_workspace_registry_repository : String
  mutation_target_relative_path : String
  secret_env_names : Array[String]
  limits : CanaryLimits
} derive(Debug, Eq, FromJson)

///|
struct CanaryCaseResult {
  name : String
  passed : Bool
  status : @sandbox.SandboxRunStatus?
  enforcement : @sandbox.SandboxEnforcement?
  output_bytes : Int
  output_truncated : Bool
  limit_reason : String?
  changed_path_count : Int
  change_count : Int
  artifact_count : Int
  cleanup_verified : Bool
  failures : Array[String]
} derive(ToJson)

///|
struct CanaryReport {
  protocol_version : Int
  workspace_id : String
  backend_config_id : String
  passed : Bool
  cases : Array[CanaryCaseResult]
  error : String?
} derive(ToJson)

///|
enum CanaryCase {
  CanonicalMutation
  NetworkPositiveControl
  NetworkEgress
  OutputFlood
  ProcessExplosion
  AggregateDisk
  TimeoutDescendants
  SecretEnvRead
  SymlinkTraversal
} derive(Debug, Eq)

///|
fn CanaryCase::name(self : CanaryCase) -> String {
  match self {
    CanonicalMutation => "canonical-mutation"
    NetworkPositiveControl => "network-positive-control"
    NetworkEgress => "network-egress"
    OutputFlood => "output-flood"
    ProcessExplosion => "process-explosion"
    AggregateDisk => "aggregate-disk"
    TimeoutDescendants => "timeout-descendants"
    SecretEnvRead => "secret-env-read"
    SymlinkTraversal => "symlink-traversal"
  }
}
