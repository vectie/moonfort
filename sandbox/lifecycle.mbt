///|
pub(all) enum SandboxLifecycleState {
  Created
  Starting
  Ready
  Executing
  Stopping
  Stopped
  SnapshottingReady
  SnapshottingStopped
  Resetting
  Failed
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxLifecycleRefusal {
  InvalidLifecycleProfile(String)
  InvalidLifecycleTransition(
    operation~ : String,
    actual~ : SandboxLifecycleState
  )
  PreparedRunMismatch
  ReceiptRunMismatch
  ReceiptNotTerminal
  StorageRefused(SandboxStorageRefusal)
  ResetDidNotRestoreBaseline(ScratchDiff)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub struct SandboxRunContract {
  profile : SandboxProfile
  profile_digest : String
  state : SandboxLifecycleState
  baseline : ScratchInventory?
  latest : ScratchInventory?
  revision : Int
} derive(Debug, Eq)

///|
pub struct SandboxScratchSnapshot {
  run_id : String
  profile_digest : String
  revision : Int
  inventory : ScratchInventory
} derive(Debug, Eq)

///|
pub struct SandboxRunObservation {
  run : SandboxRunContract
  snapshot : SandboxScratchSnapshot
  diff_from_baseline : ScratchDiff
} derive(Debug, Eq)

///|
pub fn SandboxLifecycleRefusal::code(self : SandboxLifecycleRefusal) -> String {
  match self {
    InvalidLifecycleProfile(_) => "invalid-lifecycle-profile"
    InvalidLifecycleTransition(..) => "invalid-lifecycle-transition"
    PreparedRunMismatch => "prepared-run-mismatch"
    ReceiptRunMismatch => "receipt-run-mismatch"
    ReceiptNotTerminal => "receipt-not-terminal"
    StorageRefused(_) => "storage-refused"
    ResetDidNotRestoreBaseline(_) => "reset-did-not-restore-baseline"
  }
}

///|
pub fn SandboxLifecycleState::label(self : SandboxLifecycleState) -> String {
  match self {
    Created => "created"
    Starting => "starting"
    Ready => "ready"
    Executing => "executing"
    Stopping => "stopping"
    Stopped => "stopped"
    SnapshottingReady => "snapshotting-ready"
    SnapshottingStopped => "snapshotting-stopped"
    Resetting => "resetting"
    Failed => "failed"
  }
}

///|
pub fn new_sandbox_run(
  profile : SandboxProfile,
) -> Result[SandboxRunContract, SandboxLifecycleRefusal] {
  let rejection = profile_rejection(profile)
  if rejection != "" {
    Err(InvalidLifecycleProfile(rejection))
  } else {
    let profile = copy_profile(profile)
    Ok({
      profile,
      profile_digest: profile_digest(profile),
      state: Created,
      baseline: None,
      latest: None,
      revision: 0,
    })
  }
}

///|
pub fn SandboxRunContract::state(
  self : SandboxRunContract,
) -> SandboxLifecycleState {
  self.state
}

///|
pub fn SandboxRunContract::profile(self : SandboxRunContract) -> SandboxProfile {
  copy_profile(self.profile)
}

///|
pub fn SandboxRunContract::profile_digest(self : SandboxRunContract) -> String {
  self.profile_digest
}

///|
pub fn SandboxRunContract::baseline(
  self : SandboxRunContract,
) -> ScratchInventory? {
  self.baseline.map(copy_scratch_inventory)
}

///|
pub fn SandboxRunContract::latest(
  self : SandboxRunContract,
) -> ScratchInventory? {
  self.latest.map(copy_scratch_inventory)
}

///|
pub fn SandboxRunContract::revision(self : SandboxRunContract) -> Int {
  self.revision
}

///|
pub fn SandboxScratchSnapshot::inventory(
  self : SandboxScratchSnapshot,
) -> ScratchInventory {
  copy_scratch_inventory(self.inventory)
}

///|
pub fn SandboxScratchSnapshot::run_id(self : SandboxScratchSnapshot) -> String {
  self.run_id
}

///|
pub fn SandboxScratchSnapshot::profile_digest(
  self : SandboxScratchSnapshot,
) -> String {
  self.profile_digest
}

///|
pub fn SandboxScratchSnapshot::revision(self : SandboxScratchSnapshot) -> Int {
  self.revision
}

///|
/// A durable, backend-neutral manifest. This records scratch identity and
/// inventory, not file bytes; a VM backend may bind its own snapshot handle to
/// this JSON while local reset rematerializes the canonical read-only source.
pub fn SandboxScratchSnapshot::manifest_json(
  self : SandboxScratchSnapshot,
) -> Json {
  {
    "run_id": self.run_id,
    "profile_digest": self.profile_digest,
    "revision": self.revision,
    "inventory": self.inventory,
  }
}

///|
pub fn SandboxRunObservation::run(
  self : SandboxRunObservation,
) -> SandboxRunContract {
  self.run
}

///|
pub fn SandboxRunObservation::snapshot(
  self : SandboxRunObservation,
) -> SandboxScratchSnapshot {
  self.snapshot
}

///|
pub fn SandboxRunObservation::diff_from_baseline(
  self : SandboxRunObservation,
) -> ScratchDiff {
  { ..self.diff_from_baseline, entries: self.diff_from_baseline.entries.copy() }
}

///|
fn lifecycle_transition_error(
  operation~ : String,
  actual~ : SandboxLifecycleState,
) -> Result[SandboxRunContract, SandboxLifecycleRefusal] {
  Err(InvalidLifecycleTransition(operation~, actual~))
}

///|
fn lifecycle_disk_limit(profile : SandboxProfile) -> Int64 {
  profile.limits.disk_mib.to_int64() * 1024L * 1024L
}

///|
async fn capture_lifecycle_inventory(
  run : SandboxRunContract,
) -> Result[ScratchInventory, SandboxLifecycleRefusal] {
  match
    inventory_scratch(
      run.profile.scratch_root,
      lifecycle_disk_limit(run.profile),
    ) {
    Ok(inventory) => Ok(inventory)
    Err(reason) => Err(StorageRefused(reason))
  }
}

///|
fn observation(
  run : SandboxRunContract,
  inventory : ScratchInventory,
) -> SandboxRunObservation {
  let baseline = match run.baseline {
    Some(value) => value
    None => inventory
  }
  let snapshot = {
    run_id: run.profile.run_id,
    profile_digest: run.profile_digest,
    revision: run.revision,
    inventory: copy_scratch_inventory(inventory),
  }
  { run, snapshot, diff_from_baseline: diff_scratch(baseline, inventory) }
}

///|
pub fn SandboxRunContract::begin_start(
  self : SandboxRunContract,
) -> Result[SandboxRunContract, SandboxLifecycleRefusal] {
  match self.state {
    Created => Ok({ ..self, state: Starting })
    actual => lifecycle_transition_error(operation="start", actual~)
  }
}

///|
pub async fn SandboxRunContract::complete_start(
  self : SandboxRunContract,
) -> Result[SandboxRunContract, SandboxLifecycleRefusal] {
  if !(self.state is Starting) {
    return lifecycle_transition_error(
      operation="complete-start",
      actual=self.state,
    )
  }
  match
    materialize_workspace_snapshot(
      self.profile.workspace_root,
      self.profile.scratch_root,
      disk_limit_bytes=lifecycle_disk_limit(self.profile),
    ) {
    Err(reason) => Err(StorageRefused(reason))
    Ok(baseline) =>
      Ok({
        ..self,
        state: Ready,
        baseline: Some(copy_scratch_inventory(baseline)),
        latest: Some(copy_scratch_inventory(baseline)),
      })
  }
}

///|
pub fn SandboxRunContract::begin_exec(
  self : SandboxRunContract,
  prepared : PreparedSandboxCommand,
) -> Result[SandboxRunContract, SandboxLifecycleRefusal] {
  if !(self.state is Ready) {
    return lifecycle_transition_error(operation="exec", actual=self.state)
  }
  let prepared_profile = prepared.profile()
  if prepared.profile_digest() != self.profile_digest ||
    prepared_profile.run_id != self.profile.run_id ||
    prepared_profile.backend != self.profile.backend {
    Err(PreparedRunMismatch)
  } else {
    Ok({ ..self, state: Executing })
  }
}

///|
pub async fn SandboxRunContract::complete_exec(
  self : SandboxRunContract,
  receipt : SandboxReceipt,
) -> Result[SandboxRunObservation, SandboxLifecycleRefusal] {
  if !(self.state is Executing) {
    return Err(
      InvalidLifecycleTransition(operation="complete-exec", actual=self.state),
    )
  }
  if receipt.run_id != self.profile.run_id ||
    receipt.profile_digest != self.profile_digest ||
    receipt.backend != self.profile.backend {
    return Err(ReceiptRunMismatch)
  }
  let receipt_is_terminal = match receipt.status {
    Exited | Killed | Failed => true
    _ => false
  }
  if !receipt_is_terminal || receipt.enforcement is Refused {
    return Err(ReceiptNotTerminal)
  }
  match capture_lifecycle_inventory(self) {
    Err(reason) => Err(reason)
    Ok(inventory) => {
      let run = {
        ..self,
        state: Ready,
        latest: Some(copy_scratch_inventory(inventory)),
        revision: self.revision + 1,
      }
      Ok(observation(run, inventory))
    }
  }
}

///|
pub fn SandboxRunContract::begin_stop(
  self : SandboxRunContract,
) -> Result[SandboxRunContract, SandboxLifecycleRefusal] {
  match self.state {
    Ready | Executing => Ok({ ..self, state: Stopping })
    actual => lifecycle_transition_error(operation="stop", actual~)
  }
}

///|
pub async fn SandboxRunContract::complete_stop(
  self : SandboxRunContract,
) -> Result[SandboxRunObservation, SandboxLifecycleRefusal] {
  if !(self.state is Stopping) {
    return Err(
      InvalidLifecycleTransition(operation="complete-stop", actual=self.state),
    )
  }
  match capture_lifecycle_inventory(self) {
    Err(reason) => Err(reason)
    Ok(inventory) => {
      let run = {
        ..self,
        state: Stopped,
        latest: Some(copy_scratch_inventory(inventory)),
        revision: self.revision + 1,
      }
      Ok(observation(run, inventory))
    }
  }
}

///|
pub fn SandboxRunContract::begin_snapshot(
  self : SandboxRunContract,
) -> Result[SandboxRunContract, SandboxLifecycleRefusal] {
  match self.state {
    Ready => Ok({ ..self, state: SnapshottingReady })
    Stopped => Ok({ ..self, state: SnapshottingStopped })
    actual => lifecycle_transition_error(operation="snapshot", actual~)
  }
}

///|
pub async fn SandboxRunContract::complete_snapshot(
  self : SandboxRunContract,
) -> Result[SandboxRunObservation, SandboxLifecycleRefusal] {
  let resume_state = match self.state {
    SnapshottingReady => Ready
    SnapshottingStopped => Stopped
    actual =>
      return Err(
        InvalidLifecycleTransition(operation="complete-snapshot", actual~),
      )
  }
  match capture_lifecycle_inventory(self) {
    Err(reason) => Err(reason)
    Ok(inventory) => {
      let run = {
        ..self,
        state: resume_state,
        latest: Some(copy_scratch_inventory(inventory)),
        revision: self.revision + 1,
      }
      Ok(observation(run, inventory))
    }
  }
}

///|
/// Reset mutation belongs to the enforcing backend. This transition verifies
/// that the backend restored the scratch tree exactly to its bound baseline.
pub fn SandboxRunContract::begin_reset(
  self : SandboxRunContract,
) -> Result[SandboxRunContract, SandboxLifecycleRefusal] {
  match self.state {
    Stopped => Ok({ ..self, state: Resetting })
    actual => lifecycle_transition_error(operation="reset", actual~)
  }
}

///|
pub async fn SandboxRunContract::complete_reset(
  self : SandboxRunContract,
) -> Result[SandboxRunObservation, SandboxLifecycleRefusal] {
  if !(self.state is Resetting) {
    return Err(
      InvalidLifecycleTransition(operation="complete-reset", actual=self.state),
    )
  }
  let baseline = match self.baseline {
    Some(value) => value
    None =>
      return Err(
        InvalidLifecycleTransition(
          operation="reset-without-baseline",
          actual=self.state,
        ),
      )
  }
  match
    reset_workspace_snapshot(
      self.profile.workspace_root,
      self.profile.scratch_root,
      lifecycle_disk_limit(self.profile),
    ) {
    Err(reason) => Err(StorageRefused(reason))
    Ok(inventory) => {
      let reset_diff = diff_scratch(baseline, inventory)
      if !reset_diff.entries.is_empty() {
        return Err(ResetDidNotRestoreBaseline(reset_diff))
      }
      let run = {
        ..self,
        state: Ready,
        latest: Some(copy_scratch_inventory(inventory)),
        revision: self.revision + 1,
      }
      Ok(observation(run, inventory))
    }
  }
}

///|
pub fn SandboxRunContract::mark_failed(
  self : SandboxRunContract,
) -> SandboxRunContract {
  { ..self, state: Failed }
}
