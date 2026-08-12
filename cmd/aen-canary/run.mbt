///|
async fn read_sentinel(path : String, limit : Int) -> Bytes {
  guard canonical_absolute_path(path) &&
    @fs.realpath(path) == path &&
    @fs.kind(path, follow_symlink=false) is Regular else {
    fail("canary mutation sentinel is not a canonical regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size >= 0L && size <= limit.to_int64() else {
    fail("canary mutation sentinel exceeds its byte bound")
  }
  let output = @buffer.Buffer(size_hint=size.to_int().min(8_192))
  for ;; {
    guard file.read_some(max_len=(limit - output.length() + 1).min(8_192))
      is Some(chunk) else {
      break
    }
    guard output.length() + chunk.length() <= limit else {
      fail("canary mutation sentinel exceeds its byte bound")
    }
    output.write_bytes(chunk)
  }
  guard file.size() == size &&
    @fs.realpath(path) == path &&
    @fs.kind(path, follow_symlink=false) is Regular else {
    fail("canary mutation sentinel changed during read")
  }
  output.to_bytes()
}

///|
fn fresh_case_ids(case : CanaryCase) -> (String, String) raise {
  guard @env.rand(12) is Some(random) else {
    fail("secure canary identity source is unavailable")
  }
  let token = @crypto.bytes_to_hex_string(random)
  (
    "aen-canary-\{case.name()}-\{token}",
    "run-aen-canary-\{case.name()}-\{token}",
  )
}

///|
async fn run_case(
  plan : CanaryPlan,
  config : CanaryConfig,
  executor : @trusted_executor.ExecutorConfig,
  backend : @trusted_executor.TrustedAenConfig,
  sentinel_before : Bytes,
  sentinel_path : String,
) -> CanaryCaseResult {
  let (approval_id, request_id) = fresh_case_ids(plan.case)
  let grant = make_grant(plan, config, approval_id, request_id)
  let publication = @trusted_executor.publish_grant(
    { protocol_version: 3, grant },
    executor,
  )
  if !publication.published ||
    publication.approval_digest.length() != 64 ||
    publication.error is Some(_) {
    return protocol_failure(
      plan.case,
      "trusted single-use grant publication failed",
    )
  }
  let response = @trusted_executor.execute_invocation(
    { protocol_version: 3, approval_id },
    executor,
  )
  guard response.receipt() is Some(receipt) else {
    return protocol_failure(
      plan.case,
      "production executor rejected the published MicroVm invocation",
    )
  }
  let sentinel_after = read_sentinel(
    sentinel_path,
    config.limits.max_sentinel_bytes,
  )
  assert_case_receipt(
    plan.case,
    receipt,
    publication.approval_digest,
    approval_id,
    config,
    backend,
    sentinel_before == sentinel_after,
  )
}

///|
async fn run_canary(
  config : CanaryConfig,
  executor : @trusted_executor.ExecutorConfig,
) -> CanaryReport {
  validate_deployment(config, executor)
  guard executor.workspaces.get(config.workspace_id) is Some(workspace) &&
    executor.aen_backends.get(config.backend_config_id) is Some(backend) else {
    fail("validated canary deployment disappeared")
  }
  let sentinel_path = "\{workspace.root}/\{config.mutation_target_relative_path}"
  let sentinel_before = read_sentinel(
    sentinel_path,
    config.limits.max_sentinel_bytes,
  )
  let plans = build_plans(config, backend)
  let results : Array[CanaryCaseResult] = []
  let mut continue_runs = true
  for plan in plans {
    if continue_runs {
      let result = run_case(
        plan, config, executor, backend, sentinel_before, sentinel_path,
      )
      results.push(result)
      // Do not create another hostile VM after cleanup uncertainty or evidence
      // that the canonical canary workspace changed.
      continue_runs = result.cleanup_verified &&
        !(plan.case is NetworkPositiveControl && !result.passed) &&
        !result.failures.contains(
          "canonical workspace sentinel changed on the host",
        )
    } else {
      results.push(
        protocol_failure(
          plan.case,
          "probe was not run after cleanup or workspace-integrity uncertainty",
        ),
      )
    }
  }
  {
    protocol_version: CanaryProtocolVersion,
    workspace_id: config.workspace_id,
    backend_config_id: config.backend_config_id,
    passed: results.all(result => result.passed),
    cases: results,
    error: None,
  }
}
