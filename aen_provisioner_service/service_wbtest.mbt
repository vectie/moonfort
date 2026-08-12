///|
#borrow(path)
extern "c" fn test_make_fifo_native(path : Bytes, path_len : Int) -> Bool = "moonfort_aen_provisioner_test_make_fifo"

///|
fn test_make_fifo(path : String) -> Bool {
  let path = @utf8.encode(path)
  test_make_fifo_native(path, path.length())
}

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
  max_entries? : Int = 64,
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
        max_entries,
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
  let original = request_body()
  let with_host_path = original[:original.length() - 1].to_owned() +
    ",\"workspaceRoot\":\"/tmp/attacker\"}"
  assert_eq(provision(config.api_key, with_host_path, config).status, 400)
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
  @fs.remove(workspace + "/too-large")
  assert_true(test_make_fifo(workspace + "/pipe"))
  assert_eq(
    provision(config.api_key, request_body(max_bytes=4L), config).status,
    422,
  )
  @fs.remove(workspace + "/pipe")
  @fs.write_file(workspace + "/bad\\name", "x", create_mode=CreateNew)
  assert_eq(
    provision(config.api_key, request_body(max_bytes=4L), config).status,
    422,
  )
  assert_true(@fs.readdir(staging).is_empty())
  assert_true(@fs.readdir(leases).is_empty())
  @fs.rmdir(root, recursive=true)
}

///|
async test "entry bounds and same-size poisoned OCI blobs fail closed" {
  let (root, workspace, staging, artifacts, leases) = test_tree()
  @fs.write_file(workspace + "/one", "1", create_mode=CreateNew)
  @fs.write_file(workspace + "/two", "2", create_mode=CreateNew)
  let bounded = test_config(
    workspace,
    staging,
    artifacts,
    leases,
    max_entries=1,
  )
  assert_eq(provision(bounded.api_key, request_body(), bounded).status, 422)
  @fs.remove(workspace + "/two")
  let config = test_config(workspace, staging, artifacts, leases)
  let first = provision(config.api_key, request_body(), config)
  assert_eq(first.status, 201)
  let lease : ProvisionerLease = @json.from_json(@json.parse(first.body))
  let manifest = artifacts +
    "/blobs/sha256/" +
    lease.image_ref[lease.image_ref.length() - 64:].to_owned()
  let manifest_file = @fs.open(manifest, mode=ReadOnly)
  let manifest_size = manifest_file.size()
  manifest_file.close()
  @fs.remove(manifest)
  @fs.write_file(
    manifest,
    Bytes::make(manifest_size.to_int(), b'x'),
    create_mode=CreateNew,
    permission=0o600,
  )
  assert_eq(provision(config.api_key, request_body(), config).status, 422)
  assert_true(@fs.readdir(staging).is_empty())
  assert_eq(@fs.readdir(leases).length(), 1)
  @fs.rmdir(root, recursive=true)
}

///|
async test "loopback HTTP service enforces authentication and bounded protocol" {
  let (root, workspace, staging, artifacts, leases) = test_tree()
  @fs.write_file(workspace + "/file", "data", create_mode=CreateNew)
  guard @env.rand(2) is Some(random) else { fail("test entropy unavailable") }
  let port = 20_000 + ((random[0].to_int() << 8) | random[1].to_int()) % 30_000
  let config = {
    ..test_config(workspace, staging, artifacts, leases),
    bind_address: "127.0.0.1:\{port}",
  }
  @async.with_task_group(group => {
    let server = group.spawn(() => serve(config), allow_failure=true)
    @async.sleep(20)
    let client = @http.Client("http://127.0.0.1:\{port}")
    let body = request_body()
    let unauthorized = client.post("/v1/workspaces", body, extra_headers={
      "Content-Length": body.length().to_string(),
      "Content-Type": "application/json",
      "X-API-Key": "wrong",
    })
    assert_eq(unauthorized.code, 401)
    client.skip_response_body()
    let accepted = client.post("/v1/workspaces", body, extra_headers={
      "Content-Length": body.length().to_string(),
      "Content-Type": "application/json",
      "X-API-Key": config.api_key,
    })
    assert_eq(accepted.code, 201)
    guard accepted.headers.get("content-length") is Some(raw_length) else {
      fail("provisioner response omitted content-length")
    }
    let length : Int = @strconv.from_str(raw_length)
    let lease : ProvisionerLease = @json.from_json(
      @json.parse(@utf8.decode(client.read_exactly(length))),
    )
    assert_eq(lease.workspace_id, "workspace-main")
    client.close()
    server.cancel()
    ignore(server.wait() catch { _ => () })
  })
  @fs.rmdir(root, recursive=true)
}

///|
async test "configuration loader requires a private regular file and rejects final symlinks" {
  let (root, workspace, staging, artifacts, leases) = test_tree()
  let config_path = root + "/provisioner.json"
  let config_text = Json::object({
    "bind_address": "127.0.0.1:8787".to_json(),
    "api_key": "0123456789abcdef0123456789abcdef".to_json(),
    "receipt_key_id": "test-key-1".to_json(),
    "receipt_key": "abcdef0123456789abcdef0123456789".to_json(),
    "staging_root": staging.to_json(),
    "artifact_root": artifacts.to_json(),
    "lease_root": leases.to_json(),
    "registry_repository": "registry.test/moonfort/workspaces".to_json(),
    "workspaces": Json::object({
      "workspace-main": Json::object({
        "root": workspace.to_json(),
        "max_bytes": "1048576".to_json(),
        "max_entries": (64).to_json(),
        "max_file_bytes": "1048576".to_json(),
      }),
    }),
    "limits": Json::object({
      "max_request_bytes": (16384).to_json(),
      "max_response_bytes": (16384).to_json(),
      "request_timeout_ms": (5000).to_json(),
      "snapshot_timeout_ms": (30000).to_json(),
      "max_connections": (2).to_json(),
    }),
  }).stringify()
  @fs.write_file(
    config_path,
    config_text,
    create_mode=CreateNew,
    permission=0o600,
  )
  assert_eq(
    load_config(config_path).workspaces["workspace-main"].root,
    workspace,
  )
  @fs.chmod(config_path, 0o644)
  try load_config(config_path) catch {
    InvalidConfiguration(_) => ()
    error => fail("unexpected public-config error: \{Repr(error)}")
  } noraise {
    _ => fail("world-readable secret configuration was accepted")
  }
  @fs.remove(config_path)
  let target = root + "/target.json"
  @fs.write_file(target, config_text, create_mode=CreateNew, permission=0o600)
  @fs.symlink(target~, config_path)
  try load_config(config_path) catch {
    InvalidConfiguration(_) => ()
    error => fail("unexpected config-symlink error: \{Repr(error)}")
  } noraise {
    _ => fail("configuration symlink was accepted")
  }
  @fs.rmdir(root, recursive=true)
}
