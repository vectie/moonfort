///|
test "local profile is default-deny with scratch as the only writable root" {
  let profile = local_profile(
    "run-local-1", "/workspace/book", "/scratch/run-local-1",
  ).allow_degraded()
  let policy = local_sbpl_profile(profile, "/usr/bin/moon")
  assert_true(policy.contains("(deny default)"))
  assert_true(policy.contains("(deny network*)"))
  assert_true(policy.contains("(allow file-read-data)"))
  let pathless_loader_read = policy.rev_find("(allow file-read-data)")
  let global_path_deny = policy.rev_find("(deny file-read* (subpath \"/\"))")
  let runtime_reopen = policy.rev_find(
    "(allow file-read* (subpath \"/System\"))",
  )
  guard pathless_loader_read is Some(loader_index) else {
    fail("missing pathless loader read allowance")
  }
  guard global_path_deny is Some(global_deny_index) else {
    fail("missing global path read denial")
  }
  guard runtime_reopen is Some(runtime_index) else {
    fail("missing explicit runtime read reopening")
  }
  assert_true(loader_index < global_deny_index)
  assert_true(global_deny_index < runtime_index)
  assert_true(policy.contains("(allow file-read* (subpath \"/usr/bin\"))"))
  assert_false(policy.contains("(allow file-read* (subpath \"/etc\"))"))
  assert_true(
    policy.contains("(allow file-write* (subpath \"/scratch/run-local-1\"))"),
  )
  assert_false(policy.contains("allow default"))
  assert_false(
    policy.contains("(allow file-write* (subpath \"/workspace/book\"))"),
  )
  assert_false(
    policy.contains("(allow file-read* (subpath \"/workspace/book\"))"),
  )
  assert_true(
    policy.contains("(deny file-read* (subpath \"/workspace/book\"))"),
  )
  assert_true(
    policy.contains("(allow file-read* (subpath \"/scratch/run-local-1\"))"),
  )
  let scratch_allow = policy.rev_find(
    "(allow file-write* (subpath \"/scratch/run-local-1\"))",
  )
  let workspace_deny = policy.rev_find(
    "(deny file-write* (subpath \"/workspace/book\"))",
  )
  guard scratch_allow is Some(scratch_index) else {
    fail("missing scratch allow rule")
  }
  guard workspace_deny is Some(workspace_index) else {
    fail("missing workspace deny rule")
  }
  assert_true(workspace_index > scratch_index)
}

///|
test "SBPL string escaping cannot inject a policy form" {
  let escaped = sbpl_escape("/tmp/x\")\n(allow default)\n(\"")
  assert_false(escaped.contains("\n(allow default)"))
  assert_true(escaped.contains("\\n(allow default)"))
  assert_true(escaped.contains("\\\""))
}

///|
async test "local entry point rejects a backend mismatch" {
  let profile = {
    ..local_profile("run-vm", "/workspace", "/scratch/run-vm"),
    backend: MicroVm,
  }
  let receipt = run_local_sandbox(profile, Exec(tool="moon", args=["check"]), [])
  assert_true(receipt.enforcement is Refused)
  assert_true(
    receipt.denial_reason is Some(reason) && reason.contains("LocalOs"),
  )
}

///|
async test "strict local run refuses before probing or spawning" {
  let receipt = run_local_sandbox(
    local_profile("run-strict", "/does/not/exist", "/also/missing"),
    Exec(tool="moon", args=["check"]),
    [{ capability_label: "moon", executable_path: "/does/not/matter" }],
  )
  assert_true(receipt.enforcement is Refused)
  assert_true(receipt.status is Failed)
  assert_true(
    receipt.denial_reason is Some(reason) && reason.contains("operator opt-in"),
  )
}

