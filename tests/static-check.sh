#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
for script in install.sh lib/provision.sh firstboot-complete.sh register-runner.sh tests/static-check.sh tests/guest-onboard.sh tests/qemu-boot.sh tests/build-image.sh tests/inspect-root.sh tests/safety-test.sh tests/network-bytes.sh tests/guest-network-watch.sh; do
  bash -n "$here/$script"
done
python3 -m py_compile "$here/tests/qemu-vga.py" "$here/tests/qemu-vga-watch.py" "$here/tests/test_vga_watch.py"
python3 "$here/tests/test_vga_watch.py"
grep -Fq 'observe.monitor' "$here/tests/qemu-boot.sh"
grep -Fq 'tests/qemu-vga-watch.py' "$here/tests/vga-smoke.sh"
python3 "$here/tests/test_qemu_vga.py"
bash -n "$here/tests/vga-smoke.sh"
bash -n "$here/tests/serial-relay.sh"
bash -n "$here/tests/test_serial_relay.sh"
bash "$here/tests/test_serial_relay.sh"
grep -Fq 'LIVE_SERIAL_BEGIN' "$here/tests/qemu-boot.sh"
# Polling timeouts are in seconds; a 45-second login timeout must not become 225.
grep -Fq 'SECONDS - started < limit' "$here/tests/qemu-boot.sh"
grep -Fq 'sleep 1' "$here/tests/qemu-boot.sh"
! grep -Fq 'for ((i=0; i<limit; i++))' "$here/tests/qemu-boot.sh"
# Regressions found in the first minimal-image/PAM run:
# only root's guest network watcher writes ttyS0; host marker names match.
grep -Fq '.usb-ci-vga-login-ok' "$here/lib/provision.sh"
grep -Fq '.usb-ci-vga-login-ok' "$here/tests/guest-network-watch.sh"
grep -Fq 'USB_CI_VGA_LOGIN_OK' "$here/tests/guest-network-watch.sh"
grep -Fq 'USB_CI_NET_PAM_PASSWORD_DATE_UPDATED' "$here/tests/qemu-boot.sh"
! grep -Fq 'USB_CI_VGA_LOGIN_OK' "$here/lib/provision.sh"
# Cache must be made readable to the non-root archive saver.
grep -Fq 'sudo chown -R' "$here/.github/workflows/usb-ci.yml"
grep -Fq 'sudo rm -rf -- "$CACHE/partial"' "$here/.github/workflows/usb-ci.yml"
grep -Fxq 'linux-generic' "$here/config/packages-vga.txt"
! grep -Eq '^(npm|nodejs|build-essential|cmake|linux-firmware)$' "$here/config/packages-vga.txt"
bash "$here/install.sh" --help | grep -q -- '--apply'
bash "$here/register-runner.sh" --help | grep -q -- '--url'
# systemd-networkd comes from systemd on Ubuntu 24.04, no standalone package
if grep -qx systemd-networkd "$here/config/packages.txt"; then
  echo 'ERROR: invalid Ubuntu 24.04 systemd-networkd package' >&2; exit 1
fi
# Prevent a future accidental Actions job from performing destructive USB operations.
grep -q '\[\[ -t 0 && -t 1 \]\]' "$here/install.sh"
grep -q 'ERASE ' "$here/install.sh"
grep -q 'read -r ack </dev/tty' "$here/install.sh"
grep -Fq 'chage -d 0 "$LOGIN_USER"' "$here/lib/provision.sh"
grep -q 'PasswordAuthentication no' "$here/lib/provision.sh"
grep -q 'sha256sum -c -' "$here/register-runner.sh"
# A harmless fake path must fail even with --apply.
if bash "$here/install.sh" --hostname usb01 --device /dev/null --ssh-key /dev/null --apply >/dev/null 2>&1; then
  echo 'ERROR: invalid device was accepted' >&2; exit 1
fi
printf 'PASS: static and safety checks (no actual disk I/O)\n'