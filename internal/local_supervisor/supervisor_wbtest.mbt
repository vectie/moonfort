///|
extern "c" fn native_pid() -> Int = "moonfort_local_supervisor_getpid"

///|
#borrow(path)
extern "c" fn read_pid_file(path : Bytes) -> Int = "moonfort_local_supervisor_read_pid_file"

///|
extern "c" fn wait_pid_gone(pid : Int, timeout_ms : Int) -> Bool = "moonfort_local_supervisor_wait_pid_gone"

///|
#borrow(path)
extern "c" fn unlink_file(path : Bytes) -> Unit = "moonfort_local_supervisor_unlink"

///|
extern "c" fn open_inherited_test_fd() -> Int = "moonfort_local_supervisor_test_open_inherited_fd"

///|
extern "c" fn close_test_fd(fd : Int) -> Unit = "moonfort_local_supervisor_test_close_fd"

///|
#borrow(path)
extern "c" fn prepare_test_directory(path : Bytes) -> Bool = "moonfort_local_supervisor_test_prepare_directory"

///|
#borrow(path)
extern "c" fn cleanup_test_directory(path : Bytes) -> Unit = "moonfort_local_supervisor_test_cleanup_directory"

///|
fn test_limits(wall_clock_ms : Int64) -> Limits {
  {
    wall_clock_ms,
    cpu_seconds: 2L,
    address_space_bytes: 1L << 60,
    file_size_bytes: 1024L * 1024L,
    open_files: 64L,
    processes: 64L,
    aggregate_disk_bytes: 1L << 60,
  }
}

///|
extern "c" fn supervisor_test_platform() -> Int = "moonfort_local_supervisor_test_platform"

///|
fn test_request(argv : Array[String], wall_clock_ms : Int64) -> Request {
  {
    argv,
    cwd: "/tmp",
    environment: { "PATH": "/usr/bin:/bin", "LC_ALL": "C" },
    output_path: "/tmp/moonfort-supervisor-output-\{native_pid()}.log",
    disk_root: "",
    output_bytes: 1024L * 1024L,
    limits: test_limits(wall_clock_ms),
  }
}

///|
test "native supervisor fails closed and propagates exit" {
  let exit_request = test_request(["/usr/bin/true"], 2000L)
  unlink_file(@utf8.encode(exit_request.output_path))
  let exited = run(exit_request)
  inspect(exited.kind, content="exited")
  debug_inspect(exited.exit_code, content="Some(0)")
  inspect(exited.applied_limits, content="47")

  let missing_request = {
    ..test_request(["/definitely/not/a/moonfort-command"], 2000L),
    output_path: "/tmp/moonfort-supervisor-missing-\{native_pid()}.log",
  }
  unlink_file(@utf8.encode(missing_request.output_path))
  let missing = run(missing_request)
  inspect(missing.kind, content="setup_failed")
  debug_inspect(missing.setup_stage, content="Some(\"exec\")")
  debug_inspect(missing.exit_code, content="None")
}

///|
test "native supervisor kills stubborn descendants on deadline" {
  let pid_path = "/tmp/moonfort-supervisor-descendant-\{native_pid()}.pid"
  unlink_file(@utf8.encode(pid_path))
  let script = "(trap '' TERM HUP INT; while :; do sleep 1; done) & echo $! > '\{pid_path}'; wait"
  let request = test_request(["/bin/sh", "-c", script], 250L)
  unlink_file(@utf8.encode(request.output_path))
  let result = run(request)
  inspect(result.kind, content="timed_out")
  debug_inspect(result.limit, content="Some(\"wall_clock\")")
  let descendant = read_pid_file(@utf8.encode(pid_path))
  assert_true(descendant > 0)
  // Under a highly parallel full-suite run the killed orphan can remain as a
  // non-executing zombie until launchd reaps it. Give the system reaper a
  // bounded window without weakening the supervisor's 250 ms kill deadline.
  assert_true(wait_pid_gone(descendant, 10000))
  unlink_file(@utf8.encode(pid_path))
}

