///|
fn recovery_state_digest(
  kind : String,
  size_bytes : Int64,
  fingerprint : String,
) -> String {
  let state : Json = {
    "schema": "moonfort-promotion-destination-state-v1",
    "kind": kind,
    "size_bytes": size_bytes,
    "fingerprint": fingerprint,
  }
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(state.stringify())))
}

///|
fn absent_recovery_state_digest() -> String {
  recovery_state_digest("absent", 0L, "")
}

///|
fn regular_recovery_state_digest(
  size_bytes : Int64,
  fingerprint : String,
) -> String {
  recovery_state_digest("regular", size_bytes, fingerprint)
}

///|
fn recovery_refusal(
  request : RetentionRecoveryInspectionRequest,
  outcome : String,
  code : String,
  message : String,
) -> RetentionRecoveryInspectionResponse {
  {
    protocol_version: 4,
    retention_id: if safe_identifier(request.retention_id) {
      request.retention_id
    } else {
      ""
    },
    workspace_id: "",
    profile_digest: "",
    approval_digest: "",
    command_digest: "",
    destination_path: "",
    reviewed_state_digest: "",
    desired_state_digest: "",
    observed_state_digest: "",
    outcome,
    error: Some({ code, message }),
  }
}

///|
fn recovery_evidence(
  request : RetentionRecoveryInspectionRequest,
  claim : PromotionClaim,
  reviewed_state_digest : String,
  desired_state_digest : String,
  observed_state_digest : String,
  outcome : String,
  error : ExecutorProtocolError?,
) -> RetentionRecoveryInspectionResponse {
  {
    protocol_version: 4,
    retention_id: request.retention_id,
    workspace_id: claim.record.workspace_id,
    profile_digest: claim.record.profile_digest,
    approval_digest: claim.record.approval_digest,
    command_digest: claim.record.command_digest,
    destination_path: claim.item.destination_relative_path,
    reviewed_state_digest,
    desired_state_digest,
    observed_state_digest,
    outcome,
    error,
  }
}

///|
fn claim_item_is_bound(claim : PromotionClaim, config : ExecutorConfig) -> Bool {
  let record = claim.record
  let item = claim.item
  if claim.phase != "prepared" ||
    record.retention_id == "" ||
    !safe_identifier(record.retention_id) ||
    record.scratch_path != "\{config.scratch_root}/\{record.retention_id}" ||
    !safe_identifier(record.workspace_id) ||
    !sha256_digest(record.profile_digest) ||
    !sha256_digest(record.approval_digest) ||
    !sha256_digest(record.command_digest) ||
    !retention_manifest_is_valid(record.reviewable_files, config) ||
    !@sandbox.scratch_relative_path_is_safe(item.source_relative_path) ||
    !@sandbox.scratch_relative_path_is_safe(item.destination_relative_path) ||
    item.size_bytes < 0L ||
    !sha256_digest(item.expected_source_fingerprint) {
    return false
  }
  let source_bound = record.reviewable_files.any(entry => {
    entry.kind is RegularFile &&
    entry.relative_path == item.source_relative_path &&
    entry.size_bytes == item.size_bytes &&
    entry.fingerprint == item.expected_source_fingerprint
  })
  source_bound &&
  (match item.expected_destination_state {
    ReviewedDestinationAbsent => true
    ReviewedDestinationRegular(size_bytes~, fingerprint~) =>
      size_bytes >= 0L && sha256_digest(fingerprint)
  })
}

///|
async fn load_locked_promotion_claim(
  retention_id : String,
  config : ExecutorConfig,
) -> PromotionClaim {
  guard safe_identifier(retention_id) else { fail("invalid retention ID") }
  let promoting = "\{config.retention_root}/\{retention_id}.promoting"
  let claim_path = "\{config.retention_root}/\{retention_id}.claim"
  let available_name = "\{retention_id}.json"
  guard !@fs.readdir(config.retention_root).contains(available_name) &&
    @fs.kind(promoting, follow_symlink=false) is Regular &&
    @fs.kind(claim_path, follow_symlink=false) is Regular &&
    protected_regular_file(promoting) &&
    protected_regular_file(claim_path) else {
    fail("locked promotion pair is unavailable")
  }
  let record : RetentionRecord = @json.from_json(
    @json.parse(
      bounded_regular_file(promoting, config.limits.max_protocol_bytes),
    ),
  )
  let claim : PromotionClaim = @json.from_json(
    @json.parse(
      bounded_regular_file(claim_path, config.limits.max_protocol_bytes),
    ),
  )
  guard claim.record == record &&
    record.retention_id == retention_id &&
    claim_item_is_bound(claim, config) else {
    fail("locked promotion pair is inconsistent")
  }
  claim
}

