///|
extern "C" fn diff_exit(code : Int) = "exit"

///|
let usage =
  #|Usage: diff-retention PATH [--context 0..20] [--json] < comparison.json
  #|Input: {"baseline": RECEIPT_BINDING, "candidate": RECEIPT_BINDING}
  #|Uses MOONFORT_EXECUTOR_CONFIG. Verifies both retained files; read-only.
  #|UTF-8 text, at most 256 KiB and 2000 lines per side. Default context: 3.
  #|Writes a unified patch, or JSON with receipt identities and fingerprints.
  #|Exit 0 includes identical files (empty patch); exit 1 means no usable result.
  #|

///|
async fn run(args : Array[String]) -> Unit {
  guard args.length() >= 2 else { fail("artifact path required") }
  let path = args[1]
  let mut json_output = false
  let mut context = 3
  let mut context_set = false
  for index = 2; index < args.length(); {
    if args[index] == "--json" && !json_output {
      json_output = true
      continue index + 1
    }
    guard args[index] == "--context" &&
      !context_set &&
      index + 1 < args.length() else {
      fail("invalid option")
    }
    context = @string.parse_int(args[index + 1])
    context_set = true
    continue index + 2
  }
  guard @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") is Some(config_path) else {
    fail("configuration required")
  }
  let config = @executor.load_executor_config(config_path)
  let input = @buffer.Buffer()
  while @stdio.stdin.read_some(max_len=4096) is Some(bytes) {
    guard input.length() + bytes.length() <= config.limits.max_protocol_bytes else {
      fail("comparison input too large")
    }
    input.write_bytes(bytes)
  }
  guard @json.parse(@utf8.decode(input.to_bytes())) is Object(fields) &&
    fields.length() == 2 &&
    fields.get("baseline") is Some(left) &&
    fields.get("candidate") is Some(right) else {
    fail("expected baseline and candidate bindings")
  }
  let result = @executor.diff_retained_artifact(
    @executor.decode_retention_artifact_binding(left),
    @executor.decode_retention_artifact_binding(right),
    path,
    config,
    context~,
  )
  @stdio.stdout.write(
    if json_output {
      result.to_json().stringify() + "\n"
    } else {
      result.patch
    },
  )
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "--help" {
    @stdio.stdout.write(usage)
    return
  }
  run(args) catch {
    _ => {
      @stdio.stderr.write(
        "Text diff unavailable. Check bindings, lifetime, UTF-8 text limits, selected path and options.\n" +
        usage,
      )
      diff_exit(1)
    }
  }
}
