///|
#borrow(path)
extern "c" fn secure_path_native(
  path : Bytes,
  length : Int,
  policy : Int,
) -> Bool = "moonfort_secure_path"

///|
#borrow(path)
extern "c" fn sync_directory_native(path : Bytes, length : Int) -> Int = "moonfort_sync_directory"

///|
#borrow(path, identity)
extern "c" fn directory_identity_native(
  path : Bytes,
  length : Int,
  identity : Bytes,
  identity_length : Int,
) -> Int = "moonfort_directory_identity"

///|
fn secure_path(path : String, policy : Int) -> Bool {
  let encoded = @utf8.encode(path)
  secure_path_native(encoded, encoded.length(), policy)
}

///|
fn protected_regular_file(path : String) -> Bool {
  secure_path(path, 1)
}

///|
fn private_directory(path : String) -> Bool {
  secure_path(path, 2)
}

///|
fn sync_private_directory(path : String) -> Bool {
  let encoded = @utf8.encode(path)
  sync_directory_native(encoded, encoded.length()) == 0
}

///|
fn directory_identity(path : String) -> String? {
  let encoded = @utf8.encode(path)
  let identity = Bytes::make(16, 0)
  if directory_identity_native(
      encoded,
      encoded.length(),
      identity,
      identity.length(),
    ) ==
    0 {
    Some(@crypto.bytes_to_hex_string(identity))
  } else {
    None
  }
}

///|
fn trusted_directory(path : String) -> Bool {
  secure_path(path, 3)
}

///|
fn trusted_executable(path : String) -> Bool {
  secure_path(path, 4)
}
