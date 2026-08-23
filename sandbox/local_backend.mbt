///|
/// A trusted binding from a capability label to an absolute executable.
pub(all) struct LocalSandboxTool {
  capability_label : String
  executable_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
const SandboxExecPath : String = "/usr/bin/sandbox-exec"

///|
const MacLocalDegradedReason : String = "sandbox-exec plus the native supervisor enforce local policy and resource limits, but the shared host kernel remains a best-effort boundary"

///|
let local_backend_mutex : @async.Mutex = Mutex()

///|
/// Probe enforcement behavior rather than merely checking for the binary.
pub async fn local_backend_readiness() -> SandboxBackendReadiness {
  local_backend_mutex.acquire()
  defer local_backend_mutex.release()
  local_backend_readiness_unlocked()
}

///|
async fn local_backend_readiness_unlocked() -> SandboxBackendReadiness {
  let platform = local_os_platform()
  // Re-run the behavioral probe for every run. Enforcement availability can
  // change at runtime, and a shared unsynchronized cache would let concurrent
  // requests poison one another with a stale result.
  match platform {
    MacOs => {
      let reason = diagnose_sandbox_exec()
      if reason == "" {
        BackendDegraded(MacLocalDegradedReason)
      } else {
        BackendUnavailable("sandbox-exec enforcement probe failed: \{reason}")
      }
    }
    Linux =>
      match diagnose_linux_bubblewrap() {
        LinuxProbeReady => BackendDegraded(LinuxLocalDegradedReason)
        LinuxProbeUnavailable(reason) =>
          BackendUnavailable("bubblewrap enforcement unavailable: \{reason}")
        LinuxProbeMisconfigured(reason) =>
          BackendUnavailable("bubblewrap enforcement probe failed: \{reason}")
      }
    Unsupported =>
      BackendUnavailable(
        "unsupported local operating system: \{local_os_platform_label(platform)}",
      )
  }
}

///|
async fn diagnose_sandbox_exec() -> String {
  if !@fs.exists(SandboxExecPath) {
    return "sandbox-exec executable is absent"
  }
  let workspace = @fs.tmpdir(prefix="moonfort-probe-readonly-") catch {
    error if @async.is_being_cancelled() => raise error
    _ => return "cannot allocate probe workspace"
  }
  let scratch = @fs.tmpdir(prefix="moonfort-probe-scratch-") catch {
    error if @async.is_being_cancelled() => raise error
    _ => {
      ignore(@fs.rmdir(workspace) catch { _ => () })
      return "cannot allocate probe scratch"
    }
  }
  let workspace = @fs.realpath(workspace) catch { _ => workspace }
  let scratch = @fs.realpath(scratch) catch { _ => scratch }
  let shell = @fs.realpath("/bin/sh") catch { _ => "/bin/sh" }
  let probe_profile = local_profile("probe", workspace, scratch).allow_degraded()
  let policy = local_sbpl_profile(probe_profile, shell)
  let allowed_path = "\{scratch}/allowed"
  let blocked_path = "\{workspace}/blocked"
  let secret_path = "\{workspace}/secret"
  @fs.write_file(
    secret_path,
    "host-secret",
    create_mode=CreateNew,
    permission=0o600,
  ) catch {
    error if @async.is_being_cancelled() => raise error
    _ => {
      ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
      ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
      return "cannot create probe secret"
    }
  }
  let allowed = probe_process_exit(
    SandboxExecPath,
    ["-p", policy, shell, "-c", "printf probe > \{shell_quote(allowed_path)}"],
    scratch,
  )
  let write = probe_process_exit(
    SandboxExecPath,
    ["-p", policy, shell, "-c", "printf probe > \{shell_quote(blocked_path)}"],
    scratch,
  )
  let read = probe_process_exit(
    SandboxExecPath,
    [
      "-p",
      policy,
      shell,
      "-c",
      "IFS= read -r line < \{shell_quote(secret_path)}",
    ],
    scratch,
  )
  let marker = @fs.exists(allowed_path)
  let escaped_write = @fs.exists(blocked_path)
  ignore(@fs.remove(allowed_path) catch { _ => () })
  ignore(@fs.remove(blocked_path) catch { _ => () })
  ignore(@fs.remove(secret_path) catch { _ => () })
  ignore(@fs.rmdir(workspace) catch { _ => () })
  ignore(@fs.rmdir(scratch) catch { _ => () })
  if allowed != Some(0) {
    "scratch write failed with exit \{Repr(allowed)}"
  } else if !marker {
    "scratch write exited successfully without creating its marker"
  } else if write == Some(0) || escaped_write {
    "canonical workspace write was not denied"
  } else if read == Some(0) {
    "canonical workspace read was not denied"
  } else {
    ""
  }
}

///|
async fn probe_process_exit(
  executable : String,
  args : Array[String],
  cwd : String,
) -> Int? {
  let (exit_code, _) = @process.collect_output_merged(
    executable,
    args,
    inherit_env=false,
    cwd~,
  ) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  Some(exit_code)
}

///|
/// Execute under the platform local-OS backend and always return a receipt. There is no
/// unsandboxed fallback. The local backend requires explicit degraded opt-in.
pub async fn run_local_sandbox(
  profile : SandboxProfile,
  command : SandboxCommand,
  tools : Array[LocalSandboxTool],
  working_directory? : String = "",
) -> SandboxReceipt {
  // The native supervisor is intentionally single-flight. Serialize the
  // behavioral probe, snapshot, launch, and inventory as one operation so a
  // concurrent run cannot turn a valid sandbox into an ambiguous setup error.
  local_backend_mutex.acquire()
  defer local_backend_mutex.release()
  if !(profile.backend is LocalOs) {
    return refused_receipt(
      profile.run_id,
      LocalOs,
      profile_digest(profile),
      "run_local_sandbox requires the LocalOs backend",
    )
  }
  // Validate before probing or canonicalizing, so strict and malformed calls
  // fail deterministically without executing any host process.
  let initial = prepare_sandbox_command(
    profile,
    command,
    BackendDegraded(
      match local_os_platform() {
        MacOs => MacLocalDegradedReason
        Linux => LinuxLocalDegradedReason
        Unsupported => "unsupported local operating system"
      },
    ),
  )
  guard initial.prepared() is Some(_) else {
    return preparation_refused_receipt(profile, initial)
  }
  if !(profile.network is Deny) {
    return refused_receipt(
      profile.run_id,
      LocalOs,
      profile_digest(profile),
      "local backend currently supports only deny network policy",
    )
  }
  let canonical = canonical_local_profile(profile) catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      return refused_receipt(
        profile.run_id,
        LocalOs,
        profile_digest(profile),
        "failed to canonicalize sandbox roots: \{error}",
      )
  }
  let live_output_path = if canonical.executor_evidence_root == "" {
    ""
  } else {
    let root = canonical.executor_evidence_root
    guard @fs.realpath(root) == root &&
      @fs.kind(root, follow_symlink=false) is Directory &&
      sandbox_private_directory(root) else {
      return refused_receipt(
        canonical.run_id,
        LocalOs,
        profile_digest(canonical),
        "executor evidence root is not a canonical private directory",
      )
    }
    let path = root + "/" + canonical.live_output_id + ".blob"
    guard !(@fs.exists(path) catch { _ => true }) else {
      return refused_receipt(
        canonical.run_id,
        LocalOs,
        profile_digest(canonical),
        "live output destination already exists",
      )
    }
    path
  }
  if !safe_local_working_directory(working_directory) {
    return refused_receipt(
      canonical.run_id,
      LocalOs,
      profile_digest(canonical),
      "working directory is not a safe workspace-relative path",
    )
  }
  let prepared = prepare_sandbox_command(
    canonical,
    command,
    local_backend_readiness_unlocked(),
  )
  guard prepared.prepared() is Some(checked) else {
    return preparation_refused_receipt(canonical, prepared)
  }
  let disk_limit_bytes = canonical.limits.disk_mib.to_int64() * 1024L * 1024L
  let baseline = match
    materialize_workspace_snapshot(
      canonical.workspace_root,
      canonical.scratch_root,
      disk_limit_bytes~,
    ) {
    Ok(value) => value
    Err(reason) =>
      return refused_receipt(
        canonical.run_id,
        LocalOs,
        checked.profile_digest(),
        "failed to materialize private workspace snapshot: \{reason.code()}",
      )
  }
  let process_cwd = if working_directory == "" {
    canonical.scratch_root
  } else {
    "\{canonical.scratch_root}/\{working_directory}"
  }
  let verified_cwd = @fs.realpath(process_cwd) catch {
    error if @async.is_being_cancelled() => raise error
    _ =>
      return refused_receipt(
        canonical.run_id,
        LocalOs,
        checked.profile_digest(),
        "working directory does not exist in the private snapshot",
      )
  }
  if verified_cwd != process_cwd ||
    !(@fs.kind(process_cwd, follow_symlink=false) is Directory) {
    return refused_receipt(
      canonical.run_id,
      LocalOs,
      checked.profile_digest(),
      "working directory is not a canonical directory in the private snapshot",
    )
  }
  let invocation = local_invocation(checked, tools, working_directory) catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      return refused_receipt(
        canonical.run_id,
        LocalOs,
        checked.profile_digest(),
        "failed to prepare local invocation: \{error}",
      )
  }
  let receipt = execute_local_invocation(
    checked,
    invocation,
    process_cwd,
    live_output_path~,
  )
  match inventory_scratch(canonical.scratch_root, disk_limit_bytes) {
    Err(reason) =>
      failed_receipt(
        canonical.run_id,
        LocalOs,
        Degraded,
        checked.profile_digest(),
        "post-run scratch inventory failed: \{reason.code()}",
      )
    Ok(after) =>
      match
        bind_receipt_scratch_result(receipt, diff_scratch(baseline, after), []) {
        Ok(bound) => bound
        Err(reason) =>
          failed_receipt(
            canonical.run_id,
            LocalOs,
            Degraded,
            checked.profile_digest(),
            "failed to bind scratch result: \{reason.code()}",
          )
      }
  }
}

