#!/usr/bin/env bash
# Run after the forced password change at the physical console.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Use: sudo usb-firstboot-complete' >&2; exit 1; }
[[ -f /var/lib/ubuntu-usb/identity ]] || { echo 'Not an ubuntu-usb installation' >&2; exit 1; }
LOGIN_USER=$(sed -n 's/^login_user=//p' /var/lib/ubuntu-usb/identity)
[[ $LOGIN_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo 'Invalid installation identity' >&2; exit 1; }
[[ ${SUDO_USER:-} == "$LOGIN_USER" ]] || { echo "Must be invoked by $LOGIN_USER via sudo" >&2; exit 1; }
if [[ -f /var/lib/ubuntu-usb/network-enabled ]]; then echo 'Already initialized'; exit 0; fi
lastchange=$(awk -F: -v u="$LOGIN_USER" '$1==u {print $3}' /etc/shadow)
[[ $lastchange =~ ^[1-9][0-9]*$ ]] || {
  echo "$LOGIN_USER must change the initial password locally before networking is enabled" >&2; exit 1;
}
# Emit bounded, nonsecret timings on ttyS0 only in disposable CI images.
# Physical USB media have no /etc/ubuntu-usb-ci-vga-mode flag, so their
# firstboot sequence and interactive stdout/stderr remain unchanged.
firstboot_step() {
  local name=$1 started=$SECONDS rc=0
  shift
  if [[ -f /etc/ubuntu-usb-ci-vga-mode ]]; then
    printf 'USB_CI_FIRSTBOOT_STAGE_BEGIN:%s\n' "$name" > /dev/ttyS0 || :
  fi
  "$@" || rc=$?
  if [[ -f /etc/ubuntu-usb-ci-vga-mode ]]; then
    printf 'USB_CI_FIRSTBOOT_STAGE_END:%s rc=%d elapsed_s=%d\n' \
      "$name" "$rc" "$((SECONDS - started))" > /dev/ttyS0 || :
  fi
  return "$rc"
}
firstboot_step hostkey_generation ssh-keygen -A
firstboot_step ssh_runtime_directory install -d -m 755 /run/sshd
firstboot_step ssh_config_check /usr/sbin/sshd -t
firstboot_step unmask_services systemctl unmask systemd-networkd.service systemd-networkd.socket \
  systemd-resolved.service ssh.service ssh.socket avahi-daemon.service avahi-daemon.socket
firstboot_step resolved_enable systemctl enable --now systemd-resolved.service
firstboot_step networkd_enable systemctl enable --now systemd-networkd.service
firstboot_step ssh_socket_disable systemctl disable --now ssh.socket 2>/dev/null || true
firstboot_step ssh_enable systemctl enable --now ssh.service
firstboot_step avahi_enable systemctl enable --now avahi-daemon.service
install -d -m 700 /var/lib/ubuntu-usb
date -u +%FT%TZ > /var/lib/ubuntu-usb/network-enabled
chmod 600 /var/lib/ubuntu-usb/network-enabled
echo 'Networking, mDNS, and SSH (public key only) enabled.'
echo 'Then: sudo usb-register-runner --url https://github.com/2rwa/REPOSITORY'