///|
async fn bounded_stdin(limit : Int) -> String {
  guard limit > 0 && limit <= 1_048_576 else { fail("invalid input limit") }
  let output = @buffer.Buffer(size_hint=limit.min(8_192))
  while @stdio.stdin.read_some(max_len=(limit - output.length() + 1).min(8_192))
        is Some(chunk) {
    guard output.length() + chunk.length() <= limit else {
      fail("promotion request exceeds byte limit")
    }
    output.write_bytes(chunk)
  }
  @utf8.decode(output.to_bytes())
}

///|
async fn main {
  let response = match @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") {
    None =>
      @trusted_executor.RetentionPromotionResponse::{
        protocol_version: 3,
        retention_id: "",
        workspace_id: "",
        approval_digest: "",
        command_digest: "",
        promoted_paths: [],
        completed: false,
        error: Some({
          code: "configuration-refused",
          message: "promotion configuration is unavailable",
        }),
      }
    Some(config_path) => {
      let config = @trusted_executor.load_executor_config(config_path) catch {
        _ => {
          let rejected : @trusted_executor.RetentionPromotionResponse = {
            protocol_version: 3,
            retention_id: "",
            workspace_id: "",
            approval_digest: "",
            command_digest: "",
            promoted_paths: [],
            completed: false,
            error: Some({
              code: "configuration-refused",
              message: "promotion configuration could not be verified",
            }),
          }
          @stdio.stdout.write(rejected.to_json().stringify() + "\n")
          return
        }
      }
      let request : @trusted_executor.RetentionPromotionRequest = @json.from_json(
        @json.parse(bounded_stdin(config.limits.max_protocol_bytes)),
      ) catch {
        _ => {
          let rejected : @trusted_executor.RetentionPromotionResponse = {
            protocol_version: 3,
            retention_id: "",
            workspace_id: "",
            approval_digest: "",
            command_digest: "",
            promoted_paths: [],
            completed: false,
            error: Some({
              code: "protocol-refused",
              message: "promotion request is invalid or oversized",
            }),
          }
          @stdio.stdout.write(rejected.to_json().stringify() + "\n")
          return
        }
      }
      @trusted_executor.promote_retention(request, config)
    }
  }
  @stdio.stdout.write(response.to_json().stringify() + "\n")
}
