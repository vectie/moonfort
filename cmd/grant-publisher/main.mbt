///|
async fn bounded_stdin(limit : Int) -> String {
  guard limit > 0 && limit <= 1_048_576 else { fail("invalid input limit") }
  let output = @buffer.Buffer(size_hint=limit.min(8_192))
  while @stdio.stdin.read_some(max_len=(limit - output.length() + 1).min(8_192))
        is Some(chunk) {
    guard output.length() + chunk.length() <= limit else {
      fail("publication request exceeds byte limit")
    }
    output.write_bytes(chunk)
  }
  @utf8.decode(output.to_bytes())
}

///|
async fn main {
  let config_path = match @env.get_env_var("MOONFORT_EXECUTOR_CONFIG") {
    Some(value) => value
    None => {
      let response : @trusted_executor.GrantPublicationResponse = {
        protocol_version: 3,
        approval_id: "",
        approval_digest: "",
        published: false,
        error: Some({
          code: "configuration-refused",
          message: "publisher configuration is unavailable",
        }),
      }
      @stdio.stdout.write(response.to_json().stringify() + "\n")
      return
    }
  }
  let config = @trusted_executor.load_executor_config(config_path) catch {
    _ => {
      let response : @trusted_executor.GrantPublicationResponse = {
        protocol_version: 3,
        approval_id: "",
        approval_digest: "",
        published: false,
        error: Some({
          code: "configuration-refused",
          message: "publisher configuration could not be verified",
        }),
      }
      @stdio.stdout.write(response.to_json().stringify() + "\n")
      return
    }
  }
  let request : @trusted_executor.GrantPublicationRequest = @json.from_json(
    @json.parse(bounded_stdin(config.limits.max_protocol_bytes)),
  ) catch {
    _ => {
      let response : @trusted_executor.GrantPublicationResponse = {
        protocol_version: 3,
        approval_id: "",
        approval_digest: "",
        published: false,
        error: Some({
          code: "protocol-refused",
          message: "publication request is invalid or oversized",
        }),
      }
      @stdio.stdout.write(response.to_json().stringify() + "\n")
      return
    }
  }
  let response = @trusted_executor.publish_grant(request, config)
  @stdio.stdout.write(response.to_json().stringify() + "\n")
}
