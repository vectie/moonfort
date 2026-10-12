///|
// Runtime uncaught-error diagnostics can use stdout. Export failures must keep
// that byte channel empty, so exit explicitly after the stderr write completes.
extern "C" fn command_output_exit(code : Int) = "exit"

///|
async fn read_command_output_stdin(limit : Int) -> String {
  guard limit > 0 && limit <= 1_048_576 else {
    fail("invalid protocol byte limit")
  }
  let output = @buffer.Buffer(size_hint=limit.min(8_192))
  while @stdio.stdin.read_some(max_len=(limit - output.length() + 1).min(8_192))
        is Some(chunk) {
    guard output.length() + chunk.length() <= limit else {
      fail("protocol input exceeds byte limit")
    }
    output.write_bytes(chunk)
  }
  @utf8.decode(output.to_bytes())
}

///|
fn command_output_cli_error(code : String, message : String) -> Json {
  {
    "protocol_version": 1,
    "reference": Json::null(),
    "offset": "0",
    "next_offset": "0",
    "content_base64": "",
    "eof": false,
    "status": "refused",
    "error": { "code": code, "message": message },
  }
}

///|
async fn command_output_cli_run(export_mode : Bool) -> Unit {
  let config_path = match @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") {
    Some(path) => path
    None => fail("executor configuration is unavailable")
  }
  let config = @trusted_executor.load_executor_config(config_path) catch {
    _ => fail("executor configuration could not be verified")
  }
  let request = @trusted_executor.decode_command_output_read_request(
    @json.parse(read_command_output_stdin(config.limits.max_protocol_bytes)),
  ) catch {
    _ => fail("output read request is invalid or oversized")
  }
  if export_mode {
    let bytes = @trusted_executor.export_command_output(request, config) catch {
      _ =>
        fail("complete output export was refused; no output bytes were written")
    }
    @stdio.stdout.write(bytes)
  } else {
    let response = @trusted_executor.read_command_output(request, config)
    @stdio.stdout.write(response.to_json().stringify() + "\n")
  }
}

///|
async fn main {
  let args = @env.args()
  let export_mode = args.length() == 2 && args[1] == "--export"
  guard args.length() == 1 || export_mode else {
    ignore(
      @stdio.stderr.write(
        "Usage: read-command-output [--export] < request.json\n",
      ) catch {
        _ => ()
      },
    )
    command_output_exit(2)
    return
  }
  command_output_cli_run(export_mode) catch {
    _ => {
      let error = command_output_cli_error(
        "output-read-refused", "command output could not be read; check configuration, request, and retained reference",
      )
      if export_mode {
        ignore(@stdio.stderr.write(error.stringify() + "\n") catch { _ => () })
        command_output_exit(1)
      } else {
        @stdio.stdout.write(error.stringify() + "\n")
      }
    }
  }
}
