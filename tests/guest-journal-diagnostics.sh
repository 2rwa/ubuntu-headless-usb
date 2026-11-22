#!/usr/bin/env bash
# CI-only, bounded systemd journal diagnostics to the live QEMU serial log.
# Never stream an interactive shell, VGA prompt, secrets or arbitrary journals.
set -Eeuo pipefail
[[ $EUID == 0 && -f /etc/ubuntu-usb-ci-vga-mode ]] || exit 2
{
  printf 'USB_CI_JOURNAL_BEGIN\n'
  printf 'USB_CI_TTY1_PROCESSES_BEGIN\n'
  ps -t tty1 -o pid,ppid,uid,comm --no-headers || :
  printf 'USB_CI_TTY1_PROCESSES_END\n'
  for unit in ssh.service ssh.socket systemd-resolved.service systemd-networkd.service avahi-daemon.service; do
    state=$(systemctl is-active "$unit" 2>/dev/null || :)
    printf 'USB_CI_UNIT_STATE name=%s state=%s\n' "$unit" "${state:-unknown}"
  done
  if [[ -f /var/lib/ubuntu-usb/network-enabled ]]; then
    printf 'USB_CI_NETWORK_MARKER present\n'
  else
    printf 'USB_CI_NETWORK_MARKER absent\n'
  fi
  # Narrow scope: only sudo's authorization records and known service units.
  # journalctl --no-pager emits no interactive prompts.
  printf 'USB_CI_JOURNAL_SUDO_BEGIN\n'
  journalctl -b -t sudo -n 20 --no-pager --output=short-monotonic || :
  printf 'USB_CI_JOURNAL_SUDO_END\n'
  printf 'USB_CI_JOURNAL_UNITS_BEGIN\n'
  journalctl -b -n 55 --no-pager --output=short-monotonic \
    -u ssh.service -u ssh.socket \
    -u systemd-resolved.service -u systemd-networkd.service \
    -u avahi-daemon.service -u getty@tty1.service || :
  printf 'USB_CI_JOURNAL_UNITS_END\n'
  printf 'USB_CI_JOURNAL_END\n'
} > /dev/ttyS0 2>&1
