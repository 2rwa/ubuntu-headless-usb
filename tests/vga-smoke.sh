#!/usr/bin/env bash
# Test QEMU SeaBIOS VGA independently of Ubuntu rootfs and package downloads.
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
[[ -n ${RUNNER_TEMP:-} && -d $RUNNER_TEMP ]] || { echo 'RUNNER_TEMP required' >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo 'qemu-system-x86_64 missing' >&2; exit 1; }
socket="$RUNNER_TEMP/usb-vga-smoke.monitor"
observe_socket="$RUNNER_TEMP/usb-vga-smoke.observe.monitor"
observe_log="$RUNNER_TEMP/usb-vga-smoke-observer.log"
capture_dir="$RUNNER_TEMP/usb-vga-smoke-boot-frames"
stop_file="$RUNNER_TEMP/usb-vga-smoke-boot-frames.stop"
ack_file="$RUNNER_TEMP/usb-vga-smoke-boot-frames.stopped"
log="$RUNNER_TEMP/usb-vga-smoke-qemu.log"
png="$RUNNER_TEMP/usb-vga-smoke.png"
[[ ! -e $socket && ! -e $observe_socket && ! -e $observe_log && ! -e $png &&
    ! -e $capture_dir && ! -e $stop_file && ! -e $ack_file ]] ||
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
  --frames 9 --interval 0.6 --capture-dir "$capture_dir" \
  --capture-stop-file "$stop_file" --capture-ack-file "$ack_file" &
observer_pid=$!
sleep 1.2
# Confirm that the early boot screenshots are produced, then close the image
# collection window *before* a simulated keyboard event, without stopping
# concurrent VGA metrics.
[[ $(find "$capture_dir" -maxdepth 1 -name 'boot-*.png' | wc -l) -ge 1 ]] ||
  { echo 'No boot VGA screenshots captured' >&2; exit 1; }
: > "$stop_file"
ack=0
for ((i=0;i<50;i++)); do
  if [[ -f "$ack_file" ]]; then ack=1; break; fi
  sleep 0.1
done
[[ $ack == 1 ]] || { echo 'Observer did not acknowledge screenshot stop' >&2; exit 1; }
before=$(find "$capture_dir" -maxdepth 1 -name 'boot-*.png' | wc -l)
python3 "$here/tests/qemu-vga.py" capture "$socket" "$png"
python3 "$here/tests/qemu-vga.py" enter "$socket"
wait "$observer_pid"
observer_pid=''
after=$(find "$capture_dir" -maxdepth 1 -name 'boot-*.png' | wc -l)
[[ $before == "$after" ]] ||
  { echo 'Observer saved frames after stop acknowledgment' >&2; exit 1; }
grep -Fq 'CAPTURE_DISABLED ack=yes' "$observe_log"
grep -Fq 'DONE frames=9' "$observe_log"
echo 'PASS: Two HMP sockets, timed boot PNGs, screenshot stop handshake and keyboard/metrics concurrency'
