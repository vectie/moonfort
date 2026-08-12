///|
const LinuxLocalDegradedReason : String = "bubblewrap namespaces plus the native supervisor enforce filesystem and network isolation with bounded execution, but the shared host kernel and sampled aggregate limits remain a best-effort boundary"

///|
priv enum LinuxProbeOutcome {
  LinuxProbeReady
  LinuxProbeUnavailable(String)
  LinuxProbeMisconfigured(String)
}

///|
async fn linux_bubblewrap_path() -> String? {
  for candidate in ["/usr/bin/bwrap", "/bin/bwrap"] {
    if @fs.exists(candidate) {
      let resolved = @fs.realpath(candidate) catch { _ => "" }
      if resolved.has_prefix("/") &&
        @fs.kind(resolved, follow_symlink=false) is Regular {
        return Some(resolved)
      }
    }
  }
  None
}

///|
fn linux_standard_runtime_root(root : String) -> Bool {
  ["/usr", "/bin", "/sbin", "/lib", "/lib64"].any(standard => {
    root == standard || root.has_prefix(standard + "/")
  })
}

///|
fn linux_reserved_guest_mount(root : String) -> Bool {
  if root == "/" ||
    root == "/etc" ||
    root == "/home" ||
    root == "/root" ||
    root == "/var" {
    return true
  }
  ["/workspace", "/proc", "/sys", "/dev", "/tmp", "/run"].any(reserved => {
    roots_overlap(root, reserved)
  })
}

///|
fn linux_guest_working_directory(working_directory : String) -> String {
  if working_directory == "" {
    "/workspace"
  } else {
    "/workspace/\{working_directory}"
  }
}

///|
fn linux_bubblewrap_arguments(
  profile : SandboxProfile,
  executable : String,
  command_args : ArrayView[String],
  working_directory : String,
) -> Array[String] raise {
  if !path_is_canonical_absolute(executable) {
    fail("Linux sandbox executable must be a canonical absolute path")
  }
  if !safe_local_working_directory(working_directory) {
    fail("Linux sandbox working directory must be workspace-relative")
  }
  if executable == profile.workspace_root ||
    executable.has_prefix(profile.workspace_root + "/") ||
    executable == profile.scratch_root ||
    executable.has_prefix(profile.scratch_root + "/") {
    fail("trusted executable must not reside in workspace or writable scratch")
  }
  let args = [
    "--die-with-parent", "--new-session", "--unshare-all", "--unshare-user", "--unshare-net",
    "--cap-drop", "ALL", "--clearenv", "--hostname", "moonfort",
  ]
  // Bind only runtime trees, never the host root. In particular, /etc, /home,
  // /root, and /var are absent. Reserved namespace locations cannot be opened
  // through configured read-only roots.
  for root in ["/usr", "/bin", "/sbin", "/lib", "/lib64"] {
    args.push("--ro-bind-try")
    args.push(root)
    args.push(root)
  }
  args.push("--ro-bind-try")
  args.push("/etc/ld.so.cache")
  args.push("/etc/ld.so.cache")
  for root in profile.read_only_roots {
    if root == profile.workspace_root || linux_standard_runtime_root(root) {
      continue
    }
    if linux_reserved_guest_mount(root) {
      fail(
        "read-only root collides with a reserved Linux sandbox mount: \{root}",
      )
    }
    args.push("--ro-bind")
    args.push(root)
    args.push(root)
  }
  if !linux_standard_runtime_root(executable) {
    args.push("--ro-bind")
    args.push(executable)
    args.push(executable)
  }
  args.push("--proc")
  args.push("/proc")
  args.push("--dev")
  args.push("/dev")
  args.push("--bind")
  args.push(profile.scratch_root)
  args.push("/workspace")
  args.push("--chdir")
  args.push(linux_guest_working_directory(working_directory))
  for
    pair in [
      ("HOME", "/workspace"),
      ("TMPDIR", "/workspace"),
      ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
      ("LANG", "C.UTF-8"),
    ] {
    let (key, value) = pair
    args.push("--setenv")
    args.push(key)
    args.push(value)
  }
  // The namespace root itself is immutable. The scratch bind and kernel
  // pseudo-filesystems are separate mounts; scratch is the only persistent
  // writable filesystem visible to the command.
  args.push("--remount-ro")
  args.push("/")
  args.push("--")
  args.push(executable)
  args.push_iter(command_args.iter())
  args
}

///|
async fn diagnose_linux_bubblewrap() -> LinuxProbeOutcome {
  guard linux_bubblewrap_path() is Some(bwrap) else {
    return LinuxProbeUnavailable("bubblewrap executable is absent")
  }
  let workspace = @fs.tmpdir(prefix="moonfort-linux-probe-source-") catch {
    error if @async.is_being_cancelled() => raise error
    _ => return LinuxProbeMisconfigured("cannot allocate probe workspace")
  }
  let scratch = @fs.tmpdir(prefix="moonfort-linux-probe-scratch-") catch {
    error if @async.is_being_cancelled() => raise error
    _ => {
      ignore(@fs.rmdir(workspace) catch { _ => () })
      return LinuxProbeMisconfigured("cannot allocate probe scratch")
    }
  }
  let workspace = @fs.realpath(workspace) catch { _ => workspace }
  let scratch = @fs.realpath(scratch) catch { _ => scratch }
  let shell = @fs.realpath("/bin/sh") catch { _ => "/bin/sh" }
  let profile = local_profile("linux-probe", workspace, scratch).allow_degraded()
  let script = "printf probe > /workspace/allowed && test ! -e \{shell_quote(workspace)} && { routes=0; while IFS= read -r line; do routes=$((routes + 1)); done < /proc/net/route; test \"$routes\" -le 1; }"
  let arguments = linux_bubblewrap_arguments(profile, shell, ["-c", script], "") catch {
    error => {
      ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
      ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
      return LinuxProbeMisconfigured("failed to build probe: \{error}")
    }
  }
  let (exit_code, output) = @process.collect_output_merged(bwrap, arguments) catch {
    error if @async.is_being_cancelled() => raise error
    error => {
      ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
      ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
      return LinuxProbeMisconfigured(
        "bubblewrap probe could not start: \{error}",
      )
    }
  }
  let marker = @fs.exists("\{scratch}/allowed")
  let diagnostic = output.text().trim().to_owned()
  ignore(@fs.rmdir(workspace, recursive=true) catch { _ => () })
  ignore(@fs.rmdir(scratch, recursive=true) catch { _ => () })
  if exit_code == 0 && marker {
    LinuxProbeReady
  } else {
    let lower = diagnostic.to_lower()
    if lower.contains("operation not permitted") ||
      lower.contains("no permissions to create") ||
      lower.contains("user namespace") ||
      lower.contains("namespaces are not supported") {
      LinuxProbeUnavailable(
        if diagnostic == "" {
          "kernel namespace enforcement is unavailable"
        } else {
          diagnostic
        },
      )
    } else {
      LinuxProbeMisconfigured(
        "bubblewrap exited \{exit_code} without proving enforcement: \{diagnostic}",
      )
    }
  }
}
