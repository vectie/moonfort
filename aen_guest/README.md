# Fixed AEN guest runtime

These Linux-only static binaries are the only guest processes MoonFort invokes
directly:

- `guest_attester prepare-and-attest` verifies a provisioner-compatible
  workspace manifest digest, read-only mount state, immutable root manifest,
  helper binaries, and the tool registry before mounting a private overlay.
- `guest_attester inventory` hashes only the overlay upper directory and emits
  the bounded `ScratchInventory` wire shape.
- `guest_attester export-file` accepts one safe relative path plus the exact
  profile, helper digest, regular-file size, SHA-256, and fixed 8 MiB bound.
  It traverses from the prepared scratch dirfd without following links,
  hashes the pinned file and exported bytes in linear time, and emits one
  bounded base64 JSON value. It cannot enumerate or select files independently; the
  host invokes it only for regular post-run entries from the verified diff.
- `guest_attester network-attest` re-verifies its own pinned digest and reads
  every `/proc/sys/net/ipv6/conf/*/disable_ipv6` value without following
  symlinks. It emits success only when IPv6 is absent from the kernel or
  disabled for every present interface.
- `guest_supervisor run` refuses executables outside the digest-pinned tool
  registry, makes the target root recursively read-only except scratch, drops
  to nobody with no-new-privileges, uses a fixed environment and closed stdin,
  and owns a cgroup-v2 subtree whose descendants are killed and verified gone.
  Scratch upper/work storage is a size- and inode-bounded tmpfs, including
  deleted-open allocation and metadata.

The production image must run helpers as root with overlayfs and a writable
cgroup-v2 hierarchy. Missing kernel controls are refusal conditions. The
runtime never invokes a shell, searches `PATH`, reads caller environment, or
falls back to execution outside its cgroup.

Symlinks, directories, special files, and removals are never exported. The
executor reconstructs regular files in its private scratch with mode `0600`,
rehashes the complete result, and binds the exact reviewable manifest into its
TTL retention record before AEN VM and workspace-lease cleanup.

The optional canary tools are closed operations built by
`scripts/build-aen-canary-probes.sh LITERAL_IPV4 PORT EXPECTED_TOKEN OUTPUT_DIR`:

- `moonfort-network-proof-v1` accepts only `probe`, uses a compile-time literal
  IPv4/port and exact request/response over a direct `AF_INET` socket, and does
  not use DNS, TLS, redirects, proxies, or caller environment. Reachability is
  exit 0 with exact marker `MOONFORT_NETWORK_REACHABLE_V1`. Blocked exit 90 is
  only corroborative for `EACCES`/`EPERM` or connect timeout after the same
  endpoint passes the unrestricted positive control. Refusal, routing, and
  protocol failures are distinct and never emit the blocked marker.
- `moonfort-symlink-proof-v1` accepts only `probe SAFE_RELATIVE_SENTINEL`, uses
  fixed `/scratch` and `/workspace` roots, and emits the policy-denied marker
  with exit 91 only for `EROFS`/`EACCES`/`EPERM`. Deployment must validate
  those exact guest roots; the host canary separately verifies the canonical
  sentinel is unchanged.

Add the script's two digest-bearing rows to the tool lock. Packaging never
executes either input and binds both binaries into the sorted tool registry and
executor-root manifest digests.

Build with `make -C aen_guest`. Package with
`scripts/package-aen-guest-rootfs.sh`; that script hashes rather than executes
tool inputs and prints the four digests required in executor-owned AEN config.
