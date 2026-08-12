///|
pub(all) struct SandboxArtifact {
  relative_path : String
  size_bytes : Int64
  fingerprint : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxArtifactRefusal {
  UnsafeArtifactPath(String)
  ArtifactNotFound(String)
  ArtifactNotRegularFile(path~ : String, kind~ : ScratchEntryKind)
  DuplicateArtifactPath(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn SandboxArtifactRefusal::code(self : SandboxArtifactRefusal) -> String {
  match self {
    UnsafeArtifactPath(_) => "unsafe-artifact-path"
    ArtifactNotFound(_) => "artifact-not-found"
    ArtifactNotRegularFile(..) => "artifact-not-regular-file"
    DuplicateArtifactPath(_) => "duplicate-artifact-path"
  }
}

///|
fn find_scratch_entry(
  inventory : ScratchInventory,
  relative_path : String,
) -> ScratchEntry? {
  match
    inventory.entries.search_by(entry => entry.relative_path == relative_path) {
    Some(index) => Some(inventory.entries[index])
    None => None
  }
}

///|
/// Convert explicit relative paths into artifact references. Directories,
/// symlinks, absolute paths, and traversal paths are refused.
pub fn declare_sandbox_artifacts(
  inventory : ScratchInventory,
  relative_paths : Array[String],
) -> Result[Array[SandboxArtifact], SandboxArtifactRefusal] {
  let seen : Map[String, Unit] = Map([])
  let artifacts : Array[SandboxArtifact] = []
  for relative_path in relative_paths {
    if !scratch_relative_path_is_safe(relative_path) {
      return Err(UnsafeArtifactPath(relative_path))
    }
    if seen.contains(relative_path) {
      return Err(DuplicateArtifactPath(relative_path))
    }
    seen[relative_path] = ()
    guard find_scratch_entry(inventory, relative_path) is Some(entry) else {
      return Err(ArtifactNotFound(relative_path))
    }
    if !(entry.kind is RegularFile) {
      return Err(ArtifactNotRegularFile(path=relative_path, kind=entry.kind))
    }
    artifacts.push({
      relative_path,
      size_bytes: entry.size_bytes,
      fingerprint: entry.fingerprint,
    })
  }
  Ok(artifacts)
}

///|
/// Promotion is always an explicit per-file mapping.
pub(all) struct SandboxPromotionRequest {
  artifact_path : String
  destination_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxPromotionDestinationState {
  ReviewedDestinationAbsent
  ReviewedDestinationRegular(size_bytes~ : Int64, fingerprint~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxPromotionItem {
  source_relative_path : String
  destination_relative_path : String
  expected_source_fingerprint : String
  size_bytes : Int64
  expected_destination_state : SandboxPromotionDestinationState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub struct SandboxPromotionPlan {
  destination_root : String
  items : Array[SandboxPromotionItem]
} derive(Debug, Eq)

///|
pub(all) enum SandboxPromotionRefusal {
  EmptyPromotionPlan
  MultiplePromotionItems(Int)
  UnsafeSourcePath(String)
  UnsafeDestinationPath(String)
  SourceNotFound(String)
  SourceNotRegularFile(path~ : String, kind~ : ScratchEntryKind)
  DuplicateDestinationPath(String)
  DestinationRootNotCanonical(expected~ : String, actual~ : String)
  DestinationRootInvalid(String)
  DestinationSymlink(String)
  DestinationParentNotDirectory(String)
  DestinationIsDirectory(String)
  DestinationUnsupported(path~ : String, kind~ : String)
  DestinationStateChanged(String)
  SourceFingerprintMismatch(String)
  DestinationIo(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn SandboxPromotionRefusal::code(self : SandboxPromotionRefusal) -> String {
  match self {
    EmptyPromotionPlan => "empty-promotion-plan"
    MultiplePromotionItems(_) => "multiple-promotion-items"
    UnsafeSourcePath(_) => "unsafe-source-path"
    UnsafeDestinationPath(_) => "unsafe-destination-path"
    SourceNotFound(_) => "source-not-found"
    SourceNotRegularFile(..) => "source-not-regular-file"
    DuplicateDestinationPath(_) => "duplicate-destination-path"
    DestinationRootNotCanonical(..) => "destination-root-not-canonical"
    DestinationRootInvalid(_) => "destination-root-invalid"
    DestinationSymlink(_) => "destination-symlink"
    DestinationParentNotDirectory(_) => "destination-parent-not-directory"
    DestinationIsDirectory(_) => "destination-is-directory"
    DestinationUnsupported(..) => "destination-unsupported"
    DestinationStateChanged(_) => "destination-state-changed"
    SourceFingerprintMismatch(_) => "source-fingerprint-mismatch"
    DestinationIo(_) => "destination-io"
  }
}

///|
pub(all) struct SandboxPromotionResult {
  promoted_paths : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The durable outcome of applying one reviewed promotion. `RecoveryRequired`
/// means the native operation reported I/O failure after it may have changed
/// the destination; callers must preserve the retention and inspect the named
/// destination before retrying or cleaning anything up.
pub(all) enum SandboxPromotionOutcome {
  AppliedDurable(SandboxPromotionResult)
  NotApplied(SandboxPromotionRefusal)
  RecoveryRequired(destination_path~ : String, native_status~ : Int)
} derive(Debug, Eq, ToJson, FromJson)

///|
fn promotion_outcome_from_native_status(
  item : SandboxPromotionItem,
  status : Int,
) -> SandboxPromotionOutcome {
  match status {
    0 => AppliedDurable({ promoted_paths: [item.destination_relative_path] })
    1 | 3 => NotApplied(DestinationStateChanged(item.destination_relative_path))
    2 => NotApplied(SourceFingerprintMismatch(item.source_relative_path))
    4 =>
      RecoveryRequired(
        destination_path=item.destination_relative_path,
        native_status=status,
      )
    5 => NotApplied(DestinationIo(secure_fs_status_code(status)))
    unknown =>
      RecoveryRequired(
        destination_path=item.destination_relative_path,
        native_status=unknown,
      )
  }
}

///|
pub fn bind_receipt_scratch_result(
  receipt : SandboxReceipt,
  diff : ScratchDiff,
  artifacts : Array[SandboxArtifact],
) -> Result[SandboxReceipt, SandboxArtifactRefusal] {
  let changed_paths : Array[String] = []
  let artifact_paths : Array[String] = []
  for change in diff.entries {
    if !scratch_relative_path_is_safe(change.relative_path) {
      return Err(UnsafeArtifactPath(change.relative_path))
    }
    changed_paths.push(change.relative_path)
  }
  for artifact in artifacts {
    if !scratch_relative_path_is_safe(artifact.relative_path) {
      return Err(UnsafeArtifactPath(artifact.relative_path))
    }
    artifact_paths.push(artifact.relative_path)
  }
  Ok({
    ..receipt,
    changed_paths,
    changes: diff.entries.copy(),
    artifacts: artifact_paths,
  })
}

///|
pub fn SandboxPromotionPlan::destination_root(
  self : SandboxPromotionPlan,
) -> String {
  self.destination_root
}

///|
pub fn SandboxPromotionPlan::items(
  self : SandboxPromotionPlan,
) -> Array[SandboxPromotionItem] {
  self.items.copy()
}

///|
async fn validate_destination_confinement(
  destination_root : String,
  destination_path : String,
) -> SandboxPromotionRefusal? {
  let components = destination_path.split("/").collect()
  let mut current = destination_root
  for index, component_view in components {
    let component = component_view.to_owned()
    let is_final = index == components.length() - 1
    let names = @fs.readdir(current)
    if !names.contains(component) {
      return if is_final {
        None
      } else {
        Some(DestinationParentNotDirectory(destination_path))
      }
    }
    current = "\{current}/\{component}"
    let kind = @fs.kind(current, follow_symlink=false)
    match kind {
      SymLink => return Some(DestinationSymlink(destination_path))
      Directory if is_final =>
        return Some(DestinationIsDirectory(destination_path))
      Directory => ()
      Regular if is_final => ()
      Regular => return Some(DestinationParentNotDirectory(destination_path))
      other =>
        return Some(
          DestinationUnsupported(
            path=destination_path,
            kind=fs_kind_label(other),
          ),
        )
    }
  }
  None
}

///|
/// Build a reviewable, exactly-one-file promotion plan without copying
/// anything. The backend re-runs the same confinement checks immediately
/// before the atomic promotion; destination parents must already exist.
pub async fn plan_sandbox_promotion(
  inventory : ScratchInventory,
  destination_root : String,
  requests : Array[SandboxPromotionRequest],
) -> Result[SandboxPromotionPlan, SandboxPromotionRefusal] {
  if requests.is_empty() {
    return Err(EmptyPromotionPlan)
  }
  if requests.length() != 1 {
    return Err(MultiplePromotionItems(requests.length()))
  }
  if !path_is_canonical_absolute(destination_root) {
    return Err(DestinationRootInvalid(destination_root))
  }
  try {
    let actual_root = @fs.realpath(destination_root)
    if actual_root != destination_root {
      return Err(
        DestinationRootNotCanonical(
          expected=destination_root,
          actual=actual_root,
        ),
      )
    }
    if !(@fs.kind(destination_root, follow_symlink=false) is Directory) {
      return Err(DestinationRootInvalid(destination_root))
    }
    let destinations : Map[String, Unit] = Map([])
    let items : Array[SandboxPromotionItem] = []
    for request in requests {
      if !scratch_relative_path_is_safe(request.artifact_path) {
        return Err(UnsafeSourcePath(request.artifact_path))
      }
      if !scratch_relative_path_is_safe(request.destination_path) {
        return Err(UnsafeDestinationPath(request.destination_path))
      }
      if destinations.contains(request.destination_path) {
        return Err(DuplicateDestinationPath(request.destination_path))
      }
      destinations[request.destination_path] = ()
      guard find_scratch_entry(inventory, request.artifact_path) is Some(source) else {
        return Err(SourceNotFound(request.artifact_path))
      }
      if !(source.kind is RegularFile) {
        return Err(
          SourceNotRegularFile(path=request.artifact_path, kind=source.kind),
        )
      }
      if validate_destination_confinement(
          destination_root,
          request.destination_path,
        )
        is Some(reason) {
        return Err(reason)
      }
      let destination_state = match
        secure_destination_state(destination_root, request.destination_path) {
        SecureDestinationAbsent => ReviewedDestinationAbsent
        SecureDestinationRegular(size_bytes~, fingerprint~) =>
          ReviewedDestinationRegular(size_bytes~, fingerprint~)
        SecureDestinationError(status) =>
          return Err(
            DestinationIo("destination-review-\{secure_fs_status_code(status)}"),
          )
      }
      items.push({
        source_relative_path: request.artifact_path,
        destination_relative_path: request.destination_path,
        expected_source_fingerprint: source.fingerprint,
        size_bytes: source.size_bytes,
        expected_destination_state: destination_state,
      })
    }
    Ok({ destination_root, items })
  } catch {
    error if @async.is_being_cancelled() => raise error
    error => Err(DestinationIo("\{error}"))
  }
}

///|
/// Apply a reviewed plan containing exactly one regular file. Native fd-relative
/// traversal pins every source/destination directory without following
/// symlinks. Each item also binds the reviewed destination state. Absent files
/// are installed with an atomic no-replace rename; existing regular files are
/// installed with an atomic exchange and the displaced bytes are verified
/// before deletion. Unsupported atomic primitives are refusal conditions.
pub async fn apply_sandbox_promotion(
  scratch_root : String,
  plan : SandboxPromotionPlan,
  disk_limit_bytes? : Int64 = 2_147_483_648L,
) -> SandboxPromotionOutcome {
  try {
    if plan.items.is_empty() {
      return NotApplied(EmptyPromotionPlan)
    }
    if plan.items.length() != 1 {
      return NotApplied(MultiplePromotionItems(plan.items.length()))
    }
    if @fs.realpath(scratch_root) != scratch_root ||
      @fs.realpath(plan.destination_root) != plan.destination_root {
      return NotApplied(DestinationRootInvalid(plan.destination_root))
    }
    let current = match inventory_scratch(scratch_root, disk_limit_bytes) {
      Ok(value) => value
      Err(reason) => return NotApplied(DestinationIo(reason.code()))
    }
    let item = plan.items[0]
    guard find_scratch_entry(current, item.source_relative_path) is Some(entry) else {
      return NotApplied(SourceNotFound(item.source_relative_path))
    }
    if !(entry.kind is RegularFile) ||
      entry.fingerprint != item.expected_source_fingerprint ||
      entry.size_bytes != item.size_bytes {
      return NotApplied(SourceFingerprintMismatch(item.source_relative_path))
    }
    if validate_destination_confinement(
        plan.destination_root,
        item.destination_relative_path,
      )
      is Some(reason) {
      return NotApplied(reason)
    }
    let status = secure_promote_regular(
      scratch_root,
      item.source_relative_path,
      plan.destination_root,
      item.destination_relative_path,
      item.size_bytes,
      item.expected_source_fingerprint,
      match item.expected_destination_state {
        ReviewedDestinationAbsent => 0
        ReviewedDestinationRegular(..) => 1
      },
      match item.expected_destination_state {
        ReviewedDestinationAbsent => 0L
        ReviewedDestinationRegular(size_bytes~, ..) => size_bytes
      },
      match item.expected_destination_state {
        ReviewedDestinationAbsent => ""
        ReviewedDestinationRegular(fingerprint~, ..) => fingerprint
      },
    )
    promotion_outcome_from_native_status(item, status)
  } catch {
    error if @async.is_being_cancelled() => raise error
    error => NotApplied(DestinationIo("\{error}"))
  }
}
