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
#borrow(sr, sp, dr, dp, hash)
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
) -> Int = "moonfort_secure_promote_regular"

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
fn secure_promote_regular(
  source_root : String,
  source_path : String,
  destination_root : String,
  destination_path : String,
  expected_size : Int64,
  expected_fingerprint : String,
) -> Int {
  let source_root = @utf8.encode(source_root)
  let source_path = @utf8.encode(source_path)
  let destination_root = @utf8.encode(destination_root)
  let destination_path = @utf8.encode(destination_path)
  let expected_fingerprint = @utf8.encode(expected_fingerprint)
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
  )
}
