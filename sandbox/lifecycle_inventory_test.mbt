///|
fn lifecycle_test_profile(
  workspace : String,
  scratch : String,
) -> SandboxProfile {
  {
    run_id: "run-lifecycle-test",
    workspace_root: workspace,
    scratch_root: scratch,
    backend: MicroVm,
    enforcement_requirement: RequireEnforced,
    network: Deny,
    read_only_roots: [workspace],
    allowed_egress: [],
    allowed_commands: ["moon"],
    limits: { ..default_limits(), disk_mib: 1 },
    read_only_workspace: true,
  }
}

///|
async test "inventory records symlinks without following them" {
  let scratch = @fs.realpath(@fs.tmpdir(prefix="moonfort-inventory-"))
  let outside = @fs.realpath(@fs.tmpdir(prefix="moonfort-outside-"))
  @fs.write_file("\{outside}/secret", "outside secret", create_mode=CreateNew)
  @fs.symlink("\{scratch}/escape", target="\{outside}/secret")
  let inventory = inventory_scratch(scratch, 1024L).unwrap()
  assert_eq(inventory.total_bytes, 0L)
  assert_eq(inventory.entries.length(), 1)
  assert_true(inventory.entries[0].kind is SymbolicLink)
  assert_eq(inventory.entries[0].relative_path, "escape")
  ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(outside, recursive=true) catch { _ => () })
}

///|
async test "inventory enforces its disk bound" {
  let scratch = @fs.realpath(@fs.tmpdir(prefix="moonfort-disk-"))
  @fs.write_file("\{scratch}/large", "12345", create_mode=CreateNew)
  let result = inventory_scratch(scratch, 4L)
  guard result is Err(reason) else { fail("expected disk refusal") }
  assert_eq(reason.code(), "disk-limit-exceeded")
  ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
}

///|
async test "materialization refuses workspace symlinks" {
  let workspace = @fs.realpath(@fs.tmpdir(prefix="moonfort-source-link-"))
  let scratch = @fs.realpath(@fs.tmpdir(prefix="moonfort-copy-link-"))
  @fs.symlink("\{workspace}/escape", target="/etc/passwd")
  let result = materialize_workspace_snapshot(workspace, scratch)
  guard result is Err(reason) else { fail("expected symlink refusal") }
  assert_eq(reason.code(), "unsupported-entry")
  ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
}

///|
async test "lifecycle materializes, diffs, snapshots, stops, and resets" {
  let workspace = @fs.realpath(@fs.tmpdir(prefix="moonfort-workspace-"))
  let scratch = @fs.realpath(@fs.tmpdir(prefix="moonfort-scratch-"))
  @fs.write_file("\{workspace}/original", "one", create_mode=CreateNew)
  let profile = lifecycle_test_profile(workspace, scratch)
  let created = new_sandbox_run(profile).unwrap()
  let starting = created.begin_start().unwrap()
  let ready = starting.complete_start().unwrap()
  assert_eq(@fs.read_file("\{scratch}/original").text(), "one")
  let prepared = prepare_sandbox_command(
      profile,
      Exec(tool="moon", args=["check"]),
      BackendEnforced,
    )
    .prepared()
    .unwrap()
  let executing = ready.begin_exec(prepared).unwrap()
  @fs.write_file("\{scratch}/original", "two", create_mode=CreateOrTruncate)
  @fs.write_file("\{scratch}/added", "new", create_mode=CreateNew)
  let receipt = exited_receipt(
    profile.run_id,
    MicroVm,
    Enforced,
    profile_digest(profile),
    0,
    "",
  )
  let observed = executing.complete_exec(receipt).unwrap()
  assert_eq(observed.diff_from_baseline().entries.length(), 2)
  let snap_pending = observed.run().begin_snapshot().unwrap()
  let snapped = snap_pending.complete_snapshot().unwrap()
  assert_true(
    snapped
    .snapshot()
    .manifest_json()
    .stringify()
    .contains("run-lifecycle-test"),
  )
  let stopping = snapped.run().begin_stop().unwrap()
  let stopped = stopping.complete_stop().unwrap().run()
  let resetting = stopped.begin_reset().unwrap()
  let reset = resetting.complete_reset().unwrap()
  assert_true(reset.diff_from_baseline().entries.is_empty())
  assert_eq(@fs.read_file("\{scratch}/original").text(), "one")
  assert_false(@fs.exists("\{scratch}/added"))
  ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
}

///|
test "artifact declarations reject traversal and symlinks" {
  let inventory : ScratchInventory = {
    entries: [
      {
        relative_path: "link",
        kind: SymbolicLink,
        size_bytes: 0L,
        fingerprint: "link",
      },
    ],
    total_bytes: 0L,
  }
  assert_true(declare_sandbox_artifacts(inventory, ["../escape"]) is Err(_))
  assert_true(declare_sandbox_artifacts(inventory, ["link"]) is Err(_))
}

///|
test "diff preserves added modified removed and symlink entry kinds" {
  let before : ScratchInventory = {
    entries: [
      {
        relative_path: "gone",
        kind: RegularFile,
        size_bytes: 1L,
        fingerprint: "a",
      },
      {
        relative_path: "changed",
        kind: RegularFile,
        size_bytes: 1L,
        fingerprint: "a",
      },
    ],
    total_bytes: 2L,
  }
  let after : ScratchInventory = {
    entries: [
      {
        relative_path: "changed",
        kind: RegularFile,
        size_bytes: 1L,
        fingerprint: "b",
      },
      {
        relative_path: "link",
        kind: SymbolicLink,
        size_bytes: 0L,
        fingerprint: "link",
      },
    ],
    total_bytes: 1L,
  }
  let diff = diff_scratch(before, after)
  assert_eq(diff.entries.length(), 3)
  assert_true(diff.entries.any(item => item.change is Modified))
  assert_true(diff.entries.any(item => item.change is Removed))
  assert_true(
    diff.entries.any(item => {
      item.change is Added &&
      item.after is Some(entry) &&
      entry.kind is SymbolicLink
    }),
  )
}

