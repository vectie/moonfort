///|
pub(all) enum SandboxBackendKind {
  LocalOs
  MicroVm
  Unavailable
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxNetworkMode {
  Deny
  AllowList
  Unrestricted
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The minimum enforcement state an operator accepts for a run.
///
/// Local OS backends commonly provide useful defense in depth without being
/// able to satisfy the complete profile. Such a run is refused unless the
/// caller selected `AllowDegraded` explicitly.
pub(all) enum SandboxEnforcementRequirement {
  RequireEnforced
  AllowDegraded
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxLimits {
  wall_clock_ms : Int
  cpu_seconds : Int
  memory_mib : Int
  disk_mib : Int
  processes : Int
  output_bytes : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxProfile {
  run_id : String
  workspace_root : String
  scratch_root : String
  backend : SandboxBackendKind
  enforcement_requirement : SandboxEnforcementRequirement
  network : SandboxNetworkMode
  read_only_roots : Array[String]
  allowed_egress : Array[String]
  allowed_commands : Array[String]
  limits : SandboxLimits
  read_only_workspace : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn default_limits() -> SandboxLimits {
  {
    wall_clock_ms: 120_000,
    cpu_seconds: 60,
    memory_mib: 1_024,
    disk_mib: 2_048,
    processes: 256,
    output_bytes: 10 * 1024 * 1024,
  }
}

///|
pub fn local_profile(
  run_id : String,
  workspace_root : String,
  scratch_root : String,
) -> SandboxProfile {
  {
    run_id,
    workspace_root,
    scratch_root,
    backend: LocalOs,
    enforcement_requirement: RequireEnforced,
    network: Deny,
    read_only_roots: [workspace_root],
    allowed_egress: [],
    allowed_commands: ["moon", "git"],
    limits: default_limits(),
    read_only_workspace: true,
  }
}

///|
pub fn profile_is_valid(profile : SandboxProfile) -> Bool {
  profile_rejection(profile) == ""
}

///|
pub fn profile_rejection(profile : SandboxProfile) -> String {
  if profile.run_id.trim() == "" {
    "run_id is required"
  } else if profile.workspace_root.trim() == "" {
    "workspace_root is required"
  } else if profile.scratch_root.trim() == "" {
    "scratch_root is required"
  } else if !path_is_canonical_absolute(profile.workspace_root) {
    "workspace_root must be a canonical absolute path"
  } else if !path_is_canonical_absolute(profile.scratch_root) {
    "scratch_root must be a canonical absolute path"
  } else if roots_overlap(profile.workspace_root, profile.scratch_root) {
    "scratch_root must be disjoint from workspace_root"
  } else if !profile.read_only_workspace {
    "workspace must be read-only"
  } else if profile.read_only_roots.is_empty() {
    "at least one read_only_root is required"
  } else if profile.read_only_roots.any(root => root.trim() == "") {
    "read_only_roots must not contain empty paths"
  } else if profile.read_only_roots.any(root => {
      !path_is_canonical_absolute(root)
    }) {
    "read_only_roots must be canonical absolute paths"
  } else if !profile.read_only_roots.any(root => {
      root == profile.workspace_root ||
      path_contains(root, profile.workspace_root)
    }) {
    "read_only_roots must cover workspace_root"
  } else if profile.read_only_roots.any(root => {
      roots_overlap(root, profile.scratch_root)
    }) {
    "scratch_root must be disjoint from read_only_roots"
  } else if profile.limits.wall_clock_ms <= 0 {
    "wall_clock_ms must be positive"
  } else if profile.limits.cpu_seconds <= 0 {
    "cpu_seconds must be positive"
  } else if profile.limits.memory_mib <= 0 {
    "memory_mib must be positive"
  } else if profile.limits.disk_mib <= 0 {
    "disk_mib must be positive"
  } else if profile.limits.processes <= 0 {
    "processes must be positive"
  } else if profile.limits.output_bytes <= 0 {
    "output_bytes must be positive"
  } else if profile.network is Deny && !profile.allowed_egress.is_empty() {
    "allowed_egress requires AllowList network mode"
  } else if profile.network is Unrestricted &&
    !profile.allowed_egress.is_empty() {
    "allowed_egress is invalid for Unrestricted network mode"
  } else {
    ""
  }
}

///|
/// Return a copy that explicitly opts into best-effort local enforcement.
/// Receipts still report `Degraded`; this never upgrades the backend state.
pub fn SandboxProfile::allow_degraded(self : SandboxProfile) -> SandboxProfile {
  { ..self, enforcement_requirement: AllowDegraded }
}

///|
fn roots_overlap(left : String, right : String) -> Bool {
  let left = strip_trailing_slashes(left)
  let right = strip_trailing_slashes(right)
  left == right || path_contains(left, right) || path_contains(right, left)
}

///|
fn path_contains(root : String, candidate : String) -> Bool {
  if root == "/" {
    candidate.has_prefix("/")
  } else {
    candidate.has_prefix(root + "/")
  }
}

///|
fn strip_trailing_slashes(path : String) -> String {
  for result = path; result.length() > 1 && result.has_suffix("/"); {
    continue result[:result.length() - 1].to_owned()
  } nobreak {
    result
  }
}

///|
fn path_is_canonical_absolute(path : String) -> Bool {
  path.has_prefix("/") &&
  !path.contains("//") &&
  !path.split("/").any(component => component == "." || component == "..") &&
  (path == "/" || !path.has_suffix("/"))
}

///|
pub fn backend_label(backend : SandboxBackendKind) -> String {
  match backend {
    LocalOs => "local-os"
    MicroVm => "microvm"
    Unavailable => "unavailable"
  }
}

///|
pub fn network_label(network : SandboxNetworkMode) -> String {
  match network {
    Deny => "deny"
    AllowList => "allow-list"
    Unrestricted => "unrestricted"
  }
}

///|
pub fn contract_json() -> Json {
  {
    "contract_id": "moonfort-execution-sandbox.v2",
    "version": 2,
    "owner": "moonfort",
    "workspace_owner": "moonbook",
    "execution_owner": "moonclaw",
    "ui_owner": "moondesk",
    "backends": ["local-os", "microvm"],
    "default_network": "deny",
    "workspace_mount": "read-only",
    "missing_enforcement": "refuse",
    "ipc_request": "single-use-approval-id-only",
    "approval_authority": "executor-owned-grant-store",
    "local_backend_ceiling": "degraded",
    "promotion": "explicit-diff-review",
    "required_receipt_fields": [
      "run_id", "approval_id", "approval_digest", "command_digest", "backend", "enforcement",
      "profile_digest", "exit_code", "changed_paths", "artifacts", "output", "output_truncated",
      "output_artifact", "limit_reason", "unverified_limits", "cleanup_verified",
      "retention_id",
    ],
  }
}