///|
fn safe_local_working_directory(path : String) -> Bool {
  path == "" ||
  (
    !path.has_prefix("/") &&
    !path.has_suffix("/") &&
    !path.contains("//") &&
    !path.contains("\u{0}") &&
    @utf8.encode(path).length() <= 4096 &&
    !path.split("/").any(component => component == "." || component == "..")
  )
}

///|
async fn canonical_local_profile(profile : SandboxProfile) -> SandboxProfile {
  let workspace_root = @fs.realpath(profile.workspace_root)
  let scratch_root = @fs.realpath(profile.scratch_root)
  let read_only_roots : Array[String] = []
  for root in profile.read_only_roots {
    read_only_roots.push(@fs.realpath(root))
  }
  let canonical = { ..profile, workspace_root, scratch_root, read_only_roots }
  let rejection = profile_rejection(canonical)
  if rejection != "" {
    fail(rejection)
  }
  canonical
}

///|
priv struct LocalInvocation {
  argv : Array[String]
  environment : Map[String, String]
}

///|
async fn local_invocation(
  prepared : PreparedSandboxCommand,
  tools : Array[LocalSandboxTool],
  working_directory : String,
) -> LocalInvocation {
  let profile = prepared.profile()
  let (executable, command_args) = match prepared.command() {
    Exec(tool~, args~) => {
      guard tools.search_by(binding => binding.capability_label == tool)
        is Some(index) else {
        fail("no trusted executable binding for capability \{tool}")
      }
      let binding = tools[index]
      guard binding.executable_path.has_prefix("/") else {
        fail("local executable binding must be absolute")
      }
      (@fs.realpath(binding.executable_path), args)
    }
    Shell(script~) => (@fs.realpath("/bin/sh"), ["-c", script])
  }
  if executable == profile.workspace_root ||
    executable.has_prefix(profile.workspace_root + "/") ||
    executable == profile.scratch_root ||
    executable.has_prefix(profile.scratch_root + "/") {
    fail("trusted executable must not reside in workspace or writable scratch")
  }
  match local_os_platform() {
    MacOs => {
      let policy = local_sbpl_profile(profile, executable)
      {
        argv: [SandboxExecPath, "-p", policy, executable, ..command_args],
        environment: {
          "HOME": profile.scratch_root,
          "TMPDIR": profile.scratch_root,
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
          "LANG": "C.UTF-8",
        },
      }
    }
    Linux => {
      guard linux_bubblewrap_path() is Some(bwrap) else {
        fail("bubblewrap executable is unavailable")
      }
      {
        argv: [
          bwrap,
          ..linux_bubblewrap_arguments(
            profile, executable, command_args, working_directory,
          ),
        ],
        environment: {
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
          "LANG": "C.UTF-8",
        },
      }
    }
    Unsupported => fail("unsupported local operating system")
  }
}

