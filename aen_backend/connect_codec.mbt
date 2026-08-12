///|
fn write_varint(out : @buffer.Buffer, value : Int) -> Unit {
  for remaining = value {
    if remaining < 0x80 {
      out.write_byte(remaining.to_byte())
      break
    }
    out.write_byte(((remaining & 0x7f) | 0x80).to_byte())
    continue remaining >> 7
  }
}

///|
fn write_key(out : @buffer.Buffer, field : Int, wire : Int) -> Unit {
  write_varint(out, (field << 3) | wire)
}

///|
fn write_length_delimited(
  out : @buffer.Buffer,
  field : Int,
  value : Bytes,
) -> Unit {
  write_key(out, field, 2)
  write_varint(out, value.length())
  out.write_bytes(value)
}

///|
fn write_string_field(
  out : @buffer.Buffer,
  field : Int,
  value : String,
) -> Unit {
  write_length_delimited(out, field, @utf8.encode(value))
}

///|
/// Exact protobuf encoding of envd `process.StartRequest` for a non-PTY,
/// no-stdin process. Schema: `thirdparty/envd/proto/process.proto`.
pub fn encode_start_request(
  command : String,
  args : Array[String],
  cwd : String,
) -> Bytes {
  let process = @buffer.Buffer()
  write_string_field(process, 1, command)
  for arg in args {
    write_string_field(process, 2, arg)
  }
  write_string_field(process, 4, cwd)
  let request = @buffer.Buffer()
  write_length_delimited(request, 1, process.to_bytes())
  // optional stdin=false must be present: field 4, varint zero.
  write_key(request, 4, 0)
  write_varint(request, 0)
  request.to_bytes()
}

///|
fn encode_send_signal_request(pid : Int, signal : Int) -> Bytes {
  let selector = @buffer.Buffer()
  write_key(selector, 1, 0)
  write_varint(selector, pid)
  let request = @buffer.Buffer()
  write_length_delimited(request, 1, selector.to_bytes())
  write_key(request, 2, 0)
  write_varint(request, signal)
  request.to_bytes()
}

///|
pub fn connect_envelope(flag : Int, payload : Bytes) -> Bytes {
  let out = @buffer.Buffer(size_hint=5 + payload.length())
  out.write_byte(flag.to_byte())
  let len = payload.length()
  out.write_byte((len >> 24).to_byte())
  out.write_byte((len >> 16).to_byte())
  out.write_byte((len >> 8).to_byte())
  out.write_byte(len.to_byte())
  out.write_bytes(payload)
  out.to_bytes()
}

///|
fn read_varint(
  data : BytesView,
  start : Int,
) -> (Int, Int) raise AenBackendError {
  let mut value = 0
  let mut shift = 0
  let mut index = start
  while index < data.length() && shift <= 63 {
    let byte = data[index].to_int()
    value = value | ((byte & 0x7f) << shift)
    index += 1
    if (byte & 0x80) == 0 {
      return (value, index)
    }
    shift += 7
  }
  raise ProtocolFailure("truncated or oversized protobuf varint")
}

///|
fn read_bytes(
  data : BytesView,
  start : Int,
) -> (Bytes, Int) raise AenBackendError {
  let (len, payload_start) = read_varint(data, start)
  let end = payload_start + len
  guard len >= 0 && end <= data.length() else {
    raise ProtocolFailure("truncated protobuf length-delimited field")
  }
  (data[payload_start:end].to_owned(), end)
}

///|
fn skip_field(
  data : BytesView,
  start : Int,
  wire : Int,
) -> Int raise AenBackendError {
  match wire {
    0 => read_varint(data, start).1
    1 => {
      guard start + 8 <= data.length() else {
        raise ProtocolFailure("truncated fixed64 field")
      }
      start + 8
    }
    2 => read_bytes(data, start).1
    5 => {
      guard start + 4 <= data.length() else {
        raise ProtocolFailure("truncated fixed32 field")
      }
      start + 4
    }
    _ => raise ProtocolFailure("unsupported protobuf wire type \{wire}")
  }
}

///|
fn decode_data_event(data : Bytes) -> AenExecEvent? raise AenBackendError {
  let bytes = data[:]
  let mut index = 0
  while index < bytes.length() {
    let (key, after_key) = read_varint(bytes, index)
    let field = key >> 3
    let wire = key & 7
    if wire == 2 && (field == 1 || field == 2 || field == 3) {
      let (value, next) = read_bytes(bytes, after_key)
      index = next
      return if field == 2 { Some(Stderr(value)) } else { Some(Stdout(value)) }
    }
    index = skip_field(bytes, after_key, wire)
  }
  None
}

