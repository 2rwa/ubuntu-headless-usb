#!/usr/bin/env bash
set -Eeuo pipefail
mode=${1:?mode} image=${2:?image} log=${3:?log}
[[ $mode == bios || $mode == uefi ]] || exit 2
[[ -f $image ]] || { echo 'No disk image' >&2; exit 2; }
# QEMU user networking is restricted from the internet; host SSH port forwarding is local only.
port=22289
cmd=(qemu-system-x86_64 -machine q35,accel=tcg -m 2048 -smp 2 -display none
  -monitor "unix:${RUNNER_TEMP:?}/qemu-$mode.monitor,server=on,wait=off"
  # A second HMP socket permits VGA observation while the first sends keys.
  -monitor "unix:${RUNNER_TEMP:?}/qemu-$mode.observe.monitor,server=on,wait=off"
  -vga std -serial "file:$log"
  -netdev "user,id=usbci,restrict=on,hostfwd=tcp:127.0.0.1:$port-:22"
  -device virtio-net-pci,netdev=usbci -drive "file=$image,format=raw,if=virtio")
scratch=''
monitor="${RUNNER_TEMP:?}/qemu-$mode.monitor"
observe_monitor="${RUNNER_TEMP:?}/qemu-$mode.observe.monitor"
[[ ! -e $monitor && ! -e $observe_monitor ]] ||
  { echo "QEMU monitor socket collision" >&2; exit 1; }
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
# QEMU writes the complete serial console to a retained artifact file.
# Also follow it LIVE into the GitHub Actions step, rather than hiding all
# systemd/PAM messages until the marker wait times out.
[[ ! -e $log && ! -L $log ]] || { echo "Serial log collision: $log" >&2; exit 1; }
: > "$log"
echo "LIVE_SERIAL_BEGIN mode=$mode source=$log"
bash tests/serial-relay.sh "$log" &
serial_relay_pid=$!
"${cmd[@]}" >"$log.qemu-stderr" 2>&1 &
pid=$!
# Preserve readable VGA boot-console images and correlate with ttyS0 timestamps.
# The capture-stop ACK must arrive before *any* simulated keyboard input:
# the observer continues METRICS ONLY for the rest of PAM/SSH verification.
boot_capture_dir="${RUNNER_TEMP:?}/qemu-$mode-boot-frames"
boot_capture_stop="${RUNNER_TEMP:?}/qemu-$mode-boot-frames.stop"
boot_capture_ack="${RUNNER_TEMP:?}/qemu-$mode-boot-frames.stopped"
echo "LIVE_VGA_BEGIN mode=$mode independent_monitor=$observe_monitor"
python3 -u tests/qemu-vga-watch.py "$observe_monitor" \
  "${RUNNER_TEMP:?}/qemu-$mode-vga-watch.log" \
  --capture-dir "$boot_capture_dir" \
  --capture-stop-file "$boot_capture_stop" \
  --capture-ack-file "$boot_capture_ack" \
  --max-captures 20 &
