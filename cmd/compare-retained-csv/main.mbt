///|
extern "C" fn csv_comparison_exit(code : Int) = "exit"

///|
let usage : String =
  #|Usage: compare-retained-csv PATH --key-columns 1,2 [--json | --csv] < comparison.json
  #|Input: {"baseline": RECEIPT_BINDING, "candidate": RECEIPT_BINDING}
  #|Default stdout is complete JSON. --csv writes changed cells to stdout and source context to stderr.
  #|Uses MOONFORT_EXECUTOR_CONFIG. Read-only; no execution or promotion.
  #|

///|
async fn run(args : Array[String]) -> Unit {
  guard args.length() >= 4 else { fail("path and --key-columns are required") }
  let path = args[1]
  let mut columns : Array[Int]? = None
  let mut format : String? = None
  for index = 2; index < args.length(); {
    if (args[index] == "--json" || args[index] == "--csv") && format is None {
      format = Some(args[index])
      continue index + 1
    }
    guard args[index] == "--key-columns" &&
      columns is None &&
      index + 1 < args.length() else {
      fail("unknown, repeated or incomplete option")
    }
    let selected : Array[Int] = []
    for part in args[index + 1].split(",") {
      selected.push(@string.parse_int(part.to_owned()))
    }
    columns = Some(selected)
    continue index + 2
  }
  guard columns is Some(key_columns) else { fail("--key-columns is required") }
  guard @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") is Some(config_path) else {
    fail("configuration required")
  }
  let config = @executor.load_executor_config(config_path)
  let input = @buffer.Buffer()
  while @stdio.stdin.read_some(max_len=4096) is Some(bytes) {
    guard input.length() + bytes.length() <= config.limits.max_protocol_bytes else {
      fail("comparison input exceeds protocol budget")
    }
    input.write_bytes(bytes)
  }
  guard @json.parse(@utf8.decode(input.to_bytes())) is Object(fields) &&
    fields.length() == 2 &&
    fields.get("baseline") is Some(left) &&
    fields.get("candidate") is Some(right) else {
    fail("expected baseline and candidate bindings")
  }
  let result = @executor.compare_retained_csv(
    @executor.decode_retention_artifact_binding(left),
    @executor.decode_retention_artifact_binding(right),
    path,
    config,
    key_columns~,
  )
  if format == Some("--csv") {
    let csv = result.to_csv()
    @stdio.stderr.write(result.context().stringify() + "\n")
    @stdio.stdout.write(csv)
  } else {
    @stdio.stdout.write(result.to_json().stringify() + "\n")
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "--help" {
    @stdio.stdout.write(usage)
    return
  }
  run(args) catch {
    error => {
      @stdio.stderr.write("CSV comparison unavailable: \{error}\n" + usage)
      csv_comparison_exit(1)
    }
  }
}