///|
fn decode_start_event(data : Bytes) -> AenExecEvent? raise AenBackendError {
  let bytes = data[:]
  let mut index = 0
  while index < bytes.length() {
    let (key, after_key) = read_varint(bytes, index)
    let field = key >> 3
    let wire = key & 7
    if field == 1 && wire == 0 {
      let (pid, next) = read_varint(bytes, after_key)
      index = next
      return Some(ProcessStarted(pid))
    }
    index = skip_field(bytes, after_key, wire)
  }
  None
}

///|
fn decode_end_event(data : Bytes) -> AenExecEvent raise AenBackendError {
  let bytes = data[:]
  let mut index = 0
  let mut exit_code = 0
  let mut status = ""
  while index < bytes.length() {
    let (key, after_key) = read_varint(bytes, index)
    let field = key >> 3
    let wire = key & 7
    if field == 1 && wire == 0 {
      let (raw, next) = read_varint(bytes, after_key)
      exit_code = (raw >> 1) ^ -(raw & 1)
      index = next
    } else if field == 3 && wire == 2 {
      let (value, next) = read_bytes(bytes, after_key)
      status = @utf8.decode(value) catch {
        _ => raise ProtocolFailure("envd EndEvent status is not UTF-8")
      }
      index = next
    } else {
      index = skip_field(bytes, after_key, wire)
    }
  }
  ProcessExited(exit_code, status)
}

///|
/// Decode one protobuf `process.StartResponse` payload.
pub fn decode_start_response(
  payload : Bytes,
) -> AenExecEvent? raise AenBackendError {
  let bytes = payload[:]
  let mut index = 0
  while index < bytes.length() {
    let (key, after_key) = read_varint(bytes, index)
    let field = key >> 3
    let wire = key & 7
    if field == 1 && wire == 2 {
      let (process_event, next) = read_bytes(bytes, after_key)
      index = next
      let event_bytes = process_event[:]
      let mut event_index = 0
      while event_index < event_bytes.length() {
        let (event_key, after_event_key) = read_varint(event_bytes, event_index)
        let event_field = event_key >> 3
        let event_wire = event_key & 7
        if event_wire == 2 && event_field >= 1 && event_field <= 3 {
          let (event, event_next) = read_bytes(event_bytes, after_event_key)
          event_index = event_next
          return match event_field {
            1 => decode_start_event(event)
            2 => decode_data_event(event)
            3 => Some(decode_end_event(event))
            _ => None
          }
        }
        event_index = skip_field(event_bytes, after_event_key, event_wire)
      }
      return None
    }
    index = skip_field(bytes, after_key, wire)
  }
  None
}

///|
pub struct ConnectDecoder {
  priv mut pending : Array[Byte]
  priv mut ended : Bool
  priv max_frame_bytes : Int
}

///|
pub fn ConnectDecoder::new(
  max_frame_bytes? : Int = 1_048_576,
) -> ConnectDecoder {
  guard max_frame_bytes > 0 else {
    abort("Connect frame limit must be positive")
  }
  { pending: [], ended: false, max_frame_bytes }
}

///|
pub fn ConnectDecoder::ended(self : ConnectDecoder) -> Bool {
  self.ended
}

///|
pub fn ConnectDecoder::feed(
  self : ConnectDecoder,
  chunk : Bytes,
) -> Array[AenExecEvent] raise AenBackendError {
  guard !self.ended else {
    raise ProtocolFailure("Connect stream supplied bytes after end envelope")
  }
  for byte in chunk {
    self.pending.push(byte)
  }
  let events : Array[AenExecEvent] = []
  while self.pending.length() >= 5 {
    let len = (self.pending[1].to_int() << 24) |
      (self.pending[2].to_int() << 16) |
      (self.pending[3].to_int() << 8) |
      self.pending[4].to_int()
    guard len >= 0 && len <= self.max_frame_bytes else {
      raise ProtocolFailure("Connect frame exceeded the configured limit")
    }
    let total = 5 + len
    if self.pending.length() < total {
      break
    }
    let flag = self.pending[0].to_int()
    let payload = Bytes::from_array(self.pending[5:total])
    self.pending = self.pending[total:].to_owned()
    match flag {
      0x00 =>
        match decode_start_response(payload) {
          Some(event) => events.push(event)
          None => ()
        }
      0x02 => {
        let error = if payload.length() == 0 || payload == b"{}" {
          None
        } else {
          Some(@utf8.decode_lossy(payload))
        }
        events.push(ConnectEnded(error))
        self.ended = true
      }
      _ => raise ProtocolFailure("unexpected Connect envelope flag \{flag}")
    }
  }
  events
}