vga_watch_pid=$!
cleanup() {
  kill "$vga_watch_pid" 2>/dev/null || :
  wait "$vga_watch_pid" 2>/dev/null || :
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  kill "$serial_relay_pid" 2>/dev/null || :
  wait "$serial_relay_pid" 2>/dev/null || :
  [[ -z $scratch ]] || rm -f "$scratch"
  rm -f "$monitor" "$observe_monitor"
  echo "LIVE_VGA_END mode=$mode"
  echo "LIVE_SERIAL_END mode=$mode"
}
trap cleanup EXIT
wait_marker() {
  # The limit is a wall-clock timeout in SECONDS, not a loop iteration
  # count. The previous 5-second polling made a '45' timeout 225 seconds.
  local marker=$1 limit=${2:-180} started=$SECONDS
  echo "Waiting for $marker ($mode, timeout ${limit}s)"
  while (( SECONDS - started < limit )); do
    if grep -aq "$marker" "$log" 2>/dev/null; then
      echo "Observed $marker after $((SECONDS - started))s"
      return 0
    fi
    if grep -aq 'USB_CI_FIRSTBOOT_FAILED:' "$log" 2>/dev/null; then
      echo "Guest firstboot program returned failure:" >&2
      grep -a 'USB_CI_FIRSTBOOT_FAILED:' "$log" >&2
      return 1
    fi
    if grep -aq 'USB_CI_NET_FAILED:' "$log" 2>/dev/null; then
      echo "Guest network diagnostic failed:" >&2
      grep -a 'USB_CI_NET_FAILED:' "$log" >&2
      tail -c 6000 "$log" >&2 || :
      return 1
    fi
    if grep -aq 'USB_CI_ONBOARD_FAILED:' "$log" 2>/dev/null; then
      echo "Guest onboarding assertion failed:" >&2
      grep -a 'USB_CI_ONBOARD_FAILED:' "$log" >&2
      return 1
    fi
    if ! kill -0 "$vga_watch_pid" 2>/dev/null; then
      echo "Concurrent VGA observer exited unexpectedly ($mode)" >&2
      tail -n 20 "${RUNNER_TEMP:?}/qemu-$mode-vga-watch.log" >&2 || :
      return 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "QEMU exited unexpectedly ($mode)" >&2
      tail -c 2000 "$log" >&2 || :
      cat "$log.qemu-stderr" >&2 || :
      return 1
    fi
    sleep 1
  done
  echo "Timed out waiting for $marker after $((SECONDS - started))s ($mode)" >&2
  tail -c 6000 "$log" >&2 || :
  cat "$log.qemu-stderr" >&2 || :
  return 1
}
wait_marker USB_CI_BOOT_OK
echo "PASS: QEMU $mode reached systemd multi-user"
# Capture real tty1 VGA text, even with serial as the primary kernel console.
# On any failure, the capture utility preserves a diagnostic PNG in artifacts.
sleep 3
python3 tests/qemu-vga.py tty1 "$monitor"
sleep 3
python3 tests/qemu-vga.py capture "$monitor" "${RUNNER_TEMP:?}/qemu-$mode-vga-before.png"
# Close the image-capture window BEFORE typing username or passwords.
# The separate VGA observer stays alive, reporting only change metrics.
: > "$boot_capture_stop"
capture_ack=0
for ((capture_wait=0;capture_wait<80;capture_wait++)); do
  if [[ -f $boot_capture_ack ]]; then
    capture_ack=1
    break
  fi
  if ! kill -0 "$vga_watch_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
if [[ $capture_ack != 1 ]]; then
  echo 'VGA observer did not acknowledge snapshot shutdown; refusing keyboard input' >&2
  exit 1
