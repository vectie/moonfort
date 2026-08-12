#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 ROOTFS ATTTESTER SUPERVISOR TOOL_LOCK" >&2
  exit 64
fi

rootfs=$1
attester=$2
supervisor=$3
tool_lock=$4

case "$rootfs" in
  /*) ;;
  *) echo "ROOTFS must be absolute" >&2; exit 64 ;;
esac

for input in "$attester" "$supervisor" "$tool_lock"; do
  test -f "$input" || { echo "missing regular input: $input" >&2; exit 66; }
  test ! -L "$input" || { echo "symbolic-link input refused: $input" >&2; exit 66; }
done

install -d -m 0755 "$rootfs/opt/moonfort/bin" "$rootfs/opt/moonfort/etc" "$rootfs/opt/moonfort/tools"
install -m 0555 "$attester" "$rootfs/opt/moonfort/bin/attester"
install -m 0555 "$supervisor" "$rootfs/opt/moonfort/bin/supervisor"

registry="$rootfs/opt/moonfort/etc/tool-registry.tsv"
: > "$registry"
tab=$(printf '\t')
while IFS="$tab" read -r label source image_path expected extra; do
  test -n "$label" || continue
  test -z "${extra:-}" || { echo "malformed tool lock row" >&2; exit 65; }
  case "$label" in *[!A-Za-z0-9_.:-]*|'') echo "unsafe tool label" >&2; exit 65;; esac
  case "$image_path" in /opt/moonfort/tools/*) ;; *) echo "tool image path escapes fixed registry" >&2; exit 65;; esac
  test -f "$source" && test ! -L "$source" || { echo "unsafe tool source" >&2; exit 66; }
  actual=$(sha256sum "$source" | awk '{print $1}')
  test "$actual" = "$expected" || { echo "tool digest mismatch for $label" >&2; exit 65; }
  destination="$rootfs$image_path"
  install -d -m 0755 "$(dirname "$destination")"
  install -m 0555 "$source" "$destination"
  printf '%s\t%s\t%s\n' "$label" "$image_path" "$expected" >> "$registry"
done < "$tool_lock"

LC_ALL=C sort -o "$registry" "$registry"
test -s "$registry" || { echo "tool lock must contain at least one fixed tool" >&2; exit 65; }
chmod 0444 "$registry"

manifest="$rootfs/opt/moonfort/etc/executor-root.manifest"
: > "$manifest"
find "$rootfs/opt/moonfort" -type f ! -path "$manifest" -print | LC_ALL=C sort | while IFS= read -r file; do
  relative=${file#"$rootfs"}
  size=$(stat -c %s "$file")
  digest=$(sha256sum "$file" | awk '{print $1}')
  printf 'F\t%s\t%s\t%s\n' "$relative" "$size" "$digest"
done > "$manifest"
chmod 0444 "$manifest"

attester_digest=$(sha256sum "$rootfs/opt/moonfort/bin/attester" | awk '{print $1}')
supervisor_digest=$(sha256sum "$rootfs/opt/moonfort/bin/supervisor" | awk '{print $1}')
registry_digest=$(sha256sum "$registry" | awk '{print $1}')
root_digest=$(sha256sum "$manifest" | awk '{print $1}')
printf '{"executorRootDigest":"%s","guestAttesterDigest":"%s","guestSupervisorDigest":"%s","toolRegistryDigest":"%s"}\n' \
  "$root_digest" "$attester_digest" "$supervisor_digest" "$registry_digest"
