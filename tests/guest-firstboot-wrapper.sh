#!/usr/bin/env bash
# CI-only wrapper: run the unmodified real firstboot script as root.
# Keep stdout/stderr on tty1. Export ONLY safe lifecycle markers to ttyS0.
set -Eeuo pipefail
real=/usr/local/sbin/usb-firstboot-complete.real
[[ -x $real ]] || { echo 'Missing CI-wrapped firstboot program' >&2; exit 127; }
# The preflight deliberately tests refusal BEFORE the forced password change.
# Do not emit a success-stage marker for that expected refusal.
if [[ ! -f /etc/ubuntu-usb-ci-vga-mode ]]; then exec "$real" "$@"; fi
login=$(sed -n 's/^login_user=//p' /var/lib/ubuntu-usb/identity)
changed=$(awk -F: -v u="$login" '$1==u {print $3}' /etc/shadow)
if [[ ${SUDO_USER:-} != "$login" || ! $changed =~ ^[1-9][0-9]*$ ]]; then
  exec "$real" "$@"
fi
printf 'USB_CI_FIRSTBOOT_BEGIN\n' > /dev/ttyS0
if "$real" "$@"; then
  printf 'USB_CI_FIRSTBOOT_OK\n' > /dev/ttyS0
else
  rc=$?
  printf 'USB_CI_FIRSTBOOT_ERROR rc=%d\n' "$rc" > /dev/ttyS0
  # The host only aborts once the final FAILED marker arrives, ensuring
  # the selected journal records have first reached the serial artifact.
  /usr/local/sbin/usb-ci-journal-diagnostics || :
  printf 'USB_CI_FIRSTBOOT_FAILED:%d\n' "$rc" > /dev/ttyS0
  exit "$rc"
fi
