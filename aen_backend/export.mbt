///|
const GuestExportFileBytes : Int = 8_388_608

///|
const GuestExportResponseBytes : Int = 11_272_192

///|
fn canonical_host_export_path(path : String) -> Bool {
  path.has_prefix("/") &&
  path != "/" &&
  !path.contains("//") &&
  !path.contains("\\") &&
  !path.contains("\u{0}") &&
  !path.split("/").any(component => component == "." || component == "..") &&
  !path.has_suffix("/")
}

///|
fn required_int64_string(
  object : Map[String, Json],
  key : String,
) -> Int64 raise AenBackendError {
  let text = required_string(object, key)
  @strconv.from_str(text) catch {
    _ => raise ProtocolFailure("guest export has an invalid \{key}")
  }
}

///|
fn required_text(
  object : Map[String, Json],
  key : String,
) -> String raise AenBackendError {
  match object.get(key) {
    Some(String(value)) => value
    _ => raise ProtocolFailure("guest export is missing text \{key}")
  }
}

///|
async fn ensure_export_parent(root : String, relative_path : String) -> String {
  let components = relative_path.split("/").collect()
  guard components.length() >= 1 else {
    raise ProtocolFailure("guest export path has no components")
  }
  let mut current = root
  for index in 0..<(components.length() - 1) {
    current = "\{current}/\{components[index]}"
    @fs.mkdir(current, permission=0o700) catch {
      _ => ()
    }
    guard @fs.kind(current, follow_symlink=false) is Directory &&
      @fs.realpath(current) == current else {
      raise ProtocolFailure("host export parent is not a canonical directory")
    }
  }
  "\{root}/\{relative_path}"
}

///|
async fn[T : AenTransport] AenBackend::export_regular_change(
  self : AenBackend[T],
  sandbox_id : String,
  entry : @sandbox.ScratchEntry,
  export_root : String,
) -> Unit {
  let destination = ensure_export_parent(export_root, entry.relative_path)
  let output = @fs.open(
    destination,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  )
  defer output.close()
  guard entry.size_bytes <= GuestExportFileBytes.to_int64() else {
    raise ProtocolFailure("changed regular file exceeds AEN export bound")
  }
  let detail = self.run_fixed_guest_json(
    sandbox_id,
    self.guest_attester,
    [
      "export-file",
      "--contract",
      GuestAttestationContract,
      "--scratch",
      self.guest_scratch,
      "--profile-digest",
      self.digest,
      "--attester-digest",
      self.guest_attester_digest,
      "--path",
      entry.relative_path,
      "--fingerprint",
      entry.fingerprint,
      "--size",
      entry.size_bytes.to_string(),
      "--max-bytes",
      GuestExportFileBytes.to_string(),
    ],
    "/",
    max_bytes=GuestExportResponseBytes,
  )
  let object = json_object(detail, "guest export")
  guard required_string(object, "contract") == GuestAttestationContract &&
    required_string(object, "profileDigest") == self.digest &&
    required_string(object, "guestAttesterDigest") == self.guest_attester_digest &&
    required_string(object, "path") == entry.relative_path &&
    required_string(object, "fingerprint") == entry.fingerprint &&
    required_int64_string(object, "size") == entry.size_bytes else {
    raise ProtocolFailure("guest export evidence does not match the diff")
  }
  let encoded = required_text(object, "payload")
  let payload = @base64.decode(encoded) catch {
    _ => raise ProtocolFailure("guest export payload is not base64")
  }
  guard @base64.encode(payload) == encoded &&
    payload.length().to_int64() == entry.size_bytes else {
    raise ProtocolFailure("guest export payload does not match its size")
  }
  if !payload.is_empty() {
    output.write(payload)
  }
  output.sync()
  guard output.size() == entry.size_bytes &&
    @fs.kind(destination, follow_symlink=false) is Regular else {
    raise ProtocolFailure("host export file did not materialize exactly")
  }
}

///|
/// Export only the post-run regular-file values named by the already verified
/// structured diff. The fixed, digest-bound guest helper revalidates the
/// expected path, size, and SHA-256 for every bounded file. Removals,
/// directories, and symbolic links remain visible in the receipt but never
/// become promotable host files.
async fn[T : AenTransport] AenBackend::materialize_guest_changes(
  self : AenBackend[T],
  sandbox_id : String,
  diff : Array[@sandbox.ScratchDiffEntry],
) -> Array[String] {
  let export_root = self.profile.scratch_root
  guard canonical_host_export_path(export_root) &&
    @fs.realpath(export_root) == export_root &&
    @fs.kind(export_root, follow_symlink=false) is Directory &&
    @fs.readdir(export_root).is_empty() else {
    raise ProtocolFailure("executor export root is not canonical and empty")
  }
  let expected : Array[@sandbox.ScratchEntry] = []
  let paths : Array[String] = []
  let mut total = 0L
  for change in diff {
    guard @sandbox.scratch_relative_path_is_safe(change.relative_path) else {
      raise ProtocolFailure("guest diff contains an unsafe export path")
    }
    match change.change {
      Removed => ()
      Added | Modified => {
        guard change.after is Some(after) &&
          after.relative_path == change.relative_path else {
          raise ProtocolFailure("guest diff omits the changed post-run entry")
        }
        match after.kind {
          RegularFile => {
            guard after.size_bytes >= 0L &&
              after.fingerprint.length() == 64 &&
              after.fingerprint.all(character => {
                (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f')
              }) &&
              after.size_bytes <=
              self.profile.limits.disk_mib.to_int64() * 1_048_576L - total else {
              raise ProtocolFailure("guest export exceeds the profile bound")
            }
            total += after.size_bytes
            expected.push(after)
            paths.push(after.relative_path)
          }
          DirectoryEntry | SymbolicLink => ()
        }
      }
    }
  }
  @async.with_timeout(
    self.profile.limits.wall_clock_ms,
    () => {
      for entry in expected {
        self.export_regular_change(sandbox_id, entry, export_root)
      }
    },
    error=ProtocolFailure("AEN export exceeded the profile wall-clock limit"),
  )
  let inventory = match
    @sandbox.inventory_scratch(
      export_root,
      self.profile.limits.disk_mib.to_int64() * 1_048_576L,
    ) {
    Ok(value) => value
    Err(_) =>
      raise ProtocolFailure("host export inventory could not be verified")
  }
  let actual_files = inventory.entries.filter(entry => entry.kind is RegularFile)
  let expected_by_path : Map[String, @sandbox.ScratchEntry] = Map([])
  let actual_by_path : Map[String, @sandbox.ScratchEntry] = Map([])
  for entry in expected {
    expected_by_path[entry.relative_path] = entry
  }
  for entry in actual_files {
    actual_by_path[entry.relative_path] = entry
  }
  guard actual_by_path == expected_by_path &&
    inventory.total_bytes == total &&
    inventory.entries.all(entry => {
      entry.kind is DirectoryEntry || expected.contains(entry)
    }) else {
    raise ProtocolFailure("host export does not exactly match the guest diff")
  }
  paths
}
