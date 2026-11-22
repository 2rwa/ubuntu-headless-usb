#!/usr/bin/env bash
set -Eeuo pipefail
mode=${1:?mode} image=${2:?image} log=${3:?log}
[[ $mode == bios || $mode == uefi ]] || exit 2
[[ -f $image ]] || { echo 'No disk image' >&2; exit 2; }
# QEMU user networking is restricted from the internet; host SSH port forwarding is local only.
port=22289
cmd=(qemu-system-x86_64 -machine q35,accel=tcg -m 2048 -smp 2 -display none
  -monitor none -serial "file:$log"
  -netdev "user,id=usbci,restrict=on,hostfwd=tcp:127.0.0.1:$port-:22"
  -device virtio-net-pci,netdev=usbci -drive "file=$image,format=raw,if=virtio")
scratch=''
if [[ $mode == uefi ]]; then
  code=/usr/share/OVMF/OVMF_CODE_4M.fd
  vars=/usr/share/OVMF/OVMF_VARS_4M.fd
  [[ -r $code && -r $vars ]] || { echo 'Missing OVMF 4M firmware' >&2; exit 2; }
  scratch=$(mktemp)
  cp "$vars" "$scratch"
  cmd+=(-drive "if=pflash,format=raw,readonly=on,file=$code"
        -drive "if=pflash,format=raw,file=$scratch")
fi
echo "Booting QEMU $mode (TCG); checking OS, onboarding and local SSH..."
"${cmd[@]}" >"$log.qemu-stderr" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  [[ -z $scratch ]] || rm -f "$scratch"
}
trap cleanup EXIT
wait_marker() {
  local marker=$1 limit=${2:-180}
  for ((i=0; i<limit; i++)); do
    if grep -aq "$marker" "$log" 2>/dev/null; then return 0; fi
    if grep -aq 'USB_CI_ONBOARD_FAILED:' "$log" 2>/dev/null; then
      echo "Guest onboarding assertion failed:" >&2
      grep -a 'USB_CI_ONBOARD_FAILED:' "$log" >&2
      return 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "QEMU exited unexpectedly ($mode)" >&2
      tail -c 2000 "$log" >&2 || :
      cat "$log.qemu-stderr" >&2 || :
      return 1
    fi
    sleep 5
  done
  echo "Timed out waiting for $marker ($mode)" >&2
  tail -c 6000 "$log" >&2 || :
  cat "$log.qemu-stderr" >&2 || :
  return 1
}
wait_marker USB_CI_BOOT_OK
echo "PASS: QEMU $mode reached systemd multi-user"
if [[ ${USB_CI_VERIFY_ONBOARD:-0} == 1 ]]; then
  wait_marker USB_CI_ONBOARD_OK
  key="${RUNNER_TEMP:?}/usb-ci-ssh-key"
  [[ -s $key ]] || { echo 'CI private SSH key missing' >&2; exit 1; }
  login=${USB_LOGIN_USER:-developer}
  ssh_args=(-p "$port" -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=6 -o ConnectionAttempts=1)
  verified=0
  for ((i=0;i<15;i++)); do
    if ssh "${ssh_args[@]}" "$login@127.0.0.1"        'test "$(id -un)" = "$USER" && test -f /var/lib/ubuntu-usb/network-enabled && for unit in ssh.service systemd-networkd.service avahi-daemon.service; do systemctl is-active --quiet "$unit" || exit 1; done'; then
      verified=1
      break
    fi
    sleep 3
  done
  [[ $verified == 1 ]] || { echo "Local SSH authentication failed ($mode)" >&2; exit 1; }
  if ssh "${ssh_args[@]}" "root@127.0.0.1" true >/dev/null 2>&1; then
    echo 'Root SSH login unexpectedly succeeded' >&2
    exit 1
  fi
  if ssh "${ssh_args[@]}" "${USB_RUNNER_USER:-buildbot}@127.0.0.1" true >/dev/null 2>&1; then
    echo 'Runner SSH login unexpectedly succeeded' >&2
    exit 1
  fi
  echo "PASS: QEMU $mode onboarding, network services and public-key-only SSH"
fi
