///|
#borrow(root, path, output)
extern "c" fn read_scratch_file_native(
  root : Bytes,
  root_length : Int,
  path : Bytes,
  path_length : Int,
  output : Bytes,
  output_length : Int,
) -> Int = "moonfort_read_scratch_file"

///|
/// Read one manifest-selected regular file without following path symlinks.
/// Returns bytes only when their size and SHA-256 equal the retained entry.
/// The caller supplies its byte budget; this convenience reader caps allocations
/// at 16 MiB. Larger artifacts remain listable but need another delivery route.
pub fn read_scratch_artifact(
  root : String,
  entry : ScratchEntry,
  max_bytes : Int,
) -> Bytes raise {
  guard path_is_canonical_absolute(root) &&
    scratch_relative_path_is_safe(entry.relative_path) &&
    entry.kind is RegularFile &&
    entry.size_bytes >= 0L &&
    max_bytes > 0 &&
    entry.size_bytes <= max_bytes.to_int64() &&
    entry.size_bytes <= 16_777_216L else {
    fail("artifact is invalid or exceeds the read budget")
  }
  let root = @utf8.encode(root)
  let path = @utf8.encode(entry.relative_path)
  let bytes = Bytes::make(entry.size_bytes.to_int(), 0)
  guard read_scratch_file_native(
      root,
      root.length(),
      path,
      path.length(),
      bytes,
      bytes.length(),
    ) ==
    0 &&
    @crypto.bytes_to_hex_string(@crypto.sha256(bytes)) == entry.fingerprint else {
    fail("artifact is unavailable or differs from its retained fingerprint")
  }
  bytes
}
