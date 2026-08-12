///|
fn encode_watcher_path(path : String) -> Bytes {
  let request = @buffer.Buffer()
  write_string_field(request, 1, path)
  write_key(request, 2, 0)
  write_varint(request, 1)
  request.to_bytes()
}

///|
fn encode_watcher_id(id : String) -> Bytes {
  let request = @buffer.Buffer()
  write_string_field(request, 1, id)
  request.to_bytes()
}

///|
fn decode_single_string_field(
  payload : Bytes,
  expected_field : Int,
) -> String raise AenBackendError {
  let bytes = payload[:]
  let mut index = 0
  while index < bytes.length() {
    let (key, after_key) = read_varint(bytes, index)
    let field = key >> 3
    let wire = key & 7
    if field == expected_field && wire == 2 {
      let (value, _) = read_bytes(bytes, after_key)
      return @utf8.decode(value) catch {
        _ => raise ProtocolFailure("envd filesystem response is not UTF-8")
      }
    }
    index = skip_field(bytes, after_key, wire)
  }
  raise ProtocolFailure(
    "envd filesystem response omitted field \{expected_field}",
  )
}

///|
fn decode_filesystem_event(payload : Bytes) -> String? raise AenBackendError {
  let bytes = payload[:]
  let mut index = 0
  while index < bytes.length() {
    let (key, after_key) = read_varint(bytes, index)
    let field = key >> 3
    let wire = key & 7
    if field == 1 && wire == 2 {
      let (value, next) = read_bytes(bytes, after_key)
      index = next
      return Some(
        @utf8.decode(value) catch {
          _ => raise ProtocolFailure("envd watcher path is not UTF-8")
        },
      )
    }
    index = skip_field(bytes, after_key, wire)
  }
  None
}

///|
fn decode_watcher_events(
  payload : Bytes,
) -> Array[String] raise AenBackendError {
  let bytes = payload[:]
  let mut index = 0
  let paths : Array[String] = []
  while index < bytes.length() {
    let (key, after_key) = read_varint(bytes, index)
    let field = key >> 3
    let wire = key & 7
    if field == 1 && wire == 2 {
      let (event, next) = read_bytes(bytes, after_key)
      index = next
      match decode_filesystem_event(event) {
        Some(path) => {
          guard paths.length() < 4_096 else {
            raise ProtocolFailure("envd watcher event count exceeded 4096")
          }
          guard path.length() <= 4_096 else {
            raise ProtocolFailure("envd watcher path exceeded 4096 bytes")
          }
          paths.push(path)
        }
        None => ()
      }
    } else {
      index = skip_field(bytes, after_key, wire)
    }
  }
  paths
}
