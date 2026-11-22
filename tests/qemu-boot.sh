#!/usr/bin/env bash
set -Eeuo pipefail
mode=$1 image=$2 log=$3
[[ $mode == bios || $mode == uefi ]] || exit 2
[[ -f $image ]] || { echo 'No disk image' >&2; exit 2; }
cmd=(qemu-system-x86_64 -machine q35,accel=tcg -m 2048 -smp 2 -display none
  -monitor none -serial "file:$log" -nic none -drive "file=$image,format=raw,if=virtio")
if [[ $mode == uefi ]]; then
  code=/usr/share/OVMF/OVMF_CODE_4M.fd
  vars=/usr/share/OVMF/OVMF_VARS_4M.fd
  [[ -r $code && -r $vars ]] || { echo 'Missing OVMF 4M firmware' >&2; exit 2; }
  scratch=$(mktemp)
  cp "$vars" "$scratch"
  trap 'rm -f "$scratch"' EXIT
  cmd+=(-drive "if=pflash,format=raw,readonly=on,file=$code"
        -drive "if=pflash,format=raw,file=$scratch")
fi
echo "Booting QEMU $mode (TCG); waiting for userspace marker..."
"${cmd[@]}" >/dev/null 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; }
trap cleanup EXIT
for ((i=0; i<180; i++)); do
  if grep -aq 'USB_CI_BOOT_OK' "$log" 2>/dev/null; then
    echo "PASS: QEMU $mode reached systemd multi-user"
    exit 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "QEMU exited early ($mode)" >&2
    tail -c 2000 "$log" || :
    exit 1
  fi
  sleep 5
done
echo "TIMEOUT: QEMU $mode did not emit userspace marker" >&2
tail -c 5000 "$log" || :
exit 1