///|
async test "local backend either enforces its profile or refuses without fallback" {
  let workspace = @fs.tmpdir(prefix="moonfort-e2e-workspace-")
  let scratch = @fs.tmpdir(prefix="moonfort-e2e-scratch-")
  let profile = {
    ..local_profile("run-e2e", workspace, scratch).allow_degraded(),
    allowed_commands: ["true"],
  }
  let receipt = run_local_sandbox(profile, Exec(tool="true", args=[]), [
    { capability_label: "true", executable_path: "/usr/bin/true" },
  ])
  match receipt.enforcement {
    Refused => {
      assert_true(receipt.status is Failed)
      assert_true(receipt.exit_code is None)
    }
    Degraded => {
      assert_true(receipt.status is Exited)
      assert_eq(receipt.exit_code, Some(0))
      assert_true(receipt.unverified_limits.contains("aggregate-cpu"))
      assert_true(receipt.unverified_limits.contains("aggregate-memory"))
      assert_true(receipt.unverified_limits.contains("hard-disk-quota"))
      assert_true(receipt.unverified_limits.contains("hard-process-quota"))
      assert_true(
        receipt.unverified_limits.contains("detached-descendant-processes"),
      )
      if local_os_platform() is Linux {
        assert_true(
          receipt.unverified_limits.contains("nested-user-namespaces"),
        )
      }
    }
    Enforced => fail("local backend must never claim full enforcement")
  }
  ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
}

///|
test "wall-clock receipts do not falsely claim output truncation" {
  let receipt = killed_receipt(
    "run-timeout",
    LocalOs,
    Degraded,
    "digest",
    "partial",
    false,
    "wall-clock-limit",
  )
  assert_false(receipt.output_truncated)
}

///|
test "local working directory accepts only normalized relative paths" {
  assert_true(safe_local_working_directory(""))
  assert_true(safe_local_working_directory("packages/app"))
  assert_false(safe_local_working_directory("/packages/app"))
  assert_false(safe_local_working_directory("packages/../outside"))
  assert_false(safe_local_working_directory("packages//app"))
  assert_false(safe_local_working_directory("packages/app/"))
}

///|
test "Linux bubblewrap plan exposes only runtime roots and private scratch" {
  let profile = {
    ..local_profile(
      "run-linux-plan", "/canonical/moonbook", "/private/scratch/run-linux-plan",
    ).allow_degraded(),
    read_only_roots: ["/canonical/moonbook", "/opt/moon-sdk"],
    allowed_commands: ["moon"],
  }
  let args = linux_bubblewrap_arguments(
    profile,
    "/usr/bin/moon",
    ["check", "$(must-stay-an-argument)"],
    "packages/app",
  )
  assert_true(args.contains("--unshare-all"))
  assert_true(args.contains("--unshare-user"))
  assert_false(args.contains("--disable-userns"))
  assert_true(args.contains("--unshare-net"))
  assert_true(args.contains("--cap-drop"))
  assert_false(args.contains("--share-net"))
  assert_false(args.contains("/canonical/moonbook"))
  let scratch_index = args.search_by(value => {
    value == "/private/scratch/run-linux-plan"
  })
  guard scratch_index is Some(index) else {
    fail("missing scratch bind source")
  }
  assert_eq(args[index - 1], "--bind")
  assert_eq(args[index + 1], "/workspace")
  let sdk_index = args.search_by(value => value == "/opt/moon-sdk")
  guard sdk_index is Some(index) else { fail("missing trusted read-only root") }
  assert_eq(args[index - 1], "--ro-bind")
  assert_eq(args[index + 1], "/opt/moon-sdk")
  let command_index = args.search_by(value => value == "--")
  guard command_index is Some(index) else { fail("missing argv terminator") }
  assert_eq(args[index + 1:], [
    "/usr/bin/moon", "check", "$(must-stay-an-argument)",
  ])
  let chdir_index = args.search_by(value => value == "--chdir")
  guard chdir_index is Some(index) else { fail("missing guest cwd") }
  assert_eq(args[index + 1], "/workspace/packages/app")
  let readonly_index = args.search_by(value => value == "--remount-ro")
  guard readonly_index is Some(index) else {
    fail("missing read-only root remount")
  }
  assert_eq(args[index + 1], "/")
}

///|
test "Linux bubblewrap plan refuses guest mount collisions and mutable tools" {
  let base = local_profile(
    "run-linux-refuse", "/canonical/moonbook", "/private/scratch/run-linux-refuse",
  ).allow_degraded()
  let collision = {
    ..base,
    read_only_roots: [base.workspace_root, "/workspace/host-alias"],
  }
  try
    linux_bubblewrap_arguments(collision, "/usr/bin/moon", ["check"], "")
  catch {
    _ => ()
  } noraise {
    _ => fail("reserved guest mount collision must be refused")
  }
  try
    linux_bubblewrap_arguments(
      base,
      "/private/scratch/run-linux-refuse/tool",
      [],
      "",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("writable scratch executable must be refused")
  }
  try
    linux_bubblewrap_arguments(base, "/canonical/moonbook/tool", [], "")
  catch {
    _ => ()
  } noraise {
    _ => fail("workspace executable must be refused")
  }
}

