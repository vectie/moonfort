# Fixed AEN guest runtime

These Linux-only static binaries are the only guest processes MoonFort invokes
directly:

- `guest_attester prepare-and-attest` verifies a provisioner-compatible
  workspace manifest digest, read-only mount state, immutable root manifest,
  helper binaries, and the tool registry before mounting a private overlay.
- `guest_attester inventory` hashes only the overlay upper directory and emits
  the bounded `ScratchInventory` wire shape.
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

Build with `make -C aen_guest`. Package with
`scripts/package-aen-guest-rootfs.sh`; that script hashes rather than executes
tool inputs and prints the four digests required in executor-owned AEN config.
