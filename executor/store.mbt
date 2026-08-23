///|
const MaxExecutorConfigBytes : Int = 1_048_576

///|
fn retention_window_is_valid(value : Int64) -> Bool {
  value > 0L && value <= 31_536_000_000L
}

///|
fn trusted_aen_config_is_valid(backend : TrustedAenConfig) -> Bool {
  canonical_https_origin(backend.base_url) &&
  backend.api_key.trim() != "" &&
  immutable_oci_reference(backend.executor_image_ref) &&
  backend.expected_vcpu_count > 0 &&
  backend.expected_root_disk_mib >= 1_024 &&
  backend.expected_root_disk_mib % 1_024 == 0 &&
  canonical_https_origin(backend.provisioner_url) &&
  backend.provisioner_api_key.trim() != "" &&
  backend.provisioner_receipt_key.length() >= 32 &&
  safe_identifier(backend.provisioner_key_id) &&
  immutable_oci_repository(backend.workspace_registry_repository) &&
  backend.max_workspace_bytes > 0L &&
  backend.guest_workspace.has_prefix("/") &&
  backend.guest_scratch.has_prefix("/") &&
  backend.guest_attester.has_prefix("/") &&
  backend.guest_supervisor.has_prefix("/") &&
  sha256_digest(backend.executor_root_digest) &&
  sha256_digest(backend.guest_attester_digest) &&
  sha256_digest(backend.guest_supervisor_digest) &&
  sha256_digest(backend.tool_registry_digest)
}

