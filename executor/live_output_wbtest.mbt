///|
async test "live output provides monotonic bounded chunks before terminal receipt" {
  let (config, roots) = test_executor_config()
  let approval_id = "approval-live-1"
  let approval_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let started = begin_live_output(
    "run-live-1", approval_id, approval_digest, config,
  )
  let initial = read_live_output(
    { protocol_version: 1, approval_id, offset: 0L, max_bytes: 4 },
    config,
  )
  assert_eq(initial.status, "running")
  assert_eq(initial.available_bytes, 0L)
  assert_eq(initial.retry_after_ms, LiveOutputRetryAfterMs)
  let blob = "\{live_output_root(config)}/\{started.stream_id}.blob"
  @fs.write_file(
    blob,
    "hello world",
    create_mode=CreateNew,
    permission=0o600,
    sync=Full,
  )
  let first = read_live_output(
    { protocol_version: 1, approval_id, offset: 0L, max_bytes: 5 },
    config,
  )
  assert_eq(first.content_base64, "aGVsbG8=")
  assert_eq(first.next_offset, 5L)
  assert_false(first.terminal)
  let second = read_live_output(
    { protocol_version: 1, approval_id, offset: 5L, max_bytes: 64 },
    config,
  )
  assert_eq(second.content_base64, "IHdvcmxk")
  assert_eq(second.next_offset, 11L)
  let finalized = finalize_live_output(
    started,
    approval_id,
    approval_digest,
    @sandbox.exited_receipt(
      "run-live-1",
      LocalOs,
      Degraded,
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      0,
      "hello world",
    ),
    config,
  )
  assert_eq(finalized.status, "exited")
  assert_eq(finalized.size_bytes, 11L)
  let terminal = read_live_output(
    { protocol_version: 1, approval_id, offset: 11L, max_bytes: 64 },
    config,
  )
  assert_true(terminal.terminal)
  assert_eq(terminal.status, "exited")
  cleanup_test_roots(roots)
}

///|
async test "live output rejects cross-approval cursors and terminal substitution" {
  let (config, roots) = test_executor_config()
  let approval_id = "approval-live-2"
  let approval_digest = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  let started = begin_live_output(
    "run-live-2", approval_id, approval_digest, config,
  )
  let blob = "\{live_output_root(config)}/\{started.stream_id}.blob"
  @fs.write_file(
    blob,
    "trusted",
    create_mode=CreateNew,
    permission=0o600,
    sync=Full,
  )
  ignore(
    finalize_live_output(
      started,
      approval_id,
      approval_digest,
      @sandbox.exited_receipt(
        "run-live-2",
        LocalOs,
        Degraded,
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        0,
        "trusted",
      ),
      config,
    ),
  )
  let cross = read_live_output(
    {
      protocol_version: 1,
      approval_id: "approval-live-other",
      offset: 0L,
      max_bytes: 64,
    },
    config,
  )
  assert_true(
    cross.error is Some(error) && error.code == "live-output-unavailable",
  )
  @fs.write_file(
    blob,
    "substituted",
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  let tampered = read_live_output(
    { protocol_version: 1, approval_id, offset: 0L, max_bytes: 64 },
    config,
  )
  assert_true(
    tampered.error is Some(error) &&
    error.code == "live-output-integrity-refused",
  )
  let future = read_live_output(
    { protocol_version: 1, approval_id, offset: 999L, max_bytes: 64 },
    config,
  )
  assert_true(future.error is Some(_))
  cleanup_test_roots(roots)
}
