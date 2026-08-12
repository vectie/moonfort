///|
async fn bounded_stdin(limit : Int) -> String {
  guard limit > 0 && limit <= 1_048_576 else { fail("invalid input limit") }
  let output = @buffer.Buffer(size_hint=limit.min(8_192))
  while @stdio.stdin.read_some(max_len=(limit - output.length() + 1).min(8_192))
        is Some(chunk) {
    guard output.length() + chunk.length() <= limit else {
      fail("recovery inspection request exceeds byte limit")
    }
    output.write_bytes(chunk)
  }
  @utf8.decode(output.to_bytes())
}

///|
fn refused_response(
  code : String,
  message : String,
) -> @trusted_executor.RetentionRecoveryInspectionResponse {
  {
    protocol_version: 4,
    retention_id: "",
    workspace_id: "",
    profile_digest: "",
    approval_digest: "",
    command_digest: "",
    destination_path: "",
    reviewed_state_digest: "",
    desired_state_digest: "",
    observed_state_digest: "",
    outcome: "unavailable",
    error: Some({ code, message }),
  }
}

///|
async fn main {
  let response = match @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") {
    None =>
      refused_response(
        "configuration-refused", "recovery inspection configuration is unavailable",
      )
    Some(config_path) => {
      let config = @trusted_executor.load_executor_config(config_path) catch {
        _ => {
          @stdio.stdout.write(
            refused_response(
              "configuration-refused", "recovery inspection configuration could not be verified",
            )
            .to_json()
            .stringify() +
            "\n",
          )
          return
        }
      }
      let request : @trusted_executor.RetentionRecoveryInspectionRequest = @json.from_json(
        @json.parse(bounded_stdin(config.limits.max_protocol_bytes)),
      ) catch {
        _ => {
          @stdio.stdout.write(
            refused_response(
              "protocol-refused", "recovery inspection request is invalid or oversized",
            )
            .to_json()
            .stringify() +
            "\n",
          )
          return
        }
      }
      @trusted_executor.inspect_retention_recovery(request, config)
    }
  }
  @stdio.stdout.write(response.to_json().stringify() + "\n")
}
