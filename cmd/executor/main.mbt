///|
async fn read_bounded_stdin(limit : Int) -> String {
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
async fn main {
  let response = match @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") {
    None =>
      @trusted_executor.rejected_response(
        "", "configuration-refused", "executor configuration is unavailable",
      )
    Some(config_path) => {
      let config_result : Result[@trusted_executor.ExecutorConfig, Unit] = Ok(
        @trusted_executor.load_executor_config(config_path),
      ) catch {
        _ => Err(())
      }
      match config_result {
        Err(_) =>
          @trusted_executor.rejected_response(
            "", "configuration-refused", "executor configuration could not be verified",
          )
        Ok(config) => {
          let invocation : @trusted_executor.SandboxInvocation = try {
            let input = read_bounded_stdin(config.limits.max_protocol_bytes)
            @json.from_json(@json.parse(input))
          } catch {
            _ => {
              let rejected = @trusted_executor.rejected_response(
                "", "protocol-refused", "execution invocation is invalid or oversized",
              )
              @stdio.stdout.write(rejected.to_json().stringify() + "\n")
              return
            }
          }
          @trusted_executor.execute_invocation(invocation, config)
        }
      }
    }
  }
  @stdio.stdout.write(response.to_json().stringify() + "\n")
}
