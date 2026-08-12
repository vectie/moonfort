#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 BASE_IMAGE@sha256:DIGEST TOOL_LOCK OUTPUT_TAG" >&2
  exit 64
fi
base_image=$1
tool_lock=$2
output_tag=$3
case "$base_image" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) echo "base image must be pinned by a full sha256 digest" >&2; exit 65;;
esac

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
make -C "$repo_root/aen_guest" BUILD_DIR="$repo_root/_build/aen-guest/bin"
rm -rf "$repo_root/_build/aen-guest/rootfs"
mkdir -p "$repo_root/_build/aen-guest/rootfs"
digests=$(
  "$repo_root/scripts/package-aen-guest-rootfs.sh" \
    "$repo_root/_build/aen-guest/rootfs" \
    "$repo_root/_build/aen-guest/bin/guest_attester" \
    "$repo_root/_build/aen-guest/bin/guest_supervisor" \
    "$tool_lock"
)

executor_root_digest=$(printf '%s' "$digests" | sed -n 's/.*"executorRootDigest":"\([a-f0-9]*\)".*/\1/p')
attester_digest=$(printf '%s' "$digests" | sed -n 's/.*"guestAttesterDigest":"\([a-f0-9]*\)".*/\1/p')
supervisor_digest=$(printf '%s' "$digests" | sed -n 's/.*"guestSupervisorDigest":"\([a-f0-9]*\)".*/\1/p')
registry_digest=$(printf '%s' "$digests" | sed -n 's/.*"toolRegistryDigest":"\([a-f0-9]*\)".*/\1/p')

docker build --pull=false \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "EXECUTOR_ROOT_DIGEST=$executor_root_digest" \
  --build-arg "GUEST_ATTESTER_DIGEST=$attester_digest" \
  --build-arg "GUEST_SUPERVISOR_DIGEST=$supervisor_digest" \
  --build-arg "TOOL_REGISTRY_DIGEST=$registry_digest" \
  --file "$repo_root/image/aen-executor/Dockerfile" \
  --tag "$output_tag" "$repo_root"
printf '%s\n' "$digests"
