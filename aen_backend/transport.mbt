///|
fn control_headers(api_key : String) -> Array[AenHeader] {
  [
    { name: "X-API-Key", value: api_key },
    { name: "Content-Type", value: "application/json" },
  ]
}

///|
fn envd_headers(
  api_key : String,
  sandbox_id : String,
  content_type : String,
) -> Array[AenHeader] {
  [
    { name: "X-API-Key", value: api_key },
    { name: "x-agentenv-sandbox-id", value: sandbox_id },
    { name: "x-agentenv-target-port", value: "49983" },
    { name: "Connect-Protocol-Version", value: "1" },
    { name: "Content-Type", value: content_type },
  ]
}

///|
fn control_request(
  api_key : String,
  verb : AenHttpMethod,
  path : String,
  body? : Json,
  timeout_ms~ : Int,
  response_bytes? : Int = 1_048_576,
) -> AenRequest {
  {
    verb,
    path,
    headers: control_headers(api_key),
    body: match body {
      Some(value) => JsonBody(value)
      None => EmptyBody
    },
    timeout_ms,
    response_bytes,
  }
}

///|
fn envd_start_request(
  api_key : String,
  sandbox_id : String,
  payload : Bytes,
  timeout_ms : Int,
  response_bytes : Int,
) -> AenRequest {
  {
    verb: Post,
    path: "/process.Process/Start",
    headers: envd_headers(api_key, sandbox_id, "application/connect+proto"),
    body: ConnectBody(connect_envelope(0x00, payload)),
    timeout_ms,
    response_bytes,
  }
}

///|
fn envd_signal_request(
  api_key : String,
  sandbox_id : String,
  pid : Int,
  timeout_ms : Int,
) -> AenRequest {
  {
    verb: Post,
    path: "/process.Process/SendSignal",
    headers: envd_headers(api_key, sandbox_id, "application/proto"),
    body: ProtobufBody(encode_send_signal_request(pid, 9)),
    timeout_ms,
    response_bytes: 65_536,
  }
}

///|
fn envd_filesystem_request(
  api_key : String,
  sandbox_id : String,
  operation : String,
  payload : Bytes,
  response_bytes? : Int = 1_048_576,
) -> AenRequest {
  {
    verb: Post,
    path: "/filesystem.Filesystem/\{operation}",
    headers: envd_headers(api_key, sandbox_id, "application/proto"),
    body: ProtobufBody(payload),
    timeout_ms: ControlTimeoutMs,
    response_bytes,
  }
}

///|
fn response_json(
  response : AenResponse,
  expected : Int,
) -> Json raise AenBackendError {
  guard response.status == expected else {
    raise TransportFailure(
      "AgentENV returned HTTP \{response.status}, expected \{expected}",
    )
  }
  @json.parse(@utf8.decode(response.body)) catch {
    _ => raise ProtocolFailure("AgentENV response is not valid UTF-8 JSON")
  }
}

///|
fn expect_status(
  response : AenResponse,
  expected : Int,
) -> Unit raise AenBackendError {
  guard response.status == expected else {
    raise TransportFailure(
      "AgentENV returned HTTP \{response.status}, expected \{expected}",
    )
  }
}

///|
fn url_segment(text : String) -> String {
  let out = StringBuilder()
  for byte in @utf8.encode(text) {
    let value = byte.to_int()
    if (value >= 'a' && value <= 'z') ||
      (value >= 'A' && value <= 'Z') ||
      (value >= '0' && value <= '9') ||
      value == '-' ||
      value == '_' ||
      value == '.' ||
      value == '~' {
      out.write_char(Int::unsafe_to_char(value))
    } else {
      let digits = "0123456789ABCDEF"
      out.write_char('%')
      out.write_char(Int::unsafe_to_char(digits[(value >> 4) & 0x0f].to_int()))
      out.write_char(Int::unsafe_to_char(digits[value & 0x0f].to_int()))
    }
  }
  out.to_string()
}
