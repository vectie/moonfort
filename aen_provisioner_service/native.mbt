///|
#borrow(source, staging, artifacts, repository, lease)
extern "c" fn secure_snapshot_native(
  source : Bytes,
  source_len : Int,
  staging : Bytes,
  staging_len : Int,
  artifacts : Bytes,
  artifacts_len : Int,
  repository : Bytes,
  repository_len : Int,
  lease : Bytes,
  lease_len : Int,
  max_bytes : Int64,
  max_entries : Int,
  max_file_bytes : Int64,
  timeout_ms : Int,
) -> Bytes = "moonfort_aen_provisioner_snapshot"

///|
#borrow(root, lease, body)
extern "c" fn write_lease_native(
  root : Bytes,
  root_len : Int,
  lease : Bytes,
  lease_len : Int,
  body : Bytes,
  body_len : Int,
) -> Int = "moonfort_aen_provisioner_write_lease"

///|
#borrow(root, lease)
extern "c" fn release_lease_native(
  root : Bytes,
  root_len : Int,
  lease : Bytes,
  lease_len : Int,
) -> Int = "moonfort_aen_provisioner_release_lease"

///|
#borrow(path)
extern "c" fn read_protected_config_native(
  path : Bytes,
  path_len : Int,
  max_bytes : Int,
) -> Bytes = "moonfort_aen_provisioner_read_protected_config"

///|
fn secure_snapshot(
  source : String,
  staging : String,
  artifacts : String,
  repository : String,
  lease : String,
  max_bytes : Int64,
  max_entries : Int,
  max_file_bytes : Int64,
  timeout_ms : Int,
) -> ProvisionedWorkspace raise ProvisionerError {
  let source_bytes = @utf8.encode(source)
  let staging_bytes = @utf8.encode(staging)
  let artifact_bytes = @utf8.encode(artifacts)
  let repository_bytes = @utf8.encode(repository)
  let lease_bytes = @utf8.encode(lease)
  let result = secure_snapshot_native(
    source_bytes,
    source_bytes.length(),
    staging_bytes,
    staging_bytes.length(),
    artifact_bytes,
    artifact_bytes.length(),
    repository_bytes,
    repository_bytes.length(),
    lease_bytes,
    lease_bytes.length(),
    max_bytes,
    max_entries,
    max_file_bytes,
    timeout_ms,
  )
  let text = @utf8.decode(result) catch {
    _ =>
      raise StorageFailure("native snapshot helper returned non-UTF-8 output")
  }
  let value = @json.parse(text) catch {
    _ => raise StorageFailure("native snapshot helper returned invalid output")
  }
  guard value is { "ok": True, "result": result, .. } else {
    let reason = match value {
      { "error": String(message), .. } => message
      _ => "native snapshot helper refused the workspace"
    }
    raise StorageFailure(reason)
  }
  @json.from_json(result) catch {
    _ => raise StorageFailure("native snapshot result is malformed")
  }
}

///|
fn write_lease(root : String, lease : String, body : String) -> Bool {
  let root = @utf8.encode(root)
  let lease = @utf8.encode(lease)
  let body = @utf8.encode(body)
  write_lease_native(
    root,
    root.length(),
    lease,
    lease.length(),
    body,
    body.length(),
  ) ==
  0
}

///|
fn release_lease(root : String, lease : String) -> Int {
  let root = @utf8.encode(root)
  let lease = @utf8.encode(lease)
  release_lease_native(root, root.length(), lease, lease.length())
}

///|
fn read_protected_config(path : String, max_bytes : Int) -> Bytes {
  let path = @utf8.encode(path)
  read_protected_config_native(path, path.length(), max_bytes)
}
