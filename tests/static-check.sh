#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
for script in install.sh lib/provision.sh firstboot-complete.sh register-runner.sh tests/static-check.sh tests/guest-onboard.sh tests/qemu-boot.sh tests/build-image.sh tests/inspect-root.sh tests/safety-test.sh tests/network-bytes.sh tests/guest-network-watch.sh tests/guest-tty1-login-check.sh tests/test_tty1_login_check.sh tests/guest-firstboot-wrapper.sh tests/guest-journal-diagnostics.sh tests/guest-dev-smoke.sh; do
  bash -n "$here/$script"
done
python3 -m py_compile "$here/tests/qemu-vga.py" "$here/tests/qemu-vga-watch.py" "$here/tests/test_vga_watch.py"
python3 "$here/tests/test_vga_watch.py"
grep -Fq 'observe.monitor' "$here/tests/qemu-boot.sh"
grep -Fq 'tests/qemu-vga-watch.py' "$here/tests/vga-smoke.sh"
# Preserve early boot VGA evidence and disable PNG collection BEFORE password input.
grep -Fq 'VGA_BOOT_CAPTURE_STOPPED' "$here/tests/qemu-boot.sh"
grep -Fq -- '--capture-stop-file' "$here/tests/qemu-boot.sh"
grep -Fq 'if [[ $capture_ack != 1 ]]' "$here/tests/qemu-boot.sh"
grep -Fq 'CAPTURE_DISABLED ack=yes' "$here/tests/qemu-vga-watch.py"
grep -Fq 'No boot VGA screenshots captured' "$here/tests/vga-smoke.sh"
grep -Fq 'Observer saved frames after stop acknowledgment' "$here/tests/vga-smoke.sh"
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
# A real tty1 login shell must have the expected UID and a root-owned
# login(1) process as its direct parent; PAM shadow updates alone do not pass.
bash "$here/tests/test_tty1_login_check.sh"
grep -Fq 'usb-ci-tty1-login-check' "$here/lib/provision.sh"
grep -Fq 'usb-ci-tty1-login-check' "$here/tests/guest-network-watch.sh"
grep -Fq 'USB_CI_VGA_LOGIN_OK' "$here/tests/guest-network-watch.sh"
grep -Fq 'USB_CI_NET_PAM_PASSWORD_DATE_UPDATED' "$here/tests/qemu-boot.sh"
! grep -Fq 'usb-ci-vga-login.sh' "$here/lib/provision.sh"
# CI-only firstboot wrapper distinguishes command-not-run from service failure.
grep -Fq 'USB_CI_FIRSTBOOT_BEGIN' "$here/tests/guest-firstboot-wrapper.sh"
grep -Fq 'USB_CI_FIRSTBOOT_OK' "$here/tests/guest-firstboot-wrapper.sh"
grep -Fq 'USB_CI_FIRSTBOOT_FAILED:' "$here/tests/guest-firstboot-wrapper.sh"
grep -Fq 'usb-firstboot-complete.real' "$here/lib/provision.sh"
grep -Fq 'wait_marker USB_CI_FIRSTBOOT_BEGIN 20' "$here/tests/qemu-boot.sh"
grep -Fq 'wait_marker USB_CI_FIRSTBOOT_OK 55' "$here/tests/qemu-boot.sh"
# Real firstboot stage boundaries are sent only by CI guests and never
# include passwords, key bytes, usernames or unbounded stdout.
grep -Fq 'USB_CI_FIRSTBOOT_STAGE_BEGIN:%s' "$here/firstboot-complete.sh"
grep -Fq 'USB_CI_FIRSTBOOT_STAGE_END:%s rc=%d elapsed_s=%d' "$here/firstboot-complete.sh"
grep -Fq 'firstboot_step avahi_enable systemctl enable --now avahi-daemon.service' "$here/firstboot-complete.sh"
grep -Fq 'if [[ -f /etc/ubuntu-usb-ci-vga-mode ]]' "$here/firstboot-complete.sh"
grep -Fq 'usb-ci-journal-diagnostics' "$here/tests/guest-network-watch.sh"
grep -Fq 'journalctl -b -t sudo' "$here/tests/guest-journal-diagnostics.sh"
grep -Fq 'journalctl -b -n 55' "$here/tests/guest-journal-diagnostics.sh"
grep -Fq 'USB_CI_JOURNAL_END' "$here/tests/guest-journal-diagnostics.sh"
# Even when BIOS integration fails, UEFI must still exercise firmware+VGA.
grep -Fq "if: always() && steps.imagebuild.outcome == 'success'" "$here/.github/workflows/usb-ci.yml"
grep -Fq "steps.biosboot.outcome == 'success'" "$here/.github/workflows/usb-ci.yml"
# Guest network diagnostic must finish ahead of host deadline.
grep -Fq 'for ((i=0;i<45;i++))' "$here/tests/guest-network-watch.sh"
grep -Fq 'wait_marker USB_CI_NET_READY 75' "$here/tests/qemu-boot.sh"
grep -Fq 'USB_CI_NET_EARLY_DETAILS_BEGIN' "$here/tests/guest-network-watch.sh"
grep -Fq 'signal FAILED:no-QEMU-DHCP-address' "$here/tests/guest-network-watch.sh"
# CI creation uses umask 077: networkd must still read .network as non-root.
grep -Fq 'chmod 0644 "$ROOT/etc/systemd/network/20-usb-ethernet.network"' "$here/lib/provision.sh"
grep -Fq "network_file=\"\$root/etc/systemd/network/20-usb-ethernet.network\"" "$here/tests/inspect-root.sh"
grep -Fq 'stat -c %a "$network_file"' "$here/tests/inspect-root.sh"
# CI SSH private key is created by sudo but read by the non-root runner.
grep -Fq 'chown "$SUDO_UID:$SUDO_GID" "$keybase" "$keybase.pub"' "$here/tests/build-image.sh"
grep -Fq 'chmod 0600 "$keybase"' "$here/tests/build-image.sh"
grep -Fq 'ssh-keygen -y -f "$key" >/dev/null' "$here/.github/workflows/usb-ci.yml"
grep -Fq 'stat -c %u:%a "$key"' "$here/.github/workflows/usb-ci.yml"
# Distinguish real SSH public-key authentication from remote assertions.
grep -Fq 'SSH_AUTH_PROBE' "$here/tests/qemu-boot.sh"
grep -Fq 'PASS: SSH public-key authentication as expected login user' "$here/tests/qemu-boot.sh"
grep -Fq 'SSH_REMOTE_FAIL:inactive:' "$here/tests/qemu-boot.sh"
grep -Fq 'FAIL: SSH transport/public-key authentication failed' "$here/tests/qemu-boot.sh"
grep -Fq 'FAIL: SSH authenticated but guest network/service assertion failed' "$here/tests/qemu-boot.sh"
# Root-only marker is verified by the guest watcher (ttyS0); the SSH user
# must NOT be asked to read a file under /var/lib/ubuntu-usb (0700).
grep -Fq 'wait_marker USB_CI_NET_ONBOARD_MARKER_SEEN 5' "$here/tests/qemu-boot.sh"
! grep -Fq 'test -f /var/lib/ubuntu-usb/network-enabled' "$here/tests/qemu-boot.sh"
grep -Fq 'SSH_REMOTE_UNIT_OK:' "$here/tests/qemu-boot.sh"
# No password-stage screenshot, even after a successful remote SSH test.
! grep -Fq 'qemu-$mode-vga-after.png' "$here/tests/qemu-boot.sh"
# Full-profile integration must exercise developer runtimes in the built
# image and over unprivileged SSH. Push trigger remains explicitly opt-in.
grep -Fq 'full developer image tools present and runtimes usable' "$here/tests/inspect-root.sh"
grep -Fq 'USB_CI_DEV_SMOKE_OK' "$here/tests/guest-dev-smoke.sh"
grep -Fq 'USB_CI_DEV_COMPILERS_OK' "$here/tests/guest-dev-smoke.sh"
grep -Fq 'USB_CI_DEV_PYTHON_VENV_OK' "$here/tests/guest-dev-smoke.sh"
grep -Fq 'cmake --build "$work/build"' "$here/tests/guest-dev-smoke.sh"
grep -Fq 'ssh_args[@]' "$here/tests/qemu-boot.sh"
grep -Fq 'usb-ci-dev-smoke' "$here/tests/qemu-boot.sh"
grep -Fq 'usb-ci-dev-smoke' "$here/lib/provision.sh"
# This helper must refuse to run outside the disposable guest (no host writes).
if bash "$here/tests/guest-dev-smoke.sh" >/dev/null 2>&1; then
  echo 'ERROR: guest developer smoke script ran on host' >&2; exit 1
fi
grep -Fq "[full-boot-ci-once]" "$here/.github/workflows/usb-ci.yml"
grep -Fq "USB_CI_MINIMAL: " "$here/.github/workflows/usb-ci.yml"
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
bash -n "$here/lib/reliable-install.sh"
bash -n "$here/lib/stage-packages.sh"
bash -n "$here/lib/initial-auth.sh"
bash "$here/tests/test-initial-auth.sh"
bash -n "$here/tests/test-reliable-install.sh"
bash "$here/tests/test-reliable-install.sh"
# Ensure both entrypoints stage before any partitioning and provision only after transfer.
python3 "$here/tests/test-stage-order.py"
printf 'PASS: static and safety checks (no actual disk I/O)\n'