///|
async fn bounded_regular_file(path : String, limit : Int) -> String {
  guard canonical_absolute_path(path) && limit > 0 else {
    fail("invalid bounded file request")
  }
  guard @fs.kind(path, follow_symlink=false) is Regular else {
    fail("trusted file is not regular")
  }
  guard protected_regular_file(path) else {
    fail("trusted file ownership or permissions are unsafe")
  }
  guard @fs.realpath(path) == path else {
    fail("trusted file path is not canonical")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  guard file.kind() is Regular else { fail("trusted file changed type") }
  let size = file.size()
  guard size >= 0L && size <= limit.to_int64() else {
    fail("trusted file exceeds byte limit")
  }
  let output = @buffer.Buffer(size_hint=size.to_int().min(8_192))
  for ;; {
    guard file.read_some(max_len=(limit - output.length() + 1).min(8_192))
      is Some(chunk) else {
      break
    }
    guard output.length() + chunk.length() <= limit else {
      fail("trusted file exceeds byte limit")
    }
    output.write_bytes(chunk)
  }
  guard file.size() == size &&
    @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.realpath(path) == path else {
    fail("trusted file changed during read")
  }
  @utf8.decode(output.to_bytes())
}

///|
pub async fn load_executor_config(path : String) -> ExecutorConfig {
  let config : ExecutorConfig = @json.from_json(
    @json.parse(bounded_regular_file(path, MaxExecutorConfigBytes)),
  )
  guard canonical_absolute_path(config.approval_root) &&
    @fs.realpath(config.approval_root) == config.approval_root &&
    @fs.kind(config.approval_root, follow_symlink=false) is Directory else {
    fail("approval root is not a canonical trusted directory")
  }
  guard private_directory(config.approval_root) else {
    fail("approval root ownership or permissions are unsafe")
  }
  guard canonical_absolute_path(config.scratch_root) &&
    @fs.realpath(config.scratch_root) == config.scratch_root &&
    @fs.kind(config.scratch_root, follow_symlink=false) is Directory else {
    fail("scratch root is not a canonical trusted directory")
  }
  guard private_directory(config.scratch_root) else {
    fail("scratch root ownership or permissions are unsafe")
  }
  guard canonical_absolute_path(config.retention_root) &&
    @fs.realpath(config.retention_root) == config.retention_root &&
    @fs.kind(config.retention_root, follow_symlink=false) is Directory else {
    fail("retention root is not a canonical trusted directory")
  }
  guard private_directory(config.retention_root) else {
    fail("retention root ownership or permissions are unsafe")
  }
  let output_artifact_root = "\{config.retention_root}/output-artifacts"
  guard @fs.realpath(output_artifact_root) == output_artifact_root &&
    @fs.kind(output_artifact_root, follow_symlink=false) is Directory &&
    private_directory(output_artifact_root) else {
    fail("output artifact root is not a canonical private directory")
  }
  guard !paths_overlap(config.approval_root, config.scratch_root) &&
    !paths_overlap(config.approval_root, config.retention_root) &&
    !paths_overlap(config.scratch_root, config.retention_root) else {
    fail("executor-owned roots must be pairwise disjoint")
  }
  guard config.limits.max_protocol_bytes > 0 &&
    config.limits.max_protocol_bytes <= 1_048_576 &&
    config.limits.max_wall_clock_ms > 0 &&
    config.limits.max_wall_clock_ms <= 86_400_000 &&
    config.limits.max_cpu_seconds > 0 &&
    config.limits.max_cpu_seconds <= 86_400 &&
    config.limits.max_memory_mib > 0 &&
    config.limits.max_memory_mib <= 1_048_576 &&
    config.limits.max_disk_mib > 0 &&
    config.limits.max_disk_mib <= 1_048_576 &&
    config.limits.max_processes > 0 &&
    config.limits.max_processes <= 65_536 &&
    config.limits.max_output_bytes > 0 &&
    config.limits.max_output_bytes <= 1_073_741_824 &&
    config.limits.max_model_output_bytes > 0 &&
    config.limits.max_model_output_bytes <= config.limits.max_output_bytes &&
    config.limits.max_model_output_bytes <= config.limits.max_protocol_bytes / 2 &&
    config.limits.max_command_args > 0 &&
    config.limits.max_command_args <= 4_096 &&
    config.limits.max_argument_bytes > 0 &&
    config.limits.max_argument_bytes <= 1_048_576 &&
    config.limits.max_changed_paths > 0 &&
    config.limits.max_changed_paths <= 1_000_000 &&
    retention_window_is_valid(config.limits.retention_ms) else {
    fail("executor deployment limits are invalid")
  }
  guard safe_identifier(config.artifact_key_id) &&
    config.artifact_signing_key.length() >= 32 else {
    fail("output artifact signing configuration is invalid")
  }
  for name, workspace in config.workspaces {
    guard safe_identifier(name) &&
      canonical_absolute_path(workspace.root) &&
      @fs.realpath(workspace.root) == workspace.root &&
      @fs.kind(workspace.root, follow_symlink=false) is Directory &&
      trusted_directory(workspace.root) &&
      !paths_overlap(workspace.root, config.approval_root) &&
      !paths_overlap(workspace.root, config.scratch_root) &&
      !paths_overlap(workspace.root, config.retention_root) else {
      fail("workspace registry contains an invalid root")
    }
    for root in workspace.read_only_roots {
      guard canonical_absolute_path(root) &&
        @fs.realpath(root) == root &&
        @fs.kind(root, follow_symlink=false) is Directory &&
        trusted_directory(root) &&
        !paths_overlap(root, config.approval_root) &&
        !paths_overlap(root, config.scratch_root) &&
        !paths_overlap(root, config.retention_root) else {
        fail("workspace registry contains an invalid read root")
      }
    }
    guard workspace.read_only_roots.any(root => {
      path_contains(root, workspace.root)
    }) else {
      fail("workspace registry read roots do not cover its root")
    }
  }
  for label, executable in config.local_tools {
    guard safe_identifier(label) &&
      label != @sandbox.shell_compatibility_command_label() &&
      canonical_absolute_path(executable) &&
      @fs.realpath(executable) == executable &&
      @fs.kind(executable, follow_symlink=false) is Regular &&
      trusted_executable(executable) else {
      fail("local tool registry contains an invalid executable")
    }
  }
  for id, backend in config.aen_backends {
    guard safe_identifier(id) && trusted_aen_config_is_valid(backend) else {
      fail("AEN registry contains an invalid trusted deployment")
    }
  }
  config
}

///|
async fn consume_grant(
  invocation : SandboxInvocation,
  config : ExecutorConfig,
) -> ExecutionGrant {
  guard invocation.protocol_version == 3 &&
    safe_identifier(invocation.approval_id) else {
    fail("invalid invocation")
  }
  let pending_root = "\{config.approval_root}/pending"
  let consumed_root = "\{config.approval_root}/consumed"
  guard @fs.realpath(pending_root) == pending_root &&
    @fs.realpath(consumed_root) == consumed_root &&
    @fs.kind(pending_root, follow_symlink=false) is Directory &&
    @fs.kind(consumed_root, follow_symlink=false) is Directory &&
    private_directory(pending_root) &&
    private_directory(consumed_root) else {
    fail("grant store is unavailable")
  }
  let pending = "\{pending_root}/\{invocation.approval_id}.json"
  let consumed = "\{consumed_root}/\{invocation.approval_id}.json"
  guard @fs.kind(pending, follow_symlink=false) is Regular else {
    fail("approval is unknown, expired, or already consumed")
  }
  @fs.rename(pending, consumed, replace=false) catch {
    _ => fail("approval is unknown, expired, or already consumed")
  }
  let grant : ExecutionGrant = @json.from_json(
    @json.parse(
      bounded_regular_file(consumed, config.limits.max_protocol_bytes),
    ),
  )
  grant
}

///|
/// Validate and atomically publish one human-approved grant.
pub async fn publish_grant(
  request : GrantPublicationRequest,
  config : ExecutorConfig,
) -> GrantPublicationResponse {
  let grant = request.grant
  let approval_id = grant.approval_id
  let refusal = if request.protocol_version != 3 {
    "unsupported publication protocol"
  } else if !safe_identifier(approval_id) {
    "invalid approval identity"
  } else {
    validate_grant(grant, { protocol_version: 3, approval_id }, config)
  }
  if refusal != "" {
    return {
      protocol_version: 3,
      approval_id,
      approval_digest: "",
      published: false,
      error: Some({ code: "grant-refused", message: refusal }),
    }
  }
  let pending_root = "\{config.approval_root}/pending"
  let consumed_root = "\{config.approval_root}/consumed"
  let destination = "\{pending_root}/\{approval_id}.json"
  let consumed = "\{consumed_root}/\{approval_id}.json"
  guard @fs.realpath(pending_root) == pending_root &&
    @fs.realpath(consumed_root) == consumed_root &&
    @fs.kind(pending_root, follow_symlink=false) is Directory &&
    @fs.kind(consumed_root, follow_symlink=false) is Directory &&
    private_directory(pending_root) &&
    private_directory(consumed_root) else {
    return {
      protocol_version: 3,
      approval_id,
      approval_digest: "",
      published: false,
      error: Some({
        code: "publication-refused",
        message: "grant store is unavailable",
      }),
    }
  }
  guard !@fs.exists(destination) && !@fs.exists(consumed) else {
    return {
      protocol_version: 3,
      approval_id,
      approval_digest: "",
      published: false,
      error: Some({
        code: "grant-conflict",
        message: "approval identity was already published or consumed",
      }),
    }
  }
  guard @env.rand(16) is Some(random) else {
    return {
      protocol_version: 3,
      approval_id,
      approval_digest: "",
      published: false,
      error: Some({
        code: "publication-refused",
        message: "secure publication identity is unavailable",
      }),
    }
  }
  let staging = "\{pending_root}/.publish-\{@crypto.bytes_to_hex_string(random)}.tmp"
  let digest = grant_digest(grant)
  try {
    @fs.write_file(
      staging,
      grant.to_json().stringify(),
      create_mode=CreateNew,
      permission=0o600,
      sync=Full,
    )
    guard @fs.kind(staging, follow_symlink=false) is Regular &&
      @fs.realpath(staging) == staging else {
      fail("staged grant could not be verified")
    }
    @fs.rename(staging, destination, replace=false)
    {
      protocol_version: 3,
      approval_id,
      approval_digest: digest,
      published: true,
      error: None,
    }
  } catch {
    _ => {
      ignore(@fs.remove(staging) catch { _ => () })
      {
        protocol_version: 3,
        approval_id,
        approval_digest: "",
        published: false,
        error: Some({
          code: "publication-refused",
          message: "grant could not be published atomically",
        }),
      }
    }
  }
}

///|
async fn allocate_scratch(
  _request_id : String,
  config : ExecutorConfig,
) -> (String, String) {
  guard @env.rand(16) is Some(random) else {
    fail("secure randomness is unavailable")
  }
  let retention_id = @crypto.bytes_to_hex_string(random)
  let scratch = "\{config.scratch_root}/\{retention_id}"
  @fs.mkdir(scratch, permission=0o700)
  guard @fs.realpath(scratch) == scratch &&
    @fs.kind(scratch, follow_symlink=false) is Directory else {
    ignore(@sandbox.discard_scratch_tree(scratch))
    fail("private scratch creation could not be verified")
  }
  (scratch, retention_id)
}

///|
fn retention_manifest_is_valid(
  files : Array[@sandbox.ScratchEntry],
  config : ExecutorConfig,
) -> Bool {
  if files.is_empty() || files.length() > config.limits.max_changed_paths {
    return false
  }
  let sorted = files.copy()
  sorted.sort_by_key(entry => entry.relative_path)
  if sorted != files {
    return false
  }
  let seen : Map[String, Unit] = Map([])
  let mut total = 0L
  let byte_limit = config.limits.max_disk_mib.to_int64() * 1_048_576L
  for entry in files {
    guard entry.kind is RegularFile &&
      @sandbox.scratch_relative_path_is_safe(entry.relative_path) &&
      !seen.contains(entry.relative_path) &&
      entry.size_bytes >= 0L &&
      sha256_digest(entry.fingerprint) &&
      entry.size_bytes <= byte_limit - total else {
      return false
    }
    seen[entry.relative_path] = ()
    total += entry.size_bytes
  }
  true
}

///|
async fn retain_scratch(
  scratch : String,
  retention_id : String,
  workspace_id : String,
  profile_digest : String,
  approval_digest : String,
  command_digest : String,
  reviewable_files : Array[@sandbox.ScratchEntry],
  config : ExecutorConfig,
) -> Bool {
  guard safe_identifier(retention_id) &&
    retention_window_is_valid(config.limits.retention_ms) &&
    sha256_digest(profile_digest) &&
    sha256_digest(approval_digest) &&
    sha256_digest(command_digest) &&
    scratch == "\{config.scratch_root}/\{retention_id}" else {
    return false
  }
  let manifest = reviewable_files.copy()
  manifest.sort_by_key(entry => entry.relative_path)
  guard retention_manifest_is_valid(manifest, config) else { return false }
  let inventory = match
    @sandbox.inventory_scratch(
      scratch,
      config.limits.max_disk_mib.to_int64() * 1_048_576L,
    ) {
    Ok(value) => value
    Err(_) => return false
  }
  guard manifest.all(expected => inventory.entries.contains(expected)) else {
    return false
  }
  let record : RetentionRecord = {
    retention_id,
    scratch_path: scratch,
    expires_at_ms: {
      let now = @env.now().reinterpret_as_int64()
      guard now >= 0L &&
        config.limits.retention_ms <= 9_223_372_036_854_775_807L - now else {
        return false
      }
      now + config.limits.retention_ms
    },
    workspace_id,
    profile_digest,
    approval_digest,
    command_digest,
    reviewable_files: manifest,
  }
  let encoded = record.to_json().stringify()
  guard @utf8.encode(encoded).length() <= config.limits.max_protocol_bytes else {
    return false
  }
  let path = "\{config.retention_root}/\{retention_id}.json"
  try {
    @fs.write_file(
      path,
      encoded,
      create_mode=CreateNew,
      permission=0o600,
      sync=Full,
    )
    @fs.kind(path, follow_symlink=false) is Regular
  } catch {
    _ => false
  }
}

///|
async fn load_retention_record(
  retention_id : String,
  config : ExecutorConfig,
) -> RetentionRecord {
  guard safe_identifier(retention_id) else { fail("invalid retention ID") }
  let path = "\{config.retention_root}/\{retention_id}.json"
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    protected_regular_file(path) else {
    fail("retention record is unavailable")
  }
  let record : RetentionRecord = @json.from_json(
    @json.parse(bounded_regular_file(path, config.limits.max_protocol_bytes)),
  )
  guard record.retention_id == retention_id &&
    record.scratch_path == "\{config.scratch_root}/\{retention_id}" &&
    safe_identifier(record.workspace_id) &&
    sha256_digest(record.profile_digest) &&
    sha256_digest(record.approval_digest) &&
    sha256_digest(record.command_digest) &&
    retention_manifest_is_valid(record.reviewable_files, config) &&
    record.expires_at_ms > @env.now().reinterpret_as_int64() &&
    @fs.realpath(record.scratch_path) == record.scratch_path &&
    @fs.kind(record.scratch_path, follow_symlink=false) is Directory else {
    fail("retention record is expired or inconsistent")
  }
  record
}

///|
async fn claim_retention_for_promotion(
  record : RetentionRecord,
  item : @sandbox.SandboxPromotionItem,
  workspace_root : String,
  config : ExecutorConfig,
) -> String {
  let available = "\{config.retention_root}/\{record.retention_id}.json"
  let claimed = "\{config.retention_root}/\{record.retention_id}.promoting"
  let claim_path = "\{config.retention_root}/\{record.retention_id}.claim"
  guard workspace_root_binding_digest(record.workspace_id, workspace_root)
    is Some(root_binding) else {
    fail("workspace root identity is unavailable")
  }
  let claim : PromotionClaim = {
    record,
    item,
    phase: "prepared",
    workspace_root_binding: Some(root_binding),
  }
  let encoded = claim.to_json().stringify()
  guard @utf8.encode(encoded).length() <= config.limits.max_protocol_bytes else {
    fail("promotion claim exceeds the protocol bound")
  }
  @fs.write_file(
    claim_path,
    encoded,
    create_mode=CreateNew,
    permission=0o600,
    sync=Full,
  ) catch {
    _ => fail("retention is already being promoted or is unavailable")
  }
  let claim_verified = try
    @fs.kind(claim_path, follow_symlink=false) is Regular &&
    protected_regular_file(claim_path) &&
    sync_private_directory(config.retention_root)
  catch {
    _ => false
  }
  guard claim_verified else {
    ignore(rollback_pre_rename_claim(available, claimed, claim_path, config))
    fail("claimed retention record could not be verified")
  }
  @fs.rename(available, claimed, replace=false) catch {
    _ => {
      ignore(rollback_pre_rename_claim(available, claimed, claim_path, config))
      fail("retention could not be atomically claimed")
    }
  }
  guard sync_private_directory(config.retention_root) else {
    fail("promotion claim could not be durably committed")
  }
  claimed
}

///|
/// Remove a claim sidecar only when the original retention is still a
/// protected regular file and no promoting record exists. Once the rename may
/// have occurred, ambiguity is preserved for operator recovery.
async fn rollback_pre_rename_claim(
  available : String,
  claimed : String,
  claim_path : String,
  config : ExecutorConfig,
) -> Bool {
  let proven_pre_rename = try
    @fs.kind(available, follow_symlink=false) is Regular &&
    protected_regular_file(available) &&
    !@fs.exists(claimed)
  catch {
    _ => false
  }
  if !proven_pre_rename {
    return false
  }
  try {
    if @fs.exists(claim_path) {
      guard @fs.kind(claim_path, follow_symlink=false) is Regular else {
        return false
      }
      @fs.remove(claim_path)
    }
    sync_private_directory(config.retention_root)
  } catch {
    _ => false
  }
}

///|
async fn restore_claimed_retention(
  claimed : String,
  record : RetentionRecord,
  config : ExecutorConfig,
) -> Bool {
  let available = "\{config.retention_root}/\{record.retention_id}.json"
  let claim_path = "\{config.retention_root}/\{record.retention_id}.claim"
  let restored = try {
    @fs.rename(claimed, available, replace=false)
    sync_private_directory(config.retention_root)
  } catch {
    _ => false
  }
  if !restored {
    return false
  }
  let claim_removed = try {
    @fs.remove(claim_path)
    true
  } catch {
    _ => false
  }
  claim_removed && sync_private_directory(config.retention_root)
}

///|
/// Promote only explicitly reviewed regular files from an executor-owned
/// retention into the registered canonical workspace. Promotion atomically
/// claims the retention before applying and consumes it after verified
/// cleanup; source fingerprints are revalidated by the sandbox layer.
pub async fn promote_retention(
  request : RetentionPromotionRequest,
  config : ExecutorConfig,
) -> RetentionPromotionResponse {
  let refused = fn(message : String) -> RetentionPromotionResponse {
    {
      protocol_version: 4,
      retention_id: request.retention_id,
      workspace_id: "",
      approval_digest: "",
      command_digest: "",
      promoted_paths: [],
      destination_outcome: "not-applied",
      uncertain_paths: [],
      completed: false,
      error: Some({ code: "promotion-refused", message }),
    }
  }
  if request.protocol_version != 4 ||
    !safe_identifier(request.workspace_id) ||
    request.items.is_empty() ||
    request.items.length() > config.limits.max_changed_paths {
    return refused("promotion request is invalid or exceeds deployment policy")
  }
  guard config.workspaces.get(request.workspace_id) is Some(workspace) else {
    return refused("promotion names an unknown workspace")
  }
  let record = load_retention_record(request.retention_id, config) catch {
    _ => return refused("retention is unavailable, expired, or invalid")
  }
  if record.approval_digest != request.approval_digest ||
    record.command_digest != request.command_digest ||
    record.workspace_id != request.workspace_id {
    return refused("promotion digests do not match the retained execution")
  }
  let disk_limit_bytes = config.limits.max_disk_mib.to_int64() * 1024L * 1024L
  let retained_inventory = match
    @sandbox.inventory_scratch(record.scratch_path, disk_limit_bytes) {
    Ok(value) => value
    Err(_) => return refused("retained scratch could not be safely inventoried")
  }
  guard record.reviewable_files.all(expected => {
    retained_inventory.entries.contains(expected)
  }) else {
    return refused("retained review manifest no longer matches scratch")
  }
  let inventory : @sandbox.ScratchInventory = {
    entries: record.reviewable_files.copy(),
    total_bytes: record.reviewable_files.fold(init=0L, (sum, entry) => {
      sum + entry.size_bytes
    }),
  }
  let plan = match
    @sandbox.plan_sandbox_promotion(inventory, workspace.root, request.items) {
    Ok(value) => value
    Err(reason) => return refused("promotion planning failed: \{reason.code()}")
  }
  let planned_items = plan.items()
  guard planned_items.length() == 1 else {
    return refused("promotion plan does not contain exactly one item")
  }
  @async.protect_from_cancel(
    () => {
      let claimed = claim_retention_for_promotion(
        record,
        planned_items[0],
        workspace.root,
        config,
      ) catch {
        _ =>
          return refused("retention is already being promoted or unavailable")
      }
      match
        @sandbox.apply_sandbox_promotion(
          record.scratch_path,
          plan,
          disk_limit_bytes~,
        ) {
        AppliedDurable(result) => {
          let scratch_removed = @sandbox.discard_scratch_tree(
              record.scratch_path,
            )
            is Ok(_)
          let records_removed = if scratch_removed {
            try {
              @fs.remove(claimed)
              @fs.remove(
                "\{config.retention_root}/\{request.retention_id}.claim",
              )
              sync_private_directory(config.retention_root)
            } catch {
              _ => false
            }
          } else {
            false
          }
          if scratch_removed && records_removed {
            {
              protocol_version: 4,
              retention_id: request.retention_id,
              workspace_id: record.workspace_id,
              approval_digest: record.approval_digest,
              command_digest: record.command_digest,
              promoted_paths: result.promoted_paths,
              destination_outcome: "applied-durable",
              uncertain_paths: [],
              completed: true,
              error: None,
            }
          } else {
            {
              protocol_version: 4,
              retention_id: request.retention_id,
              workspace_id: record.workspace_id,
              approval_digest: record.approval_digest,
              command_digest: record.command_digest,
              promoted_paths: result.promoted_paths,
              destination_outcome: "applied-durable",
              uncertain_paths: [],
              completed: false,
              error: Some({
                code: "promotion-cleanup-unverified",
                message: "files were promoted but retention cleanup could not be verified",
              }),
            }
          }
        }
        NotApplied(reason) =>
          if restore_claimed_retention(claimed, record, config) {
            refused(
              "promotion apply failed before destination mutation: \{reason.code()}",
            )
          } else {
            {
              protocol_version: 4,
              retention_id: request.retention_id,
              workspace_id: record.workspace_id,
              approval_digest: record.approval_digest,
              command_digest: record.command_digest,
              promoted_paths: [],
              destination_outcome: "not-applied",
              uncertain_paths: [],
              completed: false,
              error: Some({
                code: "promotion-recovery-required",
                message: "destination was not applied but the durable retention claim could not be restored",
              }),
            }
          }
        RecoveryRequired(destination_path~, native_status~) =>
          {
            protocol_version: 4,
            retention_id: request.retention_id,
            workspace_id: record.workspace_id,
            approval_digest: record.approval_digest,
            command_digest: record.command_digest,
            promoted_paths: [],
            destination_outcome: "recovery-required",
            uncertain_paths: [destination_path],
            completed: false,
            error: Some({
              code: "promotion-recovery-required",
              message: "destination outcome is uncertain for \{destination_path}; retention remains locked (native status \{native_status})",
            }),
          }
      }
    },
    resume_on_cancel=true,
  )
}

///|
/// Remove every expired, unclaimed executor-owned scratch retention record.
/// `.promoting` claims are deliberately excluded: they may represent an
/// indeterminate canonical write and require explicit recovery.
pub async fn sweep_expired_retentions(config : ExecutorConfig) -> Int {
  let mut removed = 0
  let now = @env.now().reinterpret_as_int64()
  for name in @fs.readdir(config.retention_root, sort=true) {
    guard name.has_suffix(".json") else { continue }
    let id = name[:name.length() - 5].to_owned()
    guard safe_identifier(id) else { continue }
    let promoting = "\{config.retention_root}/\{id}.promoting"
    let claim = "\{config.retention_root}/\{id}.claim"
    if (
        @fs.exists(promoting) &&
        @fs.kind(promoting, follow_symlink=false) is Regular
      ) ||
      (@fs.exists(claim) && @fs.kind(claim, follow_symlink=false) is Regular) {
      continue
    }
    let path = "\{config.retention_root}/\{name}"
    let record : RetentionRecord = @json.from_json(
      @json.parse(bounded_regular_file(path, config.limits.max_protocol_bytes)),
    ) catch {
      _ => continue
    }
    if record.retention_id != id ||
      record.scratch_path != "\{config.scratch_root}/\{id}" ||
      !safe_identifier(record.workspace_id) ||
      !sha256_digest(record.profile_digest) ||
      !sha256_digest(record.approval_digest) ||
      !sha256_digest(record.command_digest) ||
      !retention_manifest_is_valid(record.reviewable_files, config) ||
      record.expires_at_ms > now {
      continue
    }
    if @sandbox.discard_scratch_tree(record.scratch_path) is Ok(_) {
      @fs.remove(path)
      removed += 1
    }
  }
  removed
}