///|
fn local_sbpl_profile(profile : SandboxProfile, executable : String) -> String {
  let policy = StringBuilder()
  policy <+
    $|(version 1)
    $|(deny default)
    $|(allow process*)
    $|(allow sysctl-read)
    $|(allow mach-lookup)
    $|(deny network*)
    $|(allow file-read-data)
    $|(deny file-read* (subpath "/"))
    $|(allow file-read* (subpath "/System"))
    $|(allow file-read* (subpath "/usr/bin"))
    $|(allow file-read* (subpath "/bin"))
    $|(allow file-read* (subpath "/usr/sbin"))
    $|(allow file-read* (subpath "/sbin"))
    $|(allow file-read* (subpath "/usr/lib"))
    $|(allow file-read* (subpath "/usr/share"))
    $|(allow file-read* (subpath "/Library/Apple/System"))
    $|(allow file-read* (literal "/dev/null"))
    $|(allow file-read* (literal "/dev/urandom"))
    $|(allow file-read* (literal "\{sbpl_escape(executable)}"))
  for root in profile.read_only_roots {
    if root != profile.workspace_root {
      policy <+
        $|(allow file-read* (subpath "\{sbpl_escape(root)}"))
    }
  }
  policy <+
    $|(allow file-read* (subpath "\{sbpl_escape(profile.scratch_root)}"))
    $|(allow file-write* (subpath "\{sbpl_escape(profile.scratch_root)}"))
  // Keep these denials last. SBPL is last-match-wins, and an attacker must not
  // be able to re-open a canonical read root through an alias or future
  // writable carve-out.
  policy <+
    $|(deny file-read* (subpath "\{sbpl_escape(profile.workspace_root)}"))
  for root in profile.read_only_roots {
    policy <+
      $|(deny file-write* (subpath "\{sbpl_escape(root)}"))
  }
  policy.to_string()
}

