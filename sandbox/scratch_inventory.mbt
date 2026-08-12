///|
/// Entry kinds are obtained with `follow_symlink=false`. Symbolic links are
/// recorded as links and are never traversed or opened by inventorying.
pub(all) enum ScratchEntryKind {
  RegularFile
  DirectoryEntry
  SymbolicLink
} derive(Debug, Eq, ToJson, FromJson)

///|
/// All paths in an inventory are normalized paths relative to the scratch
/// root. Host scratch paths never appear in snapshots, diffs, or artifacts.
pub(all) struct ScratchEntry {
  relative_path : String
  kind : ScratchEntryKind
  size_bytes : Int64
  fingerprint : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ScratchInventory {
  entries : Array[ScratchEntry]
  total_bytes : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxStorageRefusal {
  InvalidScratchRoot(String)
  ScratchRootNotCanonical(expected~ : String, actual~ : String)
  UnsafeEntryName(String)
  UnsupportedEntry(path~ : String, kind~ : String)
  EntryChangedDuringInventory(String)
  DiskLimitExceeded(limit_bytes~ : Int64, observed_bytes~ : Int64)
  StorageIo(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
priv suberror ScratchScanFailure {
  ScratchScanFailure(SandboxStorageRefusal)
}

///|
pub fn SandboxStorageRefusal::code(self : SandboxStorageRefusal) -> String {
  match self {
    InvalidScratchRoot(_) => "invalid-scratch-root"
    ScratchRootNotCanonical(..) => "scratch-root-not-canonical"
    UnsafeEntryName(_) => "unsafe-entry-name"
    UnsupportedEntry(..) => "unsupported-entry"
    EntryChangedDuringInventory(_) => "entry-changed-during-inventory"
    DiskLimitExceeded(..) => "disk-limit-exceeded"
    StorageIo(_) => "storage-io"
  }
}

///|
pub fn scratch_relative_path_is_safe(path : String) -> Bool {
  path != "" &&
  !path.has_prefix("/") &&
  !path.has_suffix("/") &&
  !path.contains("\\") &&
  !path.contains("\u{0}") &&
  path
  .split("/")
  .all(component => component != "" && component != "." && component != "..")
}

///|
fn scratch_component_is_safe(component : String) -> Bool {
  component != "" &&
  component != "." &&
  component != ".." &&
  !component.contains("/") &&
  !component.contains("\\") &&
  !component.contains("\u{0}")
}

///|
fn copy_scratch_inventory(inventory : ScratchInventory) -> ScratchInventory {
  { entries: inventory.entries.copy(), total_bytes: inventory.total_bytes }
}

///|
fn fs_kind_label(kind : @fs.FileKind) -> String {
  match kind {
    Regular => "regular-file"
    Directory => "directory"
    SymLink => "symlink"
    Socket => "socket"
    Pipe => "pipe"
    BlockDevice => "block-device"
    CharDevice => "char-device"
    Unknown => "unknown"
  }
}

///|
fn join_scratch_path(root : String, relative_path : String) -> String {
  if relative_path == "" {
    root
  } else {
    "\{root}/\{relative_path}"
  }
}

///|
async fn regular_file_entry(
  absolute_path : String,
  relative_path : String,
  used_bytes : Ref[Int64],
  disk_limit_bytes : Int64,
) -> ScratchEntry {
  let before = @fs.kind(absolute_path, follow_symlink=false)
  if !(before is Regular) {
    raise ScratchScanFailure(EntryChangedDuringInventory(relative_path))
  }
  let file = @fs.open(absolute_path, mode=ReadOnly)
  defer file.close()
  if !(file.kind() is Regular) ||
    !(@fs.kind(absolute_path, follow_symlink=false) is Regular) {
    raise ScratchScanFailure(EntryChangedDuringInventory(relative_path))
  }
  let declared_size = file.size()
  if declared_size < 0L || declared_size > disk_limit_bytes - used_bytes.val {
    let observed = if declared_size < 0L {
      used_bytes.val
    } else {
      used_bytes.val + declared_size
    }
    raise ScratchScanFailure(
      DiskLimitExceeded(limit_bytes=disk_limit_bytes, observed_bytes=observed),
    )
  }
  let hasher = @crypto.SHA256::new()
  let observed : Ref[Int64] = { val: 0L }
  for ;; {
    guard file.read_some(max_len=64 * 1024) is Some(chunk) else { break }
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
    hasher.update(chunk)
  }
  if observed.val != declared_size ||
    file.size() != declared_size ||
    !(@fs.kind(absolute_path, follow_symlink=false) is Regular) {
    raise ScratchScanFailure(EntryChangedDuringInventory(relative_path))
  }
  used_bytes.val += declared_size
  {
    relative_path,
    kind: RegularFile,
    size_bytes: declared_size,
    fingerprint: @crypto.bytes_to_hex_string(hasher.finalize()),
  }
}

///|
async fn scan_scratch_directory(
  root : String,
  relative_directory : String,
  entries : Array[ScratchEntry],
  used_bytes : Ref[Int64],
  disk_limit_bytes : Int64,
) -> Unit {
  let absolute_directory = join_scratch_path(root, relative_directory)
  if !(@fs.kind(absolute_directory, follow_symlink=false) is Directory) {
    raise ScratchScanFailure(
      EntryChangedDuringInventory(
        if relative_directory == "" {
          "."
        } else {
          relative_directory
        },
      ),
    )
  }
  let children = @fs.readdir(absolute_directory, sort=true)
  for child in children {
    if !scratch_component_is_safe(child) {
      raise ScratchScanFailure(UnsafeEntryName(child))
    }
    let relative_path = if relative_directory == "" {
      child
    } else {
      "\{relative_directory}/\{child}"
    }
    let absolute_path = join_scratch_path(root, relative_path)
    let kind = @fs.kind(absolute_path, follow_symlink=false)
    match kind {
      Regular =>
        entries.push(
          regular_file_entry(
            absolute_path, relative_path, used_bytes, disk_limit_bytes,
          ),
        )
      Directory => {
        entries.push({
          relative_path,
          kind: DirectoryEntry,
          size_bytes: 0L,
          fingerprint: "directory",
        })
        scan_scratch_directory(
          root, relative_path, entries, used_bytes, disk_limit_bytes,
        )
      }
      SymLink => {
        let (mtime_seconds, mtime_nanos) = @fs.mtime(
          absolute_path,
          follow_symlink=false,
        )
        let (ctime_seconds, ctime_nanos) = @fs.ctime(
          absolute_path,
          follow_symlink=false,
        )
        entries.push({
          relative_path,
          kind: SymbolicLink,
          size_bytes: 0L,
          fingerprint: "link:\{mtime_seconds}:\{mtime_nanos}:\{ctime_seconds}:\{ctime_nanos}",
        })
      }
      other =>
        raise ScratchScanFailure(
          UnsupportedEntry(path=relative_path, kind=fs_kind_label(other)),
        )
    }
  }
  if !(@fs.kind(absolute_directory, follow_symlink=false) is Directory) {
    raise ScratchScanFailure(
      EntryChangedDuringInventory(
        if relative_directory == "" {
          "."
        } else {
          relative_directory
        },
      ),
    )
  }
}

///|
/// Inventory a canonical scratch root without traversing symbolic links.
/// Regular-file bytes are hashed incrementally and accounting stops at the
/// supplied hard limit before accepting an oversized inventory.
pub async fn inventory_scratch(
  scratch_root : String,
  disk_limit_bytes : Int64,
) -> Result[ScratchInventory, SandboxStorageRefusal] {
  if !path_is_canonical_absolute(scratch_root) || disk_limit_bytes <= 0L {
    return Err(InvalidScratchRoot(scratch_root))
  }
  try {
    let actual_root = @fs.realpath(scratch_root)
    if actual_root != scratch_root {
      raise ScratchScanFailure(
        ScratchRootNotCanonical(expected=scratch_root, actual=actual_root),
      )
    }
    if !(@fs.kind(scratch_root, follow_symlink=false) is Directory) {
      raise ScratchScanFailure(InvalidScratchRoot(scratch_root))
    }
    let entries : Array[ScratchEntry] = []
    let used_bytes : Ref[Int64] = { val: 0L }
    scan_scratch_directory(
      scratch_root, "", entries, used_bytes, disk_limit_bytes,
    )
    entries.sort_by_key(entry => entry.relative_path)
    Ok({ entries, total_bytes: used_bytes.val })
  } catch {
    error if @async.is_being_cancelled() => raise error
    ScratchScanFailure(reason) => Err(reason)
    error => Err(StorageIo("\{error}"))
  }
}
