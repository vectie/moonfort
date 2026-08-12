///|
async fn directory_is_empty(path : String) -> Bool {
  @fs.readdir(path).is_empty()
}

///|
async fn copy_snapshot_file(
  source_path : String,
  destination_path : String,
  relative_path : String,
  used_bytes : Ref[Int64],
  disk_limit_bytes : Int64,
) -> Unit {
  if !(@fs.kind(source_path, follow_symlink=false) is Regular) {
    raise ScratchScanFailure(EntryChangedDuringInventory(relative_path))
  }
  let source = @fs.open(source_path, mode=ReadOnly)
  defer source.close()
  if !(source.kind() is Regular) {
    raise ScratchScanFailure(EntryChangedDuringInventory(relative_path))
  }
  let declared_size = source.size()
  if declared_size < 0L || declared_size > disk_limit_bytes - used_bytes.val {
    raise ScratchScanFailure(
      DiskLimitExceeded(
        limit_bytes=disk_limit_bytes,
        observed_bytes=used_bytes.val + declared_size,
      ),
    )
  }
  let destination = @fs.open(
    destination_path,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  )
  defer destination.close()
  let observed : Ref[Int64] = { val: 0L }
  for ;; {
    guard source.read_some(max_len=64 * 1024) is Some(chunk) else { break }
    observed.val += chunk.length().to_int64()
    if observed.val > declared_size ||
      observed.val > disk_limit_bytes - used_bytes.val {
      raise ScratchScanFailure(
        DiskLimitExceeded(
          limit_bytes=disk_limit_bytes,
          observed_bytes=used_bytes.val + observed.val,
        ),
      )
    }
    destination.write(chunk)
  }
  if observed.val != declared_size ||
    source.size() != declared_size ||
    !(@fs.kind(source_path, follow_symlink=false) is Regular) {
    raise ScratchScanFailure(EntryChangedDuringInventory(relative_path))
  }
  used_bytes.val += observed.val
}

///|
async fn copy_snapshot_directory(
  workspace_root : String,
  scratch_root : String,
  relative_directory : String,
  used_bytes : Ref[Int64],
  disk_limit_bytes : Int64,
) -> Unit {
  let source_directory = join_scratch_path(workspace_root, relative_directory)
  if !(@fs.kind(source_directory, follow_symlink=false) is Directory) {
    raise ScratchScanFailure(EntryChangedDuringInventory(relative_directory))
  }
  for name in @fs.readdir(source_directory, sort=true) {
    if !scratch_component_is_safe(name) {
      raise ScratchScanFailure(UnsafeEntryName(name))
    }
    let relative_path = if relative_directory == "" {
      name
    } else {
      "\{relative_directory}/\{name}"
    }
    let source_path = join_scratch_path(workspace_root, relative_path)
    let destination_path = join_scratch_path(scratch_root, relative_path)
    match @fs.kind(source_path, follow_symlink=false) {
      Regular =>
        copy_snapshot_file(
          source_path, destination_path, relative_path, used_bytes, disk_limit_bytes,
        )
      Directory => {
        @fs.mkdir(destination_path, permission=0o700)
        copy_snapshot_directory(
          workspace_root, scratch_root, relative_path, used_bytes, disk_limit_bytes,
        )
      }
      SymLink =>
        raise ScratchScanFailure(
          UnsupportedEntry(path=relative_path, kind="symlink"),
        )
      other =>
        raise ScratchScanFailure(
          UnsupportedEntry(path=relative_path, kind=fs_kind_label(other)),
        )
    }
  }
  if !(@fs.kind(source_directory, follow_symlink=false) is Directory) {
    raise ScratchScanFailure(EntryChangedDuringInventory(relative_directory))
  }
}

///|
/// Materialize a private writable workspace copy. The destination must be an
/// existing empty canonical directory. Source symlinks and special files are
/// refused rather than followed. The returned inventory is the reset baseline.
pub async fn materialize_workspace_snapshot(
  workspace_root : String,
  scratch_root : String,
  disk_limit_bytes? : Int64 = 2_147_483_648L,
) -> Result[ScratchInventory, SandboxStorageRefusal] {
  if !path_is_canonical_absolute(workspace_root) ||
    !path_is_canonical_absolute(scratch_root) ||
    disk_limit_bytes <= 0L ||
    roots_overlap(workspace_root, scratch_root) {
    return Err(InvalidScratchRoot(scratch_root))
  }
  try {
    let actual_workspace = @fs.realpath(workspace_root)
    let actual_scratch = @fs.realpath(scratch_root)
    if actual_workspace != workspace_root {
      raise ScratchScanFailure(
        ScratchRootNotCanonical(
          expected=workspace_root,
          actual=actual_workspace,
        ),
      )
    }
    if actual_scratch != scratch_root {
      raise ScratchScanFailure(
        ScratchRootNotCanonical(expected=scratch_root, actual=actual_scratch),
      )
    }
    if !(@fs.kind(workspace_root, follow_symlink=false) is Directory) ||
      !(@fs.kind(scratch_root, follow_symlink=false) is Directory) ||
      !directory_is_empty(scratch_root) {
      raise ScratchScanFailure(InvalidScratchRoot(scratch_root))
    }
    let used_bytes : Ref[Int64] = { val: 0L }
    copy_snapshot_directory(
      workspace_root, scratch_root, "", used_bytes, disk_limit_bytes,
    )
    match inventory_scratch(scratch_root, disk_limit_bytes) {
      Ok(inventory) => Ok(inventory)
      Err(reason) => Err(reason)
    }
  } catch {
    error if @async.is_being_cancelled() => raise error
    ScratchScanFailure(reason) => Err(reason)
    error => Err(StorageIo("\{error}"))
  }
}

///|
fn remove_scratch_children(
  scratch_root : String,
) -> Unit raise ScratchScanFailure {
  let status = secure_clear_directory(scratch_root)
  if status != 0 {
    raise ScratchScanFailure(
      StorageIo("secure scratch clear failed: \{secure_fs_status_code(status)}"),
    )
  }
}

///|
/// Delete one canonical scratch tree without following symbolic links. The
/// exact root is removed only after every supported child has been removed.
pub fn discard_scratch_tree(
  scratch_root : String,
) -> Result[Unit, SandboxStorageRefusal] {
  if !path_is_canonical_absolute(scratch_root) {
    return Err(InvalidScratchRoot(scratch_root))
  }
  let status = secure_discard_tree(scratch_root)
  if status == 0 {
    Ok(())
  } else if status == 1 {
    Err(InvalidScratchRoot(scratch_root))
  } else {
    Err(
      StorageIo(
        "secure scratch discard failed: \{secure_fs_status_code(status)}",
      ),
    )
  }
}

///|
/// Restore scratch from the canonical read-only workspace snapshot source.
pub async fn reset_workspace_snapshot(
  workspace_root : String,
  scratch_root : String,
  disk_limit_bytes : Int64,
) -> Result[ScratchInventory, SandboxStorageRefusal] {
  try {
    remove_scratch_children(scratch_root)
    materialize_workspace_snapshot(
      workspace_root,
      scratch_root,
      disk_limit_bytes~,
    )
  } catch {
    error if @async.is_being_cancelled() => raise error
    ScratchScanFailure(reason) => Err(reason)
    error => Err(StorageIo("\{error}"))
  }
}
