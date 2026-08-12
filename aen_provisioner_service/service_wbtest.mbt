///|
async fn test_tree() -> (String, String, String, String, String) {
  let root = @fs.realpath(@fs.tmpdir(prefix="moonfort-aen-provisioner-"))
  let workspace = root + "/workspace"
  let staging = root + "/staging"
  let artifacts = root + "/artifacts"
  let leases = root + "/leases"
  @fs.mkdir(workspace, permission=0o700)
  @fs.mkdir(staging, permission=0o700)
  @fs.mkdir(artifacts, permission=0o700)
  @fs.mkdir(leases, permission=0o700)
  (root, workspace, staging, artifacts, leases)
}

///|
fn test_config(
  workspace : String,
  staging : String,
  artifacts : String,
  leases : String,
  max_bytes? : Int64 = 1_048_576L,
) -> ProvisionerConfig {
  {
    bind_address: "127.0.0.1:8787",
    api_key: "0123456789abcdef0123456789abcdef",
    receipt_key_id: "test-key-1",
    receipt_key: "abcdef0123456789abcdef0123456789",
    staging_root: staging,
    artifact_root: artifacts,
    lease_root: leases,
    registry_repository: "registry.test/moonfort/workspaces",
    workspaces: {
      "workspace-main": {
        root: workspace,
        max_bytes,
        max_entries: 64,
        max_file_bytes: max_bytes,
      },
    },
    limits: {
      max_request_bytes: 16_384,
      max_response_bytes: 16_384,
      request_timeout_ms: 5_000,
      snapshot_timeout_ms: 30_000,
      max_connections: 2,
    },
  }
}

///|
fn request_body(
  max_bytes? : Int64 = 1_048_576L,
  workspace_id? : String = "workspace-main",
  reject_symlinks? : Bool = true,
) -> String {
  Json::object({
    "protocolVersion": 2,
    "runID": "run-1",
    "workspaceID": workspace_id,
    "profileDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "maxBytes": max_bytes.to_string(),
    "rejectSymlinks": reject_symlinks,
    "requireImmutableImageDigest": true,
  }).stringify()
}

///|
async test "provisions deterministic content-addressed OCI blobs and signed leases" {
  let (root, workspace, staging, artifacts, leases) = test_tree()
  @fs.mkdir(workspace + "/src", permission=0o700)
  @fs.write_file(
    workspace + "/src/main.mbt",
    "fn main { println(\"ok\") }\n",
    create_mode=CreateNew,
  )
  @fs.write_file(workspace + "/README.md", "hello\n", create_mode=CreateNew)
  let config = test_config(workspace, staging, artifacts, leases)
  let first = provision(config.api_key, request_body(), config)
  assert_eq(first.status, 201)
  let first_lease : ProvisionerLease = @json.from_json(@json.parse(first.body))
  assert_true(
    first_lease.image_ref.has_prefix(
      "registry.test/moonfort/workspaces@sha256:",
    ),
  )
  assert_eq(first_lease.receipt_key_id, "test-key-1")
  assert_eq(first_lease.entry_count, 3)
  assert_eq(first_lease.total_bytes, 32L)
  assert_true(first_lease.staging_cleanup_verified)
  assert_true(
    constant_time_equal(
      first_lease.receipt_mac,
      receipt_mac(config.receipt_key, { ..first_lease, receipt_mac: "" }),
    ),
  )
  assert_true(@fs.readdir(staging).is_empty())
  assert_true(
    @fs.exists(
      artifacts +
      "/blobs/sha256/" +
      first_lease.image_ref[first_lease.image_ref.length() - 64:].to_owned(),
    ),
  )
  let second = provision(config.api_key, request_body(), config)
  assert_eq(second.status, 201)
  let second_lease : ProvisionerLease = @json.from_json(
    @json.parse(second.body),
  )
  assert_eq(first_lease.workspace_digest, second_lease.workspace_digest)
  assert_eq(first_lease.image_ref, second_lease.image_ref)
  assert_true(first_lease.lease_id != second_lease.lease_id)
  assert_eq(release(config.api_key, first_lease.lease_id, config).status, 204)
  assert_eq(release(config.api_key, first_lease.lease_id, config).status, 404)
  @fs.rmdir(root, recursive=true)
}

///|
async test "authentication, registry identity, and mandatory policy fail closed" {
  let (root, workspace, staging, artifacts, leases) = test_tree()
  @fs.write_file(workspace + "/file", "data", create_mode=CreateNew)
  let config = test_config(workspace, staging, artifacts, leases)
  assert_eq(provision("wrong", request_body(), config).status, 401)
  let unknown = request_body(workspace_id="not-registered")
  assert_eq(provision(config.api_key, unknown, config).status, 403)
  let permits_links = request_body(reject_symlinks=false)
  assert_eq(provision(config.api_key, permits_links, config).status, 400)
  assert_eq(release(config.api_key, "../escape", config).status, 400)
  assert_true(@fs.readdir(staging).is_empty())
  assert_true(@fs.readdir(leases).is_empty())
  @fs.rmdir(root, recursive=true)
}

///|
async test "symlinks and oversized files are refused without lease or staging residue" {
  let (root, workspace, staging, artifacts, leases) = test_tree()
  let outside = root + "/outside"
  @fs.write_file(outside, "secret", create_mode=CreateNew)
  @fs.symlink(target=outside, workspace + "/link")
  let config = test_config(workspace, staging, artifacts, leases, max_bytes=4L)
  assert_eq(
    provision(config.api_key, request_body(max_bytes=4L), config).status,
    422,
  )
  @fs.remove(workspace + "/link")
  @fs.write_file(workspace + "/too-large", "12345", create_mode=CreateNew)
  assert_eq(
    provision(config.api_key, request_body(max_bytes=4L), config).status,
    422,
  )
  assert_true(@fs.readdir(staging).is_empty())
  assert_true(@fs.readdir(leases).is_empty())
  @fs.rmdir(root, recursive=true)
}
