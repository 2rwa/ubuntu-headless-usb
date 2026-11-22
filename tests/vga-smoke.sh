#!/usr/bin/env bash
# Test QEMU SeaBIOS VGA independently of Ubuntu rootfs and package downloads.
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
[[ -n ${RUNNER_TEMP:-} && -d $RUNNER_TEMP ]] || { echo 'RUNNER_TEMP required' >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo 'qemu-system-x86_64 missing' >&2; exit 1; }
socket="$RUNNER_TEMP/usb-vga-smoke.monitor"
observe_socket="$RUNNER_TEMP/usb-vga-smoke.observe.monitor"
observe_log="$RUNNER_TEMP/usb-vga-smoke-observer.log"
log="$RUNNER_TEMP/usb-vga-smoke-qemu.log"
png="$RUNNER_TEMP/usb-vga-smoke.png"
[[ ! -e $socket && ! -e $observe_socket && ! -e $observe_log && ! -e $png ]] ||
  { echo 'VGA smoke output collision' >&2; exit 1; }
qemu-system-x86_64 -machine q35,accel=tcg -m 128 -smp 1 \
  -display none -vga std -boot menu=on -nic none \
  -monitor "unix:$socket,server=on,wait=off" \
  -monitor "unix:$observe_socket,server=on,wait=off" >"$log" 2>&1 &
pid=$!
observer_pid=''
cleanup() {
  if [[ -n $observer_pid ]]; then
    kill "$observer_pid" 2>/dev/null || :
    wait "$observer_pid" 2>/dev/null || :
  fi
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  rm -f "$socket" "$observe_socket"
}
trap cleanup EXIT
for ((i=0;i<20;i++)); do
  [[ -S $socket ]] && break
  kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; exit 1; }
  sleep 1
done
[[ -S $socket && -S $observe_socket ]] ||
  { echo 'QEMU independent HMP sockets missing' >&2; exit 1; }
sleep 4
# Independent sockets are exercised simultaneously: observing must not
# interrupt keyboard sendkey or the saved diagnostic screenshot.
python3 -u "$here/tests/qemu-vga-watch.py" "$observe_socket" "$observe_log" \
  --frames 3 --interval 0.8 &
observer_pid=$!
python3 "$here/tests/qemu-vga.py" capture "$socket" "$png"
python3 "$here/tests/qemu-vga.py" enter "$socket"
wait "$observer_pid"
observer_pid=''
grep -Fq 'VGA_OBSERVER ' "$observe_log"
grep -Fq 'DONE frames=3' "$observe_log"
echo 'PASS: Two independent QEMU HMP sockets; VGA watcher and keyboard ran concurrently'