fi
echo "VGA_BOOT_CAPTURE_STOPPED mode=$mode image_dir=$boot_capture_dir"
if [[ ${USB_CI_VERIFY_ONBOARD:-0} == 1 ]]; then
  if [[ $mode == bios && ${USB_CI_VGA_LOGIN:-0} == 1 ]]; then
    wait_marker USB_CI_PRE_ONBOARD_LOCK_OK 60
    initial="${RUNNER_TEMP:?}/usb-ci-initial-password"
    replacement="${RUNNER_TEMP:?}/usb-ci-next-password"
    [[ -s $initial && ! -e $replacement ]] || { echo 'CI password file missing or reused' >&2; exit 1; }
    umask 077
    openssl rand -hex 12 > "$replacement"
    # Authenticate on the emulated VGA tty1 and complete the genuine PAM
    # password-expiry conversation, not a chage simulation.
    python3 tests/qemu-vga.py type "$monitor" "${USB_LOGIN_USER:-developer}"
    sleep 3
    # Capture only after the username, before typing any secret.
    # Later password-stage screens are deliberately never uploaded.
    python3 tests/qemu-vga.py capture "$monitor" "${RUNNER_TEMP:?}/qemu-$mode-vga-username.png"
    python3 tests/qemu-vga.py type-file "$monitor" "$initial"
    sleep 3
    python3 tests/qemu-vga.py type-file "$monitor" "$initial"
    sleep 3
    python3 tests/qemu-vga.py type-file "$monitor" "$replacement"
    sleep 3
    python3 tests/qemu-vga.py type-file "$monitor" "$replacement"
    if ! wait_marker USB_CI_VGA_LOGIN_OK 45; then
      if grep -aq USB_CI_NET_PAM_PASSWORD_DATE_UPDATED "$log"; then
        echo 'PAM did update shadow, but a tty1 login shell marker was not observed' >&2
      else
        echo 'No PAM password-change evidence was observed on the guest serial port' >&2
      fi
      exit 1
    fi
    echo 'PASS: real VGA tty1 login and forced PAM password change'
    python3 tests/qemu-vga.py type "$monitor" 'sudo usb-firstboot-complete'
    sleep 3
    python3 tests/qemu-vga.py type-file "$monitor" "$replacement"
    # The CI-only wrapper reports whether sudo actually reached the command
    # and whether it returned successfully; journal diagnostics report why.
    wait_marker USB_CI_FIRSTBOOT_BEGIN 20
    # Under TCG the five systemctl transitions vary by >20s between runs.
    # Retain the overall 180s cap; stage timings identify real stalls.
    wait_marker USB_CI_FIRSTBOOT_OK 55
    echo 'PASS: sudo firstboot actually started and completed'
    # SSH verifies that the service start and network unmask succeeded.
  else
    wait_marker USB_CI_ONBOARD_OK
  fi
  # Guest's 45s DHCP deadline plus journal diagnostics must fit here;
  # the earlier 60s/60s race killed the VM before its failure evidence.
  wait_marker USB_CI_NET_READY 75
  # The guest's ROOT watcher checks /var/lib/ubuntu-usb/network-enabled
  # (parent is 0700). Never require the unprivileged SSH login user to
  # traverse that protected directory.
  wait_marker USB_CI_NET_ONBOARD_MARKER_SEEN 5
  key="${RUNNER_TEMP:?}/usb-ci-ssh-key"
  [[ -s $key ]] || { echo 'CI private SSH key missing' >&2; exit 1; }
  login=${USB_LOGIN_USER:-developer}
  ssh_args=(-p "$port" -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=6 -o ConnectionAttempts=1)
  # Keep authentication separate from the remote systemd assertions.
  # The former test silently retried a compound command 15 times: a remote
  # service test failure looked identical to a rejected SSH public key.
  verified=0
  for ((i=1;i<=5;i++)); do
    remote_user=$(ssh "${ssh_args[@]}" "$login@127.0.0.1" 'id -un') && verified=1 || :
    if [[ $verified == 1 ]]; then break; fi
    echo "SSH_AUTH_PROBE attempt=$i result=failed"
    sleep 2
  done
  if [[ $verified != 1 ]]; then
    echo "FAIL: SSH transport/public-key authentication failed ($mode)" >&2
    # Only show selected SSH negotiation facts; no private key bytes,
    # passwords, full ssh -vv transcript or remote user journals.
    ssh_diag=$(mktemp "${RUNNER_TEMP:?}/ssh-auth-diag.XXXXXXXX")
    chmod 600 "$ssh_diag"
    ssh -vv "${ssh_args[@]}" "$login@127.0.0.1" 'true' >/dev/null 2>"$ssh_diag" || :
    grep -E 'Connection established|connect to address|Authentications that can continue|Offering public key|Server accepts key|Authenticated to|Permission denied|Connection refused|Connection timed out|No route to host|No more authentication methods' "$ssh_diag" >&2 || :
    rm -f "$ssh_diag"
    exit 1
  fi
  [[ $remote_user == "$login" ]] || {
    echo "FAIL: SSH authenticated as unexpected user ($mode)" >&2; exit 1;
  }
  echo "PASS: SSH public-key authentication as expected login user ($mode)"
  if ! ssh "${ssh_args[@]}" "$login@127.0.0.1" '
    # Root-only onboarding marker is tested by guest CI watcher over serial.
    # A successful unprivileged SSH login can inspect service state instead.
    for unit in ssh.service systemd-networkd.service avahi-daemon.service; do
      if systemctl is-active --quiet "$unit"; then
        echo "SSH_REMOTE_UNIT_OK:$unit"
      else
        echo "SSH_REMOTE_FAIL:inactive:$unit"; exit 1;
      fi
    done
  '; then
    echo "FAIL: SSH authenticated but guest network/service assertion failed ($mode)" >&2
    exit 1
  fi
  echo "PASS: root-watcher onboard marker and unprivileged remote service checks ($mode)"
  if ssh "${ssh_args[@]}" "root@127.0.0.1" true >/dev/null 2>&1; then
    echo 'Root SSH login unexpectedly succeeded' >&2
    exit 1
  fi
  if ssh "${ssh_args[@]}" "${USB_RUNNER_USER:-buildbot}@127.0.0.1" true >/dev/null 2>&1; then
    echo 'Runner SSH login unexpectedly succeeded' >&2
    exit 1
  fi
  echo "PASS: QEMU $mode onboarding, network services and public-key-only SSH"
  # Credential-phase VGA contents must NEVER be captured to artifacts;
  # the observer already disabled screenshots before any password entry.
fi