///|
/// Inspect a durable promotion claim without changing the destination,
/// retention files, or scratch tree. This reports content state only; it does
/// not prove which historical rename step ran.
pub async fn inspect_retention_recovery(
  request : RetentionRecoveryInspectionRequest,
  config : ExecutorConfig,
) -> RetentionRecoveryInspectionResponse {
  if request.protocol_version != 4 || !safe_identifier(request.retention_id) {
    return recovery_refusal(
      request, "unavailable", "inspection-refused", "recovery inspection request is invalid",
    )
  }
  let claim = load_locked_promotion_claim(request.retention_id, config) catch {
    _ =>
      return recovery_refusal(
        request, "unavailable", "inspection-unavailable", "locked promotion evidence is unavailable or invalid",
      )
  }
  let item = claim.item
  let reviewed = match item.expected_destination_state {
    ReviewedDestinationAbsent => absent_recovery_state_digest()
    ReviewedDestinationRegular(size_bytes~, fingerprint~) =>
      regular_recovery_state_digest(size_bytes, fingerprint)
  }
  let desired = regular_recovery_state_digest(
    item.size_bytes,
    item.expected_source_fingerprint,
  )
  guard config.workspaces.get(claim.record.workspace_id) is Some(workspace) else {
    return recovery_evidence(
      request,
      claim,
      reviewed,
      desired,
      "",
      "manual-recovery",
      Some({
        code: "root-mapping-unproven",
        message: "the claimed workspace root mapping cannot be proven",
      }),
    )
  }
  guard claim.workspace_root_binding is Some(claimed_root_binding) &&
    sha256_digest(claimed_root_binding) &&
    canonical_absolute_path(workspace.root) &&
    @fs.realpath(workspace.root) == workspace.root &&
    @fs.kind(workspace.root, follow_symlink=false) is Directory &&
    trusted_directory(workspace.root) &&
    workspace_root_binding_digest(claim.record.workspace_id, workspace.root)
    is Some(current_root_binding) &&
    current_root_binding == claimed_root_binding else {
    return recovery_evidence(
      request,
      claim,
      reviewed,
      desired,
      "",
      "manual-recovery",
      Some({
        code: "root-mapping-unproven",
        message: "the claimed workspace root mapping cannot be proven",
      }),
    )
  }
  let observation = @sandbox.inspect_sandbox_destination(
    workspace.root,
    item.destination_relative_path,
  )
  guard workspace_root_binding_digest(claim.record.workspace_id, workspace.root)
    is Some(rechecked_root_binding) &&
    rechecked_root_binding == claimed_root_binding else {
    return recovery_evidence(
      request,
      claim,
      reviewed,
      desired,
      "",
      "manual-recovery",
      Some({
        code: "root-mapping-unproven",
        message: "the claimed workspace root mapping cannot be proven",
      }),
    )
  }
  match observation {
    DestinationUnavailable =>
      recovery_evidence(
        request,
        claim,
        reviewed,
        desired,
        "",
        "unavailable",
        Some({
          code: "destination-unavailable",
          message: "the reviewed destination could not be safely inspected",
        }),
      )
    DestinationAbsent => {
      let observed = absent_recovery_state_digest()
      recovery_evidence(
        request,
        claim,
        reviewed,
        desired,
        observed,
        if observed == desired {
          "desired-applied"
        } else if observed == reviewed {
          "reviewed-prestate"
        } else {
          "diverged"
        },
        None,
      )
    }
    DestinationRegular(size_bytes~, fingerprint~) => {
      let observed = regular_recovery_state_digest(size_bytes, fingerprint)
      recovery_evidence(
        request,
        claim,
        reviewed,
        desired,
        observed,
        if observed == desired {
          "desired-applied"
        } else if observed == reviewed {
          "reviewed-prestate"
        } else {
          "diverged"
        },
        None,
      )
    }
  }
}