///|
async test "Linux backend behaviorally isolates host paths and network or is unavailable" {
  if !(local_os_platform() is Linux) {
    return
  }
  match local_backend_readiness() {
    BackendUnavailable(reason) => {
      if reason.contains("enforcement unavailable") {
        println(
          "moonfort Linux E2E skipped: enforcement genuinely unavailable (\{reason})",
        )
        return
      }
      fail("bubblewrap exists but the MoonFort profile is broken: \{reason}")
    }
    BackendEnforced =>
      fail("local OS backend must not claim microVM enforcement")
    BackendDegraded(_) => {
      let workspace = @fs.tmpdir(prefix="moonfort-linux-e2e-source-")
      let scratch = @fs.tmpdir(prefix="moonfort-linux-e2e-scratch-")
      let workspace = @fs.realpath(workspace)
      let scratch = @fs.realpath(scratch)
      @fs.write_file(
        "\{workspace}/canonical.txt",
        "canonical",
        create_mode=CreateNew,
        permission=0o600,
      )
      let shell = @fs.realpath("/bin/sh")
      let profile = {
        ..local_profile("run-linux-e2e", workspace, scratch).allow_degraded(),
        allowed_commands: ["sh"],
      }
      let script = "test ! -e \"$1\" && test ! -e /etc/shadow && printf isolated > linux-output.txt"
      let receipt = run_local_sandbox(
        profile,
        Exec(tool="sh", args=["-c", script, "moonfort", workspace]),
        [{ capability_label: "sh", executable_path: shell }],
      )
      assert_true(receipt.enforcement is Degraded)
      assert_true(receipt.status is Exited)
      assert_eq(receipt.exit_code, Some(0))
      assert_eq(receipt.changed_paths, ["linux-output.txt"])
      assert_false(@fs.exists("\{workspace}/linux-output.txt"))
      assert_eq(
        @utf8.decode_lossy(@fs.read_file("\{workspace}/canonical.txt").binary()),
        "canonical",
      )
      ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
      ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
    }
  }
}

///|
async test "macOS backend denies canonical and host-secret reads in a real run" {
  if !(local_os_platform() is MacOs) {
    return
  }
  match local_backend_readiness() {
    BackendUnavailable(reason) =>
      println(
        "moonfort macOS E2E skipped: enforcement genuinely unavailable (\{reason})",
      )
    BackendEnforced =>
      fail("local OS backend must not claim microVM enforcement")
    BackendDegraded(_) => {
      let workspace = @fs.tmpdir(prefix="moonfort-macos-e2e-source-")
      let scratch = @fs.tmpdir(prefix="moonfort-macos-e2e-scratch-")
      let workspace = @fs.realpath(workspace)
      let scratch = @fs.realpath(scratch)
      @fs.write_file(
        "\{workspace}/canonical.txt",
        "canonical-secret",
        create_mode=CreateNew,
        permission=0o600,
      )
      let shell = @fs.realpath("/bin/sh")
      let profile = {
        ..local_profile("run-macos-e2e", workspace, scratch).allow_degraded(),
        allowed_commands: ["sh"],
      }
      let script = "if IFS= read -r line < \"$1\"; then exit 90; fi; if IFS= read -r line < /etc/passwd; then exit 91; fi; printf isolated > macos-output.txt"
      let receipt = run_local_sandbox(
        profile,
        Exec(tool="sh", args=[
          "-c",
          script,
          "moonfort",
          workspace + "/canonical.txt",
        ]),
        [{ capability_label: "sh", executable_path: shell }],
      )
      assert_true(receipt.enforcement is Degraded)
      assert_true(receipt.status is Exited)
      assert_eq(receipt.exit_code, Some(0))
      assert_eq(receipt.changed_paths, ["macos-output.txt"])
      assert_false(@fs.exists("\{workspace}/macos-output.txt"))
      assert_eq(
        @utf8.decode_lossy(@fs.read_file("\{workspace}/canonical.txt").binary()),
        "canonical-secret",
      )
      ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
      ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
    }
  }
}
