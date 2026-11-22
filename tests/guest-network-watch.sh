#!/usr/bin/env bash
# CI-only diagnostic of real DHCP/address/SSH readiness. Never in physical installs.
set -Eeuo pipefail
signal() { printf '%s\n' "USB_CI_NET_$1" > /dev/ttyS0; }
# Allow slow TCG interactive PAM without preempting host-side diagnosis.
limit=180
vga=0
if [[ -f /etc/ubuntu-usb-ci-vga-mode ]]; then
  limit=600
  vga=1
  login=$(sed -n 's/^login_user=//p' /var/lib/ubuntu-usb/identity)
fi
reported=0
login_reported=0
login_pending_reported=0
pam_change_at=0
if [[ $vga == 1 ]]; then
  expected_uid=$(id -u "$login")
  login_shell=$(getent passwd "$login" | awk -F: '{print $7}')
  login_shell=${login_shell##*/}
  [[ $login_shell =~ ^[a-zA-Z0-9_.+-]+$ ]] ||
    { signal FAILED:invalid-login-shell; exit 1; }
fi
for ((i=0;i<limit;i++)); do
  [[ ! -f /var/lib/ubuntu-usb/network-enabled ]] || break
  if [[ $vga == 1 && $reported == 0 ]]; then
    last_change=$(awk -F: -v u="$login" '$1==u {print $3}' /etc/shadow)
    if [[ $last_change =~ ^[1-9][0-9]*$ ]]; then
      signal PAM_PASSWORD_DATE_UPDATED
      reported=1
      pam_change_at=$SECONDS
    fi
  fi
  # A password-date update alone is insufficient. Verify the actual user
  # shell is an immediate child of a root-owned login(1) process on tty1.
  # This is CI-only and does not depend on /etc/profile.d being sourced or
  # on giving a non-root user write access to the serial device.
  if [[ $vga == 1 && $reported == 1 && $login_reported == 0 ]]; then
    if ps -t tty1 -o pid=,ppid=,uid=,comm= |
         /usr/local/sbin/usb-ci-tty1-login-check "$expected_uid" "$login_shell"; then
      printf 'USB_CI_VGA_LOGIN_OK\n' > /dev/ttyS0
      login_reported=1
    fi
  fi
  # If the expected login shell is still missing, publish *only* a safe
  # process summary for diagnosis, never a password or VGA framebuffer.
  if [[ $vga == 1 && $reported == 1 && $login_reported == 0 &&
        $login_pending_reported == 0 ]] && (( SECONDS - pam_change_at >= 10 )); then
    signal LOGIN_MARKER_PENDING
    ps -t tty1 -o pid,ppid,user,comm --no-headers > /dev/ttyS0 2>&1 || :
    login_pending_reported=1
  fi
  sleep 1
done
[[ -f /var/lib/ubuntu-usb/network-enabled ]] || { signal FAILED:no-onboard-marker; exit 1; }
for ((i=0;i<60;i++)); do
  address=$(ip -o -4 addr show scope global | grep -E 'inet 10[.]0[.]2[.]' || :)
  [[ -z $address ]] || break
  sleep 1
done
{
  echo 'USB_CI_NET_DETAILS_BEGIN'
  ip -o -4 addr show || :
  ip -4 route show || :
  networkctl list --no-pager || :
  ss -ltn || :
  echo 'USB_CI_NET_DETAILS_END'
} > /dev/ttyS0 2>&1
[[ -n ${address:-} ]] || { signal FAILED:no-QEMU-DHCP-address; exit 1; }
ss -ltn | grep -Eq '[:.]22[[:space:]]' || { signal FAILED:ssh-port-not-listening; exit 1; }
signal READY
