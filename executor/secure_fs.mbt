///|
#borrow(path)
extern "c" fn secure_path_native(
  path : Bytes,
  length : Int,
  policy : Int,
) -> Bool = "moonfort_secure_path"

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
fn trusted_directory(path : String) -> Bool {
  secure_path(path, 3)
}

///|
fn trusted_executable(path : String) -> Bool {
  secure_path(path, 4)
}
