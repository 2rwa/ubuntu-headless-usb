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
ssh-keygen -A
install -d -m 755 /run/sshd
/usr/sbin/sshd -t
systemctl unmask systemd-networkd.service systemd-networkd.socket \
  systemd-resolved.service ssh.service ssh.socket avahi-daemon.service avahi-daemon.socket
systemctl enable --now systemd-resolved.service
systemctl enable --now systemd-networkd.service
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable --now ssh.service
systemctl enable --now avahi-daemon.service
install -d -m 700 /var/lib/ubuntu-usb
date -u +%FT%TZ > /var/lib/ubuntu-usb/network-enabled
chmod 600 /var/lib/ubuntu-usb/network-enabled
echo 'Networking, mDNS, and SSH (public key only) enabled.'
echo 'Then: sudo usb-register-runner --url https://github.com/2rwa/REPOSITORY'