///|
test "native supervisor enforces CPU and file size limits" {
  // RLIMIT_CPU measures scheduled CPU time, not elapsed time. Leave enough
  // wall-clock headroom for this process to accumulate one CPU second while
  // the full native suite is running other CPU-heavy supervisor fixtures.
  let cpu_base = test_request(["/bin/sh", "-c", "while :; do :; done"], 30000L)
  let cpu_request = {
    ..cpu_base,
    limits: { ..cpu_base.limits, cpu_seconds: 1L },
  }
  unlink_file(@utf8.encode(cpu_request.output_path))
  let cpu = run(cpu_request)
  inspect(cpu.kind, content="limit_exceeded")
  debug_inspect(cpu.limit, content="Some(\"cpu\")")

  let output_path = "/tmp/moonfort-supervisor-fsize-\{native_pid()}.bin"
  unlink_file(@utf8.encode(output_path))
  let file_base = test_request(
    ["/bin/dd", "if=/dev/zero", "of=\{output_path}", "bs=4096", "count=4"],
    3000L,
  )
  let file_request = {
    ..file_base,
    limits: { ..file_base.limits, file_size_bytes: 1024L },
    output_path: "/tmp/moonfort-supervisor-output-file-\{native_pid()}.log",
  }
  unlink_file(@utf8.encode(file_request.output_path))
  let file = run(file_request)
  inspect(file.kind, content="limit_exceeded")
  debug_inspect(file.limit, content="Some(\"file_size\")")
  unlink_file(@utf8.encode(output_path))
}

///|
test "native supervisor enforces merged output cap" {
  let base = test_request(["/usr/bin/yes", "overflow"], 5000L)
  let request = { ..base, output_bytes: 4096L }
  unlink_file(@utf8.encode(request.output_path))
  let result = run(request)
  inspect(result.kind, content="limit_exceeded")
  debug_inspect(result.limit, content="Some(\"output\")")
  unlink_file(@utf8.encode(request.output_path))
}

///|
test "native supervisor enforces aggregate disk bytes across many files" {
  let disk_root = "/private/tmp/moonfort-supervisor-disk-\{native_pid()}"
  assert_true(prepare_test_directory(@utf8.encode(disk_root)))
  let base = test_request(
    [
      "/bin/sh", "-c", "i=0; while [ $i -lt 100 ]; do dd if=/dev/zero of=\"$1/f$i\" bs=4096 count=1 2>/dev/null; i=$((i+1)); done; sleep 2",
      "write-many", disk_root,
    ],
    5000L,
  )
  let request = {
    ..base,
    disk_root,
    limits: { ..base.limits, aggregate_disk_bytes: 64L * 1024L },
    output_path: "/tmp/moonfort-supervisor-disk-output-\{native_pid()}.log",
  }
  unlink_file(@utf8.encode(request.output_path))
  let result = run(request)
  debug_inspect(result.limit, content="Some(\"aggregate_disk\")")
  inspect(result.kind, content="limit_exceeded")
  assert_eq(result.applied_limits, 63)
  cleanup_test_directory(@utf8.encode(disk_root))
  unlink_file(@utf8.encode(request.output_path))
}

///|
test "native supervisor enforces process group count" {
  let base = test_request(
    [
      "/bin/sh", "-c", "i=0; while [ $i -lt 8 ]; do sleep 5 & i=$((i+1)); done; wait",
    ],
    5000L,
  )
  let request = {
    ..base,
    limits: { ..base.limits, processes: 3L },
    output_path: "/tmp/moonfort-supervisor-process-output-\{native_pid()}.log",
  }
  unlink_file(@utf8.encode(request.output_path))
  let result = run(request)
  inspect(result.kind, content="limit_exceeded")
  debug_inspect(result.limit, content="Some(\"process_count\")")
  unlink_file(@utf8.encode(request.output_path))
}

///|
test "Linux process ceiling follows descendants after setsid" {
  if supervisor_test_platform() != 2 {
    return
  }
  let base = test_request(
    [
      "/bin/sh", "-c", "setsid /bin/sh -c 'sleep 5 & sleep 5 & sleep 5 & wait' & wait",
    ],
    5000L,
  )
  let request = {
    ..base,
    limits: { ..base.limits, processes: 2L },
    output_path: "/tmp/moonfort-supervisor-linux-setsid-\{native_pid()}.log",
  }
  unlink_file(@utf8.encode(request.output_path))
  let result = run(request)
  inspect(result.kind, content="limit_exceeded")
  debug_inspect(result.limit, content="Some(\"process_count\")")
  unlink_file(@utf8.encode(request.output_path))
}

///|
test "native supervisor kills descendants when leader exits normally" {
  let pid_path = "/tmp/moonfort-supervisor-escaped-\{native_pid()}.pid"
  unlink_file(@utf8.encode(pid_path))
  let request = {
    ..test_request(
      ["/bin/sh", "-c", "sleep 999 & echo $! > '\{pid_path}'; exit 0"],
      2000L,
    ),
    output_path: "/tmp/moonfort-supervisor-normal-exit-\{native_pid()}.log",
  }
  unlink_file(@utf8.encode(request.output_path))
  let result = run(request)
  inspect(result.kind, content="exited")
  let descendant = read_pid_file(@utf8.encode(pid_path))
  assert_true(descendant > 0)
  assert_true(wait_pid_gone(descendant, 2000))
  unlink_file(@utf8.encode(pid_path))
  unlink_file(@utf8.encode(request.output_path))
}

///|
test "target cannot inherit supervisor or unrelated host descriptors" {
  let reserved_fd = open_inherited_test_fd()
  let inherited_fd = open_inherited_test_fd()
  assert_true(inherited_fd > 3)
  let request = {
    ..test_request(
      [
        "/bin/sh",
        "-c",
        "if ( : >&3 ) 2>/dev/null; then exit 93; fi; if ( eval ': <&'$1 ) 2>/dev/null; then exit 94; fi; exit 0",
        "probe-fds",
        inherited_fd.to_string(),
      ],
      2000L,
    ),
    output_path: "/tmp/moonfort-supervisor-fd-isolation-\{native_pid()}.log",
  }
  unlink_file(@utf8.encode(request.output_path))
  let result = run(request)
  close_test_fd(reserved_fd)
  close_test_fd(inherited_fd)
  inspect(result.kind, content="exited")
  debug_inspect(result.exit_code, content="Some(0)")
  unlink_file(@utf8.encode(request.output_path))
}

///|
test "setsid descendant retaining output cannot hang the supervisor" {
  let pid_path = "/tmp/moonfort-supervisor-setsid-\{native_pid()}.pid"
  let output_path = "/tmp/moonfort-supervisor-setsid-\{native_pid()}.log"
  unlink_file(@utf8.encode(pid_path))
  unlink_file(@utf8.encode(output_path))
  let script =
    #|import os, sys, time
    #|read_fd, write_fd = os.pipe()
    #|pid = os.fork()
    #|if pid:
    #|    os.close(write_fd)
    #|    os.read(read_fd, 1)
    #|    os.close(read_fd)
    #|    os._exit(0)
    #|os.close(read_fd)
    #|os.setsid()
    #|with open(sys.argv[1], "w") as pid_file:
    #|    pid_file.write(str(os.getpid()))
    #|os.write(write_fd, b"1")
    #|os.close(write_fd)
    #|time.sleep(2)
    #|os._exit(0)
  let request = {
    ..test_request(["/usr/bin/python3", "-c", script, pid_path], 5000L),
    output_path,
  }
  let result = run(request)
  inspect(result.kind, content="cleanup_unverified")
  assert_true(result.elapsed_ms < 1500L)
  let descendant = read_pid_file(@utf8.encode(pid_path))
  assert_true(descendant > 0)
  assert_true(wait_pid_gone(descendant, 4000))
  unlink_file(@utf8.encode(pid_path))
  unlink_file(@utf8.encode(output_path))
}

///|
test "native supervisor rejects unsafe requests before fork" {
  let relative = test_request(["sh", "-c", "exit 0"], 1000L)
  try run(relative) catch {
    InvalidRequest(message) =>
      inspect(message, content="argv[0] must be an absolute executable path")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("expected InvalidRequest")
  }
}
