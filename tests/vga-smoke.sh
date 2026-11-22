#!/usr/bin/env bash
# Test QEMU SeaBIOS VGA independently of Ubuntu rootfs and package downloads.
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
[[ -n ${RUNNER_TEMP:-} && -d $RUNNER_TEMP ]] || { echo 'RUNNER_TEMP required' >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo 'qemu-system-x86_64 missing' >&2; exit 1; }
socket="$RUNNER_TEMP/usb-vga-smoke.monitor"
log="$RUNNER_TEMP/usb-vga-smoke-qemu.log"
png="$RUNNER_TEMP/usb-vga-smoke.png"
[[ ! -e $socket && ! -e $png ]] || { echo 'VGA smoke output collision' >&2; exit 1; }
qemu-system-x86_64 -machine q35,accel=tcg -m 128 -smp 1 \
  -display none -vga std -boot menu=on -nic none \
  -monitor "unix:$socket,server=on,wait=off" >"$log" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  rm -f "$socket"
}
trap cleanup EXIT
for ((i=0;i<20;i++)); do
  [[ -S $socket ]] && break
  kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; exit 1; }
  sleep 1
done
[[ -S $socket ]] || { echo 'QEMU HMP socket missing' >&2; exit 1; }
sleep 4
python3 "$here/tests/qemu-vga.py" capture "$socket" "$png"
python3 "$here/tests/qemu-vga.py" enter "$socket"
echo 'PASS: SeaBIOS VGA capture and HMP keyboard command (no guest OS)'
