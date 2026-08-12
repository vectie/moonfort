///|
async fn emit_report(report : CanaryReport) -> Unit {
  @stdio.stdout.write(report.to_json().stringify() + "\n")
}

///|
async fn main {
  let config_path = match @env.get_env_var("MOONFORT_AEN_CANARY_CONFIG") {
    Some(value) => value
    None => {
      emit_report({
        protocol_version: CanaryProtocolVersion,
        workspace_id: "",
        backend_config_id: "",
        passed: false,
        cases: [],
        error: Some("canary configuration is unavailable"),
      })
      fail("AEN canary refused")
    }
  }
  let loaded : Result[(CanaryConfig, @trusted_executor.ExecutorConfig), Unit] = try {
    let config = load_canary_config(config_path)
    let executor = @trusted_executor.load_executor_config(
      config.executor_config_path,
    )
    validate_deployment(config, executor)
    Ok((config, executor))
  } catch {
    _ => Err(())
  }
  guard loaded is Ok((config, executor)) else {
    emit_report({
      protocol_version: CanaryProtocolVersion,
      workspace_id: "",
      backend_config_id: "",
      passed: false,
      cases: [],
      error: Some("canary configuration or deployment validation failed"),
    })
    fail("AEN canary refused")
  }
  let report : CanaryReport = run_canary(config, executor) catch {
    _ => {
      emit_report({
        protocol_version: CanaryProtocolVersion,
        workspace_id: config.workspace_id,
        backend_config_id: config.backend_config_id,
        passed: false,
        cases: [],
        error: Some("canary execution failed closed before a complete report"),
      })
      fail("AEN canary failed")
    }
  }
  emit_report(report)
  if !report.passed {
    fail("AEN canary detected an enforcement failure")
  }
}