///|
async fn execute_local_invocation(
  prepared : PreparedSandboxCommand,
  invocation : LocalInvocation,
  process_cwd : String,
  live_output_path~ : String,
) -> SandboxReceipt {
  let profile = prepared.profile()
  let capture_root = @fs.tmpdir(prefix="moonfort-supervisor-capture-") catch {
    error if @async.is_being_cancelled() => raise error
    error =>
      return failed_receipt(
        profile.run_id,
        LocalOs,
        Degraded,
        prepared.profile_digest(),
        "failed to create private supervisor capture: \{error}",
      )
  }
  let capture_root = @fs.realpath(capture_root) catch {
    error => {
      cleanup_supervisor_capture(capture_root, "")
      return failed_receipt(
        profile.run_id,
        LocalOs,
        Degraded,
        prepared.profile_digest(),
        "failed to canonicalize private supervisor capture: \{error}",
      )
    }
  }
  if capture_root == profile.scratch_root ||
    capture_root.has_prefix(profile.scratch_root + "/") {
    cleanup_supervisor_capture(capture_root, "")
    return failed_receipt(
      profile.run_id,
      LocalOs,
      Degraded,
      prepared.profile_digest(),
      "private supervisor capture resolved inside writable scratch",
    )
  }
  let capture_path = if live_output_path == "" {
    "\{capture_root}/merged-output"
  } else {
    live_output_path
  }
  let removable_capture_path = if live_output_path == "" {
    capture_path
  } else {
    ""
  }
  let native_request : @local_supervisor.Request = {
    argv: invocation.argv,
    cwd: process_cwd,
    environment: invocation.environment,
    output_path: capture_path,
    disk_root: profile.scratch_root,
    output_bytes: profile.limits.output_bytes.to_int64(),
    limits: {
      wall_clock_ms: profile.limits.wall_clock_ms.to_int64(),
      cpu_seconds: profile.limits.cpu_seconds.to_int64(),
      address_space_bytes: profile.limits.memory_mib.to_int64() * 1024L * 1024L,
      file_size_bytes: profile.limits.disk_mib.to_int64() * 1024L * 1024L,
      open_files: 256L,
      processes: profile.limits.processes.to_int64(),
      aggregate_disk_bytes: profile.limits.disk_mib.to_int64() * 1024L * 1024L,
    },
  }
  let native_result = @local_supervisor.run(native_request) catch {
    error => {
      cleanup_supervisor_capture(capture_root, removable_capture_path)
      return failed_receipt(
        profile.run_id,
        LocalOs,
        Degraded,
        prepared.profile_digest(),
        "native supervisor protocol failed: \{Repr(error)}",
      )
    }
  }
  let output = try @fs.read_file(capture_path) catch {
    _ => ""
  } noraise {
    data => @utf8.decode_lossy(data.binary())
  }
  cleanup_supervisor_capture(capture_root, removable_capture_path)
  let required_limit_mask = if local_os_platform() is MacOs { 61 } else { 63 }
  if native_result.kind != "setup_failed" &&
    native_result.kind != "monitor_unverified" &&
    native_result.kind != "cleanup_unverified" &&
    (native_result.applied_limits & required_limit_mask) != required_limit_mask {
    return failed_receipt(
      profile.run_id,
      LocalOs,
      Degraded,
      prepared.profile_digest(),
      "native supervisor did not attest every required resource limit",
    )
  }
  let receipt = match native_result.kind {
    "timed_out" =>
      killed_receipt(
        profile.run_id,
        LocalOs,
        Degraded,
        prepared.profile_digest(),
        output,
        false,
        "wall-clock-limit",
      )
    "limit_exceeded" => {
      let reason = match native_result.limit {
        Some("output") => "output-limit"
        Some("cpu") => "cpu-limit"
        Some("file_size") => "file-size-limit"
        Some("aggregate_disk") => "aggregate-disk-limit"
        Some("disk_entries") => "disk-entry-limit"
        Some("process_count") => "process-count-limit"
        Some(limit) => "\{limit}-limit"
        None => "resource-limit"
      }
      killed_receipt(
        profile.run_id,
        LocalOs,
        Degraded,
        prepared.profile_digest(),
        output,
        native_result.limit == Some("output"),
        reason,
      )
    }
    "exited" =>
      match native_result.exit_code {
        Some(exit_code) =>
          exited_receipt(
            profile.run_id,
            LocalOs,
            Degraded,
            prepared.profile_digest(),
            exit_code,
            output,
          )
        None =>
          failed_receipt(
            profile.run_id,
            LocalOs,
            Degraded,
            prepared.profile_digest(),
            "native supervisor omitted exit code",
          )
      }
    "signaled" | "interrupted" =>
      killed_receipt(
        profile.run_id,
        LocalOs,
        Degraded,
        prepared.profile_digest(),
        output,
        false,
        match native_result.signal {
          Some(signal) => "signal-\{signal}"
          None => "signal"
        },
      )
    "setup_failed" =>
      failed_receipt(
        profile.run_id,
        LocalOs,
        Degraded,
        prepared.profile_digest(),
        "native supervisor setup failed at \{native_result.setup_stage.unwrap_or("unknown")} (errno \{native_result.os_errno.unwrap_or(0)})",
      )
    "cleanup_unverified" =>
      refused_receipt(
        profile.run_id,
        LocalOs,
        prepared.profile_digest(),
        "native supervisor could not verify descendant cleanup",
      )
    "monitor_unverified" =>
      refused_receipt(
        profile.run_id,
        LocalOs,
        prepared.profile_digest(),
        "native supervisor could not verify \{native_result.limit.unwrap_or("aggregate-resource")} monitoring",
      )
    kind =>
      failed_receipt(
        profile.run_id,
        LocalOs,
        Degraded,
        prepared.profile_digest(),
        "native supervisor returned unknown result kind \{kind}",
      )
  }
  {
    ..receipt
    // POSIX rlimits are per process and the byte/process monitors are sampled.
    // The platform sandbox adds filesystem/network isolation but cannot turn
    // a shared host kernel into a microVM boundary.
    // Keep these explicit on every local receipt; `Degraded` is never upgraded.
    ,
    unverified_limits: [
      "aggregate-cpu",
      "aggregate-memory",
      "hard-disk-quota",
      "filesystem-inode-quota",
      "hard-process-quota",
      ..if (native_result.applied_limits & 2) == 0 {
        ["per-process-address-space"]
      } else {
        []
      },
      ..if local_os_platform() is MacOs {
        ["detached-descendant-processes"]
      } else {
        ["nested-user-namespaces"]
      },
    ],
  }
}

///|
async fn cleanup_supervisor_capture(root : String, output : String) -> Unit {
  if output != "" {
    ignore(@fs.remove(output) catch { _ => () })
  }
  ignore(@fs.rmdir(root) catch { _ => () })
}

///|
fn preparation_refused_receipt(
  profile : SandboxProfile,
  preparation : SandboxPreparation,
) -> SandboxReceipt {
  let reason = match preparation.refusal() {
    Some(refusal) => refusal.message()
    None => "sandbox preparation failed without a reason"
  }
  refused_receipt(
    profile.run_id,
    profile.backend,
    profile_digest(profile),
    reason,
  )
}

///|
fn sbpl_escape(text : String) -> String {
  text
  .replace_all(old="\\", new="\\\\")
  .replace_all(old="\"", new="\\\"")
  .replace_all(old="\n", new="\\n")
  .replace_all(old="\r", new="\\r")
}

///|
fn shell_quote(text : String) -> String {
  "'\{text.replace_all(old="'", new="'\\''")}'"
}
