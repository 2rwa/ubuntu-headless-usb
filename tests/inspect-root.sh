#!/usr/bin/env bash
set -Eeuo pipefail
root=$1 login=$2 service=$3 luid=$4 ruid=$5 rootpart=$6 esp=$7
fail() { echo "ROOT INSPECTION FAIL: $*" >&2; exit 1; }
[[ -d $root/etc ]] || fail 'missing root filesystem'
[[ $(chroot "$root" id -u "$login") == "$luid" ]] || fail 'login UID mismatch'
[[ $(chroot "$root" id -u "$service") == "$ruid" ]] || fail 'runner UID mismatch'
chroot "$root" id -nG "$login" | grep -qw sudo || fail 'login lacks sudo'
! chroot "$root" id -nG "$service" | grep -qw sudo || fail 'runner has sudo'
[[ $(awk -F: -v u="$login" '$1 == u {print $3}' "$root/etc/shadow") == 0 ]] || fail 'password not expired'
grep -Fxq "login_user=$login" "$root/var/lib/ubuntu-usb/identity" || fail 'wrong login identity'
grep -Fxq "runner_user=$service" "$root/var/lib/ubuntu-usb/identity" || fail 'wrong runner identity'
grep -Fxq "AllowUsers $login" "$root/etc/ssh/sshd_config.d/60-ubuntu-usb.conf" || fail 'SSH allowed user mismatch'
grep -Fxq "PasswordAuthentication no" "$root/etc/ssh/sshd_config.d/60-ubuntu-usb.conf" || fail 'SSH password auth enabled'
# This is a functional networkd dependency, not merely a style convention:
# the image is built with umask 077 but networkd runs as systemd-network.
network_file="$root/etc/systemd/network/20-usb-ethernet.network"
[[ -f $network_file && ! -L $network_file ]] || fail 'missing regular .network config'
[[ $(stat -c %a "$network_file") == 644 ]] || fail '.network config must be 0644 for unprivileged systemd-networkd'
grep -Fxq 'Name=en* eth*' "$network_file" || fail 'Ethernet match config missing'
grep -Fxq 'DHCP=yes' "$network_file" || fail 'Ethernet DHCP configuration missing'
[[ ! -s $root/etc/machine-id ]] || fail 'machine-id must be blank in template'
[[ ! -e $root/etc/ssh/ssh_host_rsa_key ]] || fail 'SSH host keys pre-generated'
for unit in ssh.service ssh.socket systemd-networkd.service systemd-resolved.service avahi-daemon.service; do
  [[ $(readlink "$root/etc/systemd/system/$unit") == /dev/null ]] || fail "$unit not masked"
done
grep -Fq "UUID=$(blkid -s UUID -o value "$rootpart") / ext4" "$root/etc/fstab" || fail 'root fstab UUID mismatch'
grep -Fq "UUID=$(blkid -s UUID -o value "$esp") /boot/efi vfat" "$root/etc/fstab" || fail 'ESP fstab UUID mismatch'
[[ -f $root/boot/efi/EFI/BOOT/BOOTX64.EFI ]] || fail 'missing removable UEFI GRUB'
compgen -G "$root/boot/vmlinuz-*" >/dev/null || fail 'missing kernel'
compgen -G "$root/boot/initrd.img-*" >/dev/null || fail 'missing initramfs'
[[ -s $root/boot/grub/grub.cfg ]] || fail 'missing generated grub.cfg'
[[ -f $root/usr/local/sbin/usb-firstboot-complete && -f $root/usr/local/sbin/usb-register-runner ]] || fail 'missing helpers'
[[ -f $root/usr/local/sbin/usb-ci-onboard-verify ]] || fail 'CI onboarding tester missing'
[[ -f $root/etc/systemd/system/ubuntu-usb-ci-onboard.service ]] || fail 'CI onboarding service missing'
echo 'PASS: boot files, accounts, network masks, identity, and UUIDs'
if [[ ${USB_CI_MINIMAL:-0} != 1 ]]; then
  # Inspect actual binaries in the generated FULL developer image, not host.
  # The minimal VGA profile deliberately excludes these build tools.
  for tool in gcc g++ make cmake ninja git python3 node npm jq rsync; do
    chroot "$root" /bin/sh -c "command -v $tool" >/dev/null ||
      fail "full image missing $tool"
  done
  chroot "$root" /usr/bin/python3 -c 'import ssl, sqlite3; assert (2+3)==5' ||
    fail 'full image Python runtime failed'
  chroot "$root" /usr/bin/node -e 'if (process.version[0] !== "v") process.exit(1)' ||
    fail 'full image Node runtime failed'
  chroot "$root" /usr/bin/gcc --version >/dev/null ||
    fail 'full image GCC cannot execute'
  chroot "$root" /usr/bin/npm --version >/dev/null ||
    fail 'full image npm cannot execute'
  echo 'PASS: full developer image tools present and runtimes usable'
fi
