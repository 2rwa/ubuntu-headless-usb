#!/usr/bin/env bash
# Cheap behavior test: output must be emitted while the source is still open.
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
pid=''
cleanup() {
  if [[ -n $pid ]]; then
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
source_log="$tmp/serial.log"
out="$tmp/live.out"
printf 'USB_CI_BOOT_OK\n' > "$source_log"
bash "$here/tests/serial-relay.sh" "$source_log" > "$out" &
pid=$!
printf 'USB_CI_NET_PAM_PASSWORD_DATE_UPDATED\n' >> "$source_log"
seen=0
for ((i=0;i<30;i++)); do
  if grep -Fqx 'USB_CI_NET_PAM_PASSWORD_DATE_UPDATED' "$out" 2>/dev/null; then
    seen=1
    break
  fi
  sleep 0.1
done
[[ $seen == 1 ]] || { echo 'Live relay did not emit serial marker while running' >&2; exit 1; }
grep -Fqx 'USB_CI_BOOT_OK' "$out"
kill -0 "$pid"
echo 'PASS: serial monitor forwards markers before QEMU exits'
