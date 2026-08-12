///|
async fn[T : AenTransport] AenBackend::refused_exec_receipt(
  self : AenBackend[T],
  reason : String,
) -> @sandbox.SandboxReceipt {
  let cleanup_verified = self.discard_protected()
  self.refused_after_cleanup(reason, cleanup_verified)
}

///|
fn[T] AenBackend::guest_argv(
  self : AenBackend[T],
  prepared : @sandbox.PreparedSandboxCommand,
) -> (String, Array[String]) raise AenBackendError {
  let label = prepared.capability_label()
  let executable = match self.guest_tools.get(label) {
    Some(path) => path
    None => raise InvalidConfiguration("missing guest binding for \{label}")
  }
  let command_args = match prepared.command() {
    Exec(args~, ..) => args
    Shell(script~) => ["-lc", script]
  }
  (
    self.guest_supervisor,
    [
      "run",
      "--contract",
      GuestAttestationContract,
      "--profile-digest",
      self.digest,
      "--cpu-seconds",
      self.profile.limits.cpu_seconds.to_string(),
      "--process-limit",
      self.profile.limits.processes.to_string(),
      "--scratch-disk-mib",
      self.profile.limits.disk_mib.to_string(),
      "--scratch",
      self.guest_scratch,
      "--wall-clock-ms",
      self.profile.limits.wall_clock_ms.to_string(),
      "--output-bytes",
      self.profile.limits.output_bytes.to_string(),
      "--",
      executable,
      ..command_args,
    ],
  )
}

///|
async fn[T : AenTransport] AenBackend::signal_process(
  self : AenBackend[T],
  pid : Int?,
) -> Bool {
  guard self.sandbox_id is Some(id) && pid is Some(value) else { return false }
  let response = self.transport.request(
    envd_signal_request(self.api_key, id, value, ControlTimeoutMs),
  ) catch {
    _ => return false
  }
  response.status >= 200 && response.status < 300
}

///|
async fn[T : AenTransport] AenBackend::terminate_and_finish_manifest(
  self : AenBackend[T],
  sandbox_id : String,
  watcher_id : String,
  pid : Int?,
) -> (Result[(Array[String], @sandbox.ScratchDiff), Error], Bool) {
  @async.protect_from_cancel(
    () => {
      ignore(self.signal_process(pid))
      let changed : Result[(Array[String], @sandbox.ScratchDiff), Error] = Ok(
        (
          self.finish_diff_manifest(sandbox_id, watcher_id),
          if self.require_guest_attestation {
            self.inventory_guest_changes(sandbox_id)
          } else {
            { entries: [], before_bytes: 0L, after_bytes: 0L }
          },
        ),
      ) catch {
        error => Err(error)
      }
      (changed, self.discard_checked())
    },
    resume_on_cancel=true,
  ) catch {
    error => (Err(error), false)
  }
}

