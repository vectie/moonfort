///|
/// Concrete AgentENV transport built on `moonbitlang/async/http`. The base URL
/// is fixed at construction and redirects are not implemented by this HTTP
/// client path, so control/data-plane requests stay on the configured origin.
pub struct AenHttpTransport {
  base_url : String
}

///|
fn canonical_port(value : StringView) -> Bool {
  if value == "" ||
    !value.all(character => character >= '0' && character <= '9') {
    return false
  }
  let port = @string.parse_int(value) catch { _ => return false }
  port >= 1 && port <= 65_535 && value.to_owned() == port.to_string()
}

///|
fn loopback_http_origin(value : String) -> Bool {
  for origin in ["http://localhost", "http://127.0.0.1", "http://[::1]"] {
    if value == origin {
      return true
    }
    let prefix = "\{origin}:"
    if value.has_prefix(prefix) && canonical_port(value[prefix.length():]) {
      return true
    }
  }
  false
}

///|
pub fn AenHttpTransport::new(
  base_url : String,
) -> AenHttpTransport raise AenBackendError {
  let base_url = for value = base_url; value.length() > 0 &&
                    value.has_suffix("/"); {
    continue value[:value.length() - 1].to_owned()
  } nobreak {
    value
  }
  let secure_origin = if base_url.has_prefix("https://") {
    let authority = base_url[8:]
    authority != "" &&
    !authority.contains("/") &&
    !authority.contains("?") &&
    !authority.contains("#") &&
    !authority.contains("@")
  } else {
    false
  }
  guard secure_origin || loopback_http_origin(base_url) else {
    raise InvalidConfiguration(
      "AEN base URL must be an HTTPS origin or canonical HTTP loopback origin",
    )
  }
  { base_url, }
}

///|
fn request_headers(headers : Array[AenHeader]) -> Map[String, String] {
  Map::from_array([ for header in headers => (header.name, header.value) ])
}

///|
fn request_bytes(body : AenRequestBody) -> Bytes {
  match body {
    EmptyBody => b""
    JsonBody(value) => @utf8.encode(value.stringify())
    ProtobufBody(value) | ConnectBody(value) => value
  }
}

///|
fn http_method(verb : AenHttpMethod) -> @http.RequestMethod {
  match verb {
    Get => Get
    Post => Post
    Put => Put
    Delete => Delete
  }
}

///|
async fn AenHttpTransport::open(
  self : AenHttpTransport,
  request : AenRequest,
) -> (@http.Response, @http.Client) {
  let client = @http.Client(self.base_url)
  try {
    client.request(
      http_method(request.verb),
      request.path,
      extra_headers=request_headers(request.headers),
    )
    let bytes = request_bytes(request.body)
    if bytes.length() > 0 {
      client.write(bytes)
    }
    let response = client.end_request()
    (response, client)
  } catch {
    error => {
      client.close()
      raise error
    }
  }
}

///|
async fn read_capped(client : @http.Client, cap : Int) -> Bytes {
  guard cap > 0 else {
    raise InvalidConfiguration("response byte limit must be positive")
  }
  let out = @buffer.Buffer(size_hint=cap.min(8_192))
  while client.read_some(max_len=(cap - out.length() + 1).min(8_192))
        is Some(chunk) {
    guard out.length() + chunk.length() <= cap else {
      raise TransportFailure("AgentENV response exceeded the byte limit")
    }
    out.write_bytes(chunk)
  }
  out.to_bytes()
}

///|
pub impl AenTransport for AenHttpTransport with fn request(self, request) {
  let timeout_ms = request.timeout_ms
  guard timeout_ms > 0 else {
    raise InvalidConfiguration("transport timeout must be positive")
  }
  match
    @async.with_timeout_opt(timeout_ms, () => {
      let (response, client) = self.open(request)
      defer client.close()
      let body = read_capped(client, request.response_bytes)
      { status: response.code, body }
    }) {
    Some(response) => response
    None => raise TransportFailure("AgentENV request timed out")
  }
}

///|
pub impl AenTransport for AenHttpTransport with fn stream(
  self,
  request,
  consume~,
) {
  let timeout_ms = request.timeout_ms
  guard timeout_ms > 0 else {
    raise InvalidConfiguration("transport timeout must be positive")
  }
  let completed = @async.with_timeout_opt(timeout_ms, () => {
    let (response, client) = self.open(request)
    defer client.close()
    guard response.code >= 200 && response.code < 300 else {
      ignore(read_capped(client, request.response_bytes))
      raise TransportFailure("AgentENV stream returned HTTP \{response.code}")
    }
    let mut received = 0
    while client.read_some(max_len=8_192) is Some(chunk) {
      received += chunk.length()
      guard received <= request.response_bytes else {
        raise TransportFailure("AgentENV stream exceeded the byte limit")
      }
      if consume(chunk) is StopStream {
        return
      }
    }
  })
  guard completed is Some(_) else {
    raise TransportFailure("AgentENV stream timed out")
  }
}
