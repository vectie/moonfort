///|
extern "C" fn comparison_exit(code : Int) = "exit"

///|
let usage = "Usage: compare-retention [--prefix PATH] [--after PATH] [--limit 1..200] [--include-unchanged] [--json] < comparison.json\nInput: {\"baseline\": RECEIPT_BINDING, \"candidate\": RECEIPT_BINDING}\nUses MOONFORT_EXECUTOR_CONFIG. Read-only saved manifest comparison; does not verify live bytes, execute, approve or promote.\n"

///|
async fn run(args : Array[String]) -> Unit {
  let options : Map[String, String] = Map([])
  let mut json = false
  let mut unchanged = false
  for i = 1; i < args.length(); {
    if args[i] == "--json" && !json {
      json = true
      continue i + 1
    }
    if args[i] == "--include-unchanged" && !unchanged {
      unchanged = true
      continue i + 1
    }
    guard ["--prefix", "--after", "--limit"].contains(args[i]) &&
      i + 1 < args.length() &&
      !options.contains(args[i]) else {
      fail("invalid option")
    }
    options[args[i]] = args[i + 1]
    continue i + 2
  }
  guard @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") is Some(path) else {
    fail("configuration required")
  }
  let config = @executor.load_executor_config(path)
  let input = @buffer.Buffer()
  while @stdio.stdin.read_some(max_len=4096) is Some(bytes) {
    guard input.length() + bytes.length() <= config.limits.max_protocol_bytes else {
      fail("input too large")
    }
    input.write_bytes(bytes)
  }
  guard @json.parse(@utf8.decode(input.to_bytes())) is Object(fields) &&
    fields.length() == 2 &&
    fields.get("baseline") is Some(left) &&
    fields.get("candidate") is Some(right) else {
    fail("expected baseline and candidate bindings")
  }
  let result = @executor.compare_retained_artifacts(
    @executor.decode_retention_artifact_binding(left),
    @executor.decode_retention_artifact_binding(right),
    config,
    prefix=options.get("--prefix").unwrap_or(""),
    after=options.get("--after").unwrap_or(""),
    limit=@string.parse_int(options.get("--limit").unwrap_or("50")),
    include_unchanged=unchanged,
  )
  if json {
    @stdio.stdout.write(result.to_json().stringify() + "\n")
    return
  }
  let output = StringBuilder()
  output.write_string(
    "Saved manifest comparison: " +
    result.baseline.retention_id.to_json().stringify() +
    " -> " +
    result.candidate.retention_id.to_json().stringify() +
    "\n",
  )
  output.write_string(
    "Added \{result.added}; removed \{result.removed}; changed \{result.changed}; unchanged \{result.unchanged}; byte delta \{result.byte_delta}\n",
  )
  output.write_string(
    "Metadata only. Preview/export selected bytes before review. No approval or promotion.\n",
  )
  for row in result.entries {
    output.write_string(
      row.change +
      " " +
      row.path.to_json().stringify() +
      " (byte delta \{row.byte_delta})\n",
    )
    for (label, file) in [("before", row.before), ("after", row.after)] {
      if file is Some(file) {
        output.write_string(
          "  " +
          label +
          ": \{file.size_bytes} bytes SHA256 " +
          file.fingerprint +
          "\n",
        )
      }
    }
  }
  if result.has_more {
    output.write_string(
      "More rows; --after " +
      result.next_after.to_json().stringify() +
      " with the same filters.\n",
    )
  }
  @stdio.stdout.write(output.to_string())
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
        "Comparison unavailable. Check bindings, retention lifetime, configuration and options.\n" +
        usage,
      )
      comparison_exit(1)
    }
  }
}