///|
/// Execute only an opaque command previously checked by MoonFort's capability
/// preflight. envd output is decoded incrementally and retained in order up to
/// `output_bytes`. `guest_workspace` is the VM-private COW view of the source
/// snapshot, never the canonical host path; only `guest_scratch` is watched for
/// the bounded changed-path manifest. The stream has an independent byte cap
/// and whole-request deadline. Reaching either bound closes the stream, sends
/// SIGKILL when a PID is known, and always deletes the VM so descendants cannot
/// survive.
pub async fn[T : AenTransport] AenBackend::exec(
  self : AenBackend[T],
  prepared : @sandbox.PreparedSandboxCommand,
  working_directory? : String = "",
) -> @sandbox.SandboxReceipt {
  guard self.state is Running && self.sandbox_id is Some(id) else {
    return self.refused_exec_receipt(
      "AEN exec requires an attested running sandbox",
    )
  }
  guard prepared.profile_digest() == self.digest &&
    prepared.profile().run_id == self.profile.run_id &&
    prepared.enforcement() is Enforced else {
    return self.refused_exec_receipt(
      "prepared command is not bound to this enforced run",
    )
  }
  guard safe_guest_working_directory(working_directory) else {
    return self.refused_exec_receipt(
      "working directory is not a safe workspace-relative path",
    )
  }
  let process_cwd = if working_directory == "" {
    self.guest_scratch
  } else {
    "\{self.guest_scratch}/\{working_directory}"
  }
  let (executable, arguments) = self.guest_argv(prepared) catch {
    _ => return self.refused_exec_receipt("AEN guest command binding failed")
  }
  let watcher_id = self.begin_diff_manifest(id) catch {
    _ =>
      return self.refused_exec_receipt(
        "AEN could not establish trusted scratch diff watcher",
      )
  }
  let output_limit = self.profile.limits.output_bytes
  let decoder = ConnectDecoder::new(max_frame_bytes=output_limit + 65_536)
  let output = @buffer.Buffer(size_hint=output_limit.min(8_192))
  let mut pid : Int? = None
  let mut exit_code : Int? = None
  let mut process_status = ""
  let mut connect_error : String? = None
  let mut output_limited = false
  let payload = encode_start_request(executable, arguments, process_cwd)
  let request = envd_start_request(
    self.api_key,
    id,
    payload,
    self.profile.limits.wall_clock_ms,
    output_limit + 1_048_576,
  )
  let stream_result : Result[Unit, Error] = try {
    self.transport.stream(request, consume=chunk => {
      let events = decoder.feed(chunk) catch {
        _ => {
          connect_error = Some("invalid Connect stream")
          return StopStream
        }
      }
      for event in events {
        match event {
          ProcessStarted(value) => pid = Some(value)
          Stdout(bytes) | Stderr(bytes) => {
            let remaining = output_limit - output.length()
            if bytes.length() > remaining {
              if remaining > 0 {
                output.write_bytes(bytes[:remaining].to_owned())
              }
              output_limited = true
              return StopStream
            }
            output.write_bytes(bytes)
          }
          ProcessExited(code, status) => {
            exit_code = Some(code)
            process_status = status
          }
          ConnectEnded(error) => {
            connect_error = error.map(_ => "remote Connect error")
            return StopStream
          }
        }
      }
      ContinueStream
    })
    Ok(())
  } catch {
    error => Err(error)
  }
  if output_limited {
    let (changed_result, cleanup_verified) = self.terminate_and_finish_manifest(
      id, watcher_id, pid,
    )
    if !cleanup_verified {
      return self.refused_exec_receipt(
        "output limit reached and VM termination could not be verified",
      )
    }
    let (changed_paths, diff) = match changed_result {
      Ok(value) => value
      Err(_) =>
        return self.refused_exec_receipt(
          "AEN output-limited run has no trusted diff manifest",
        )
    }
    return {
      ..@sandbox.killed_receipt(
        self.profile.run_id,
        MicroVm,
        Enforced,
        self.digest,
        @utf8.decode_lossy(output.to_bytes()),
        true,
        "output_bytes",
      ),
      changed_paths,
      changes: diff.entries,
      cleanup_verified: true,
      retention_id: None,
    }
  }
  match stream_result {
    Err(error) => {
      let (_, cleanup_verified) = self.terminate_and_finish_manifest(
        id, watcher_id, pid,
      )
      if @async.is_cancellation_error(error) {
        self.state = Refused
        raise error
      }
      return self.refused_after_cleanup(
        "AEN execution stream failed", cleanup_verified,
      )
    }
    Ok(_) => ()
  }
  guard connect_error is None && decoder.ended() && exit_code is Some(code) else {
    let (_, cleanup_verified) = self.terminate_and_finish_manifest(
      id, watcher_id, pid,
    )
    let reason = match connect_error {
      Some(_) => "AEN Connect stream reported an error"
      None => "AEN Connect stream ended without a terminal process event"
    }
    return self.refused_after_cleanup(reason, cleanup_verified)
  }
  let changed_paths = self.finish_diff_manifest(id, watcher_id) catch {
    _ => {
      let cleanup_verified = self.discard_protected()
      return self.refused_after_cleanup(
        "AEN terminal run has no trusted diff manifest", cleanup_verified,
      )
    }
  }
  let diff = try {
    if self.require_guest_attestation {
      self.inventory_guest_changes(id)
    } else {
      { entries: [], before_bytes: 0L, after_bytes: 0L }
    }
  } catch {
    _ => {
      let cleanup_verified = self.discard_protected()
      return self.refused_after_cleanup(
        "AEN terminal run has no trusted structured diff", cleanup_verified,
      )
    }
  }
  let rendered = @utf8.decode_lossy(output.to_bytes())
  {
    // The guest process exited, but the backing VM remains live so callers can
    // snapshot/reset/fork it. Keep the lifecycle status non-terminal; only the
    // one-shot facade may emit Exited after preservation and verified cleanup.
    ..self.base_receipt(Running),
    exit_code: Some(code),
    output: rendered,
    changed_paths,
    changes: diff.entries,
    denial_reason: if process_status == "" || process_status == "exited" {
      None
    } else {
      Some("AEN process returned a nonstandard terminal status")
    },
  }
}

///|
fn safe_guest_working_directory(path : String) -> Bool {
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