///|
test "receipt binding keeps identity and uses relative paths" {
  let profile = lifecycle_test_profile("/workspace", "/scratch")
  let receipt = exited_receipt(
    profile.run_id,
    MicroVm,
    Enforced,
    profile_digest(profile),
    0,
    "ok",
  )
  let entry : ScratchEntry = {
    relative_path: "out/result",
    kind: RegularFile,
    size_bytes: 2L,
    fingerprint: "digest",
  }
  let diff : ScratchDiff = {
    entries: [
      {
        relative_path: "out/result",
        change: Added,
        before: None,
        after: Some(entry),
      },
    ],
    before_bytes: 0L,
    after_bytes: 2L,
  }
  let bound = bind_receipt_scratch_result(receipt, diff, [
    { relative_path: "out/result", size_bytes: 2L, fingerprint: "digest" },
  ]).unwrap()
  assert_eq(bound.run_id, profile.run_id)
  assert_eq(bound.profile_digest, profile_digest(profile))
  assert_eq(bound.changed_paths, ["out/result"])
  assert_eq(bound.changes.length(), 1)
  assert_true(
    bound.changes[0].change is Added &&
    bound.changes[0].after is Some(after) &&
    after.fingerprint == "digest" &&
    after.size_bytes == 2L,
  )
  assert_eq(bound.artifacts, ["out/result"])
}

///|
async test "promotion refuses symlink destinations and applies regular files" {
  let scratch = @fs.realpath(@fs.tmpdir(prefix="moonfort-promote-source-"))
  let destination = @fs.realpath(@fs.tmpdir(prefix="moonfort-promote-dest-"))
  let outside = @fs.realpath(@fs.tmpdir(prefix="moonfort-promote-outside-"))
  @fs.write_file("\{scratch}/artifact", "payload", create_mode=CreateNew)
  let inventory = inventory_scratch(scratch, 1024L).unwrap()
  @fs.symlink("\{destination}/escape", target=outside)
  let rejected = plan_sandbox_promotion(inventory, destination, [
    { artifact_path: "artifact", destination_path: "escape/file" },
  ])
  guard rejected is Err(reason) else { fail("expected destination refusal") }
  assert_eq(reason.code(), "destination-symlink")
  let plan = plan_sandbox_promotion(inventory, destination, [
    { artifact_path: "artifact", destination_path: "safe/file" },
  ]).unwrap()
  let promoted = apply_sandbox_promotion(scratch, plan).unwrap()
  assert_eq(promoted.promoted_paths, ["safe/file"])
  assert_eq(@fs.read_file("\{destination}/safe/file").text(), "payload")
  assert_false(@fs.exists("\{outside}/file"))
  ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(destination, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(outside, recursive=true) catch { _ => () })
}

///|
async test "promotion pins destination ancestry after reviewed plan" {
  let scratch = @fs.realpath(@fs.tmpdir(prefix="moonfort-promote-race-source-"))
  let destination = @fs.realpath(
    @fs.tmpdir(prefix="moonfort-promote-race-dest-"),
  )
  let outside = @fs.realpath(
    @fs.tmpdir(prefix="moonfort-promote-race-outside-"),
  )
  @fs.write_file("\{scratch}/artifact", "payload", create_mode=CreateNew)
  @fs.mkdir("\{destination}/parent", permission=0o700)
  let inventory = inventory_scratch(scratch, 1024L).unwrap()
  let plan = plan_sandbox_promotion(inventory, destination, [
    { artifact_path: "artifact", destination_path: "parent/file" },
  ]).unwrap()
  // Model an attacker swapping the reviewed parent before the apply operation.
  // The fd-relative implementation must refuse the symlink and never touch its
  // target, even though all path-based planning checks already passed.
  @fs.rename("\{destination}/parent", "\{destination}/reviewed-parent")
  @fs.symlink("\{destination}/parent", target=outside)
  let result = apply_sandbox_promotion(scratch, plan)
  guard result is Err(reason) else { fail("expected swapped parent refusal") }
  assert_eq(reason.code(), "destination-symlink")
  assert_false(@fs.exists("\{outside}/file"))
  ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(destination, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(outside, recursive=true) catch { _ => () })
}

///|
async test "discard refuses a swapped root without touching symlink target" {
  let owner = @fs.realpath(@fs.tmpdir(prefix="moonfort-discard-race-owner-"))
  let outside = @fs.realpath(
    @fs.tmpdir(prefix="moonfort-discard-race-outside-"),
  )
  let scratch = "\{owner}/scratch"
  let moved = "\{owner}/moved-scratch"
  @fs.mkdir(scratch, permission=0o700)
  @fs.write_file("\{scratch}/artifact", "payload", create_mode=CreateNew)
  @fs.write_file("\{outside}/sentinel", "outside", create_mode=CreateNew)
  // Model a scratch-root replacement between allocation/validation and cleanup.
  @fs.rename(scratch, moved)
  @fs.symlink(scratch, target=outside)
  let result = discard_scratch_tree(scratch)
  guard result is Err(_) else { fail("expected swapped scratch refusal") }
  assert_eq(@fs.read_file("\{outside}/sentinel").text(), "outside")
  assert_eq(@fs.read_file("\{moved}/artifact").text(), "payload")
  ignore(@fs.rmdir(owner, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(outside, recursive=true) catch { _ => () })
}
