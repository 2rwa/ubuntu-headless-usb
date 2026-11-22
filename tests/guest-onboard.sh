#!/usr/bin/env bash
# CI-only guest-side test: simulates *completed* local password change with chage.
# Never installed on a physical USB; never opens outbound test connections.
set -Eeuo pipefail
signal() { printf '%s\n' "USB_CI_$1" > /dev/ttyS0; }
fail() { signal "ONBOARD_FAILED:$1"; exit 1; }
identity=/var/lib/ubuntu-usb/identity
[[ -f $identity ]] || fail missing-identity
login=$(sed -n 's/^login_user=//p' "$identity")
service=$(sed -n 's/^runner_user=//p' "$identity")
[[ $login =~ ^[a-z_][a-z0-9_-]{0,30}$ && $service =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || fail malformed-identity
if [[ ! -f /var/lib/ubuntu-usb/network-enabled ]]; then
  for unit in ssh.service ssh.socket systemd-networkd.service systemd-resolved.service avahi-daemon.service; do
    [[ $(systemctl is-enabled "$unit" 2>/dev/null) == masked ]] || fail "unmasked-before-onboard:$unit"
  done
  [[ $(awk -F: -v u="$login" '$1==u {print $3}' /etc/shadow) == 0 ]] || fail password-not-expired
  if SUDO_USER="$login" usb-firstboot-complete >/run/usb-ci-expected-refusal.log 2>&1; then
    fail premature-firstboot-accepted
  fi
  grep -Fq 'must change the initial password' /run/usb-ci-expected-refusal.log || fail wrong-refusal
  [[ ! -f /var/lib/ubuntu-usb/network-enabled ]] || fail network-enabled-too-early
  if usb-register-runner --url https://github.com/2rwa/ubuntu-headless-usb >/run/usb-ci-expected-runner-refusal.log 2>&1; then
    fail runner-accepted-before-network
  fi
  grep -Fq 'run usb-firstboot-complete first' /run/usb-ci-expected-runner-refusal.log || fail wrong-runner-refusal
  if SUDO_USER="$service" usb-firstboot-complete >/run/usb-ci-wrong-user.log 2>&1; then
    fail runner-may-onboard
  fi
  signal PRE_ONBOARD_LOCK_OK

  # Simulate PAM's password-change date update, not the interactive PAM flow.
  chage -d "$(date +%F)" "$login"
  [[ $(awk -F: -v u="$login" '$1==u {print $3}' /etc/shadow) =~ ^[1-9][0-9]*$ ]] || fail password-change-transition
  SUDO_USER="$login" usb-firstboot-complete >/run/usb-ci-onboard.log 2>&1 || {
    tail -n 30 /run/usb-ci-onboard.log > /dev/ttyS0
    fail firstboot-complete
  }
  signal PASSWORD_TRANSITION_OK
fi
[[ -f /var/lib/ubuntu-usb/network-enabled ]] || fail missing-network-marker
for unit in systemd-resolved.service systemd-networkd.service ssh.service avahi-daemon.service; do
  systemctl is-active --quiet "$unit" || fail "inactive:$unit"
done
[[ -s /etc/ssh/ssh_host_ed25519_key ]] || fail missing-hostkey
/usr/sbin/sshd -t || fail invalid-sshd
[[ $(systemctl is-enabled ssh.socket) == disabled || $(systemctl is-enabled ssh.socket) == masked ]] || fail ssh-socket-enabled
SUDO_USER="$login" usb-firstboot-complete | grep -Fq 'Already initialized' || fail not-idempotent
signal ONBOARD_OK
