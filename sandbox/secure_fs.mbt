///|
#borrow(root)
extern "c" fn secure_clear_directory_native(
  root : Bytes,
  root_length : Int,
) -> Int = "moonfort_secure_clear_directory"

///|
#borrow(root)
extern "c" fn secure_discard_tree_native(
  root : Bytes,
  root_length : Int,
) -> Int = "moonfort_secure_discard_tree"

///|
#borrow(path)
extern "c" fn sandbox_private_directory_native(
  path : Bytes,
  path_length : Int,
) -> Bool = "moonfort_sandbox_private_directory"

///|
fn sandbox_private_directory(path : String) -> Bool {
  let encoded = @utf8.encode(path)
  sandbox_private_directory_native(encoded, encoded.length())
}

///|
#borrow(sr, sp, dr, dp, hash, destination_hash)
extern "c" fn secure_promote_regular_native(
  sr : Bytes,
  sr_length : Int,
  sp : Bytes,
  sp_length : Int,
  dr : Bytes,
  dr_length : Int,
  dp : Bytes,
  dp_length : Int,
  expected_size : Int64,
  hash : Bytes,
  hash_length : Int,
  destination_kind : Int,
  destination_size : Int64,
  destination_hash : Bytes,
  destination_hash_length : Int,
) -> Int = "moonfort_secure_promote_regular"

///|
#borrow(root, path, state)
extern "c" fn secure_destination_state_native(
  root : Bytes,
  root_length : Int,
  path : Bytes,
  path_length : Int,
  state : Bytes,
  state_length : Int,
) -> Int = "moonfort_secure_destination_state"

///|
priv enum SecureDestinationState {
  SecureDestinationAbsent
  SecureDestinationRegular(size_bytes~ : Int64, fingerprint~ : String)
  SecureDestinationError(Int)
}

///|
fn secure_fs_status_code(status : Int) -> String {
  match status {
    0 => "ok"
    1 => "invalid-path"
    2 => "source-changed-or-unsafe"
    3 => "destination-changed-or-unsafe"
    4 => "io"
    5 => "unsupported-entry"
    _ => "native-protocol"
  }
}

///|
fn secure_clear_directory(root : String) -> Int {
  let bytes = @utf8.encode(root)
  secure_clear_directory_native(bytes, bytes.length())
}

///|
fn secure_discard_tree(root : String) -> Int {
  let bytes = @utf8.encode(root)
  secure_discard_tree_native(bytes, bytes.length())
}

///|
fn secure_destination_state(
  destination_root : String,
  destination_path : String,
) -> SecureDestinationState {
  let root = @utf8.encode(destination_root)
  let path = @utf8.encode(destination_path)
  let state = Bytes::new(72)
  let status = secure_destination_state_native(
    root,
    root.length(),
    path,
    path.length(),
    state,
    state.length(),
  )
  if status == 0 {
    SecureDestinationAbsent
  } else if status == 6 {
    let mut size = 0L
    for index in 0..<8 {
      size = (size << 8) | state[index].to_int().to_int64()
    }
    let fingerprint = @utf8.decode(state[8:72]) catch {
      _ => return SecureDestinationError(1)
    }
    SecureDestinationRegular(size_bytes=size, fingerprint~)
  } else {
    SecureDestinationError(status)
  }
}

///|
fn secure_promote_regular(
  source_root : String,
  source_path : String,
  destination_root : String,
  destination_path : String,
  expected_size : Int64,
  expected_fingerprint : String,
  expected_destination_kind : Int,
  expected_destination_size : Int64,
  expected_destination_fingerprint : String,
) -> Int {
  let source_root = @utf8.encode(source_root)
  let source_path = @utf8.encode(source_path)
  let destination_root = @utf8.encode(destination_root)
  let destination_path = @utf8.encode(destination_path)
  let expected_fingerprint = @utf8.encode(expected_fingerprint)
  let expected_destination_fingerprint = @utf8.encode(
    expected_destination_fingerprint,
  )
  secure_promote_regular_native(
    source_root,
    source_root.length(),
    source_path,
    source_path.length(),
    destination_root,
    destination_root.length(),
    destination_path,
    destination_path.length(),
    expected_size,
    expected_fingerprint,
    expected_fingerprint.length(),
    expected_destination_kind,
    expected_destination_size,
    expected_destination_fingerprint,
    expected_destination_fingerprint.length(),
  )
}
