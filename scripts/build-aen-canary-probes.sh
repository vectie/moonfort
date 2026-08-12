#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 LITERAL_IPV4 PORT EXPECTED_TOKEN OUTPUT_DIR" >&2
  exit 64
fi
ipv4=$1
port=$2
expected=$3
output=$4
case "$ipv4" in *[!0-9.]*|''|.*|*.) echo "probe endpoint must be a literal IPv4 address" >&2; exit 65;; esac
printf '%s\n' "$ipv4" | awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1; exit 0 } { exit 1 }' || { echo "probe endpoint must be a valid literal IPv4 address" >&2; exit 65; }
case "$port" in *[!0-9]*|'') echo "probe port must be decimal" >&2; exit 65;; esac
test "$port" -ge 1 && test "$port" -le 65535 || { echo "probe port is outside 1..65535" >&2; exit 65; }
case "$expected" in *[!A-Za-z0-9_-]*|'') echo "expected response must be one fixed ASCII token" >&2; exit 65;; esac
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$output"
cc -O2 -pipe -static -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wpedantic -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
  -DMF_NETWORK_PROBE_IPV4="\"$ipv4\"" -DMF_NETWORK_PROBE_PORT="$port" -DMF_NETWORK_PROBE_EXPECTED="\"$expected\"" \
  "$repo_root/aen_guest/runtime.c" "$repo_root/aen_guest/network_proof.c" -Wl,-z,relro,-z,now -o "$output/network-proof"
cc -O2 -pipe -static -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wpedantic -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
  "$repo_root/aen_guest/runtime.c" "$repo_root/aen_guest/symlink_proof.c" -Wl,-z,relro,-z,now -o "$output/symlink-proof"
network_digest=$(sha256sum "$output/network-proof" | awk '{print $1}')
symlink_digest=$(sha256sum "$output/symlink-proof" | awk '{print $1}')
printf 'moonfort-network-proof-v1\t%s\t/opt/moonfort/tools/network-proof\t%s\n' "$output/network-proof" "$network_digest"
printf 'moonfort-symlink-proof-v1\t%s\t/opt/moonfort/tools/symlink-proof\t%s\n' "$output/symlink-proof" "$symlink_digest"
