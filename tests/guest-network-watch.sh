#!/usr/bin/env bash
# CI-only diagnostic of real DHCP/address/SSH readiness. Never in physical installs.
set -Eeuo pipefail
signal() { printf '%s\n' "USB_CI_NET_$1" > /dev/ttyS0; }
# Allow slow TCG interactive PAM without preempting host-side diagnosis.
limit=180
[[ -f /etc/ubuntu-usb-ci-vga-mode ]] && limit=600
for ((i=0;i<limit;i++)); do
  [[ ! -f /var/lib/ubuntu-usb/network-enabled ]] || break
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
