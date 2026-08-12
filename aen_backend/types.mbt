///|
pub(all) suberror AenBackendError {
  InvalidConfiguration(String)
  TransportFailure(String)
  ProtocolFailure(String)
} derive(Debug, ToJson)

///|
pub(all) enum AenHttpMethod {
  Get
  Post
  Put
  Delete
} derive(Debug, Eq)

///|
pub(all) struct AenHeader {
  name : String
  value : String
} derive(Eq)

///|
pub(all) enum AenRequestBody {
  EmptyBody
  JsonBody(Json)
  ProtobufBody(Bytes)
  ConnectBody(Bytes)
}

///|
/// Transport-neutral representation of an AgentENV control-plane or envd
/// request. `timeout_ms` is a mandatory upper bound that concrete transports
/// must enforce for the complete request or stream lifetime.
pub(all) struct AenRequest {
  verb : AenHttpMethod
  path : String
  headers : Array[AenHeader]
  body : AenRequestBody
  timeout_ms : Int
  response_bytes : Int
}

///|
pub(all) struct AenResponse {
  status : Int
  body : Bytes
}

///|
pub(all) enum AenStreamControl {
  ContinueStream
  StopStream
} derive(Debug, Eq)

///|
pub(open) trait AenTransport {
  /// Execute one bounded HTTP request. Redirects must not be followed.
  async fn request(Self, AenRequest) -> AenResponse

  /// Stream raw response body chunks in order. The implementation must close
  /// the response immediately when `consume` returns `StopStream` and must
  /// enforce `request.timeout_ms` across the whole stream.
  async fn stream(Self, AenRequest, consume~ : (Bytes) -> AenStreamControl) -> Unit
}

///|
pub(all) enum AenLifecycleState {
  Created
  Running
  Paused
  Stopped
  Refused
} derive(Debug, Eq)

///|
pub(all) struct AenArtifactResult {
  artifact_id : String?
  receipt : @sandbox.SandboxReceipt
} derive(Debug)

///|
pub(all) struct AenForkResult {
  sandbox_ids : Array[String]
  receipt : @sandbox.SandboxReceipt
} derive(Debug)

///|
/// Immutable workspace-drive lease returned by the trusted companion
/// provisioner. The image reference is content-addressed and the receipt MAC
/// binds it to the exact executor-owned workspace, run, and profile.
pub(all) struct AenWorkspaceLease {
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
  receipt_mac : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum AenExecEvent {
  ProcessStarted(Int)
  Stdout(Bytes)
  Stderr(Bytes)
  ProcessExited(Int, String)
  ConnectEnded(String?)
} derive(Debug, Eq)
