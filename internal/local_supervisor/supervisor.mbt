///|
pub(all) struct Limits {
  wall_clock_ms : Int64
  cpu_seconds : Int64
  address_space_bytes : Int64
  file_size_bytes : Int64
  open_files : Int64
  processes : Int64
  aggregate_disk_bytes : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct Request {
  argv : Array[String]
  cwd : String
  environment : Map[String, String]
  output_path : String
  disk_root : String
  output_bytes : Int64
  limits : Limits
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct Result {
  kind : String
  exit_code : Int?
  signal : Int?
  limit : String?
  setup_stage : String?
  os_errno : Int?
  elapsed_ms : Int64
  applied_limits : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) suberror SupervisorError {
  InvalidRequest(String)
  NativeProtocol(String)
} derive(Debug, Eq, ToJson)

///|
#borrow(argv_blob, env_blob, cwd, output_path, disk_root)
extern "c" fn run_native(
  argv_blob : Bytes,
  argv_blob_len : Int,
  argc : Int,
  env_blob : Bytes,
  env_blob_len : Int,
  envc : Int,
  cwd : Bytes,
  cwd_len : Int,
  output_path : Bytes,
  output_path_len : Int,
  disk_root : Bytes,
  disk_root_len : Int,
  output_bytes : Int64,
  wall_clock_ms : Int64,
  cpu_seconds : Int64,
  address_space_bytes : Int64,
  file_size_bytes : Int64,
  open_files : Int64,
  processes : Int64,
  aggregate_disk_bytes : Int64,
) -> Bytes = "moonfort_local_supervisor_run"

///|
fn contains_nul(value : String) -> Bool {
  value.contains("\u0000")
}

///|
fn encode_nul_list(values : ArrayView[String]) -> Bytes {
  let builder = StringBuilder::new()
  for value in values {
    builder.write_string(value)
    builder.write_char('\u0000')
  }
  @utf8.encode(builder.to_string())
}

///|
fn validate(request : Request) -> Unit raise SupervisorError {
  if request.argv.is_empty() {
    raise InvalidRequest("argv must not be empty")
  }
  if !request.argv[0].has_prefix("/") {
    raise InvalidRequest("argv[0] must be an absolute executable path")
  }
  for arg in request.argv {
    if contains_nul(arg) {
      raise InvalidRequest("argv must not contain NUL")
    }
  }
  if !request.cwd.has_prefix("/") || contains_nul(request.cwd) {
    raise InvalidRequest("cwd must be an absolute NUL-free path")
  }
  for key, value in request.environment {
    if key == "" ||
      key.contains("=") ||
      key.has_prefix("MOONFORT_SUPERVISOR_") ||
      contains_nul(key) ||
      contains_nul(value) {
      raise InvalidRequest(
        "environment entries must have NUL-free names and values",
      )
    }
  }
  if !request.output_path.has_prefix("/") || contains_nul(request.output_path) {
    raise InvalidRequest("output_path must be an absolute NUL-free path")
  }
  if request.disk_root != "" &&
    (!request.disk_root.has_prefix("/") || contains_nul(request.disk_root)) {
    raise InvalidRequest("disk_root must be empty or an absolute NUL-free path")
  }
  if request.output_bytes <= 0L {
    raise InvalidRequest("output_bytes must be positive")
  }
  let limits = request.limits
  if limits.wall_clock_ms <= 0L ||
    limits.cpu_seconds <= 0L ||
    limits.address_space_bytes <= 0L ||
    limits.file_size_bytes <= 0L ||
    limits.open_files <= 0L ||
    limits.processes <= 0L ||
    limits.aggregate_disk_bytes <= 0L {
    raise InvalidRequest("all limits must be positive")
  }
}

///|
/// Run one absolute executable through a fresh POSIX session/process group.
///
/// The child receives only `request.environment`, never the supervisor's host
/// environment. Native setup failures are returned as `setup_failed`; execution
/// never falls back to an unconfined host spawn. Process count is sampled for
/// the supervised process group and aggregate logical bytes are sampled beneath
/// `disk_root`; neither is represented as a kernel quota on macOS.
pub fn run(request : Request) -> Result raise SupervisorError {
  validate(request)
  let env = [ for key, value in request.environment => "\{key}=\{value}" ]
  let argv_blob = encode_nul_list(request.argv)
  let env_blob = encode_nul_list(env)
  let cwd_bytes = @utf8.encode(request.cwd)
  let output_path_bytes = @utf8.encode(request.output_path)
  let disk_root_bytes = @utf8.encode(request.disk_root)
  let raw = run_native(
    argv_blob,
    argv_blob.length(),
    request.argv.length(),
    env_blob,
    env_blob.length(),
    env.length(),
    cwd_bytes,
    cwd_bytes.length(),
    output_path_bytes,
    output_path_bytes.length(),
    disk_root_bytes,
    disk_root_bytes.length(),
    request.output_bytes,
    request.limits.wall_clock_ms,
    request.limits.cpu_seconds,
    request.limits.address_space_bytes,
    request.limits.file_size_bytes,
    request.limits.open_files,
    request.limits.processes,
    request.limits.aggregate_disk_bytes,
  )
  let text = @utf8.decode_lossy(raw)
  try @json.from_json(@json.parse(text)) catch {
    _ => raise NativeProtocol(text)
  } noraise {
    result => result
  }
}
