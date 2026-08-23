///|
async fn read_live_output_stdin(limit : Int) -> String {
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
fn read_live_output_refused(code : String, message : String) -> Json {
  {
    "protocol_version": 1,
    "approval_id": "",
    "stream_id": "",
    "run_id": "",
    "offset": 0,
    "next_offset": 0,
    "available_bytes": 0,
    "content_base64": "",
    "status": "unavailable",
    "terminal": true,
    "retry_after_ms": 0,
    "error": { "code": code, "message": message },
  }
}

///|
async fn main {
  let response : Json = match @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") {
    None =>
      read_live_output_refused(
        "configuration-refused", "executor configuration is unavailable",
      )
    Some(config_path) => {
      let config = @trusted_executor.load_executor_config(config_path) catch {
        _ => {
          let refused = read_live_output_refused(
            "configuration-refused", "executor configuration could not be verified",
          )
          @stdio.stdout.write(refused.stringify() + "\n")
          return
        }
      }
      let request : @trusted_executor.LiveOutputReadRequest = try {
        let input = read_live_output_stdin(config.limits.max_protocol_bytes)
        @json.from_json(@json.parse(input))
      } catch {
        _ => {
          let refused = read_live_output_refused(
            "protocol-refused", "live output request is invalid or oversized",
          )
          @stdio.stdout.write(refused.stringify() + "\n")
          return
        }
      }
      @trusted_executor.read_live_output(request, config).to_json()
    }
  }
  @stdio.stdout.write(response.stringify() + "\n")
}
