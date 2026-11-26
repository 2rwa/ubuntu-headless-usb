#!/usr/bin/env bash
# Configure an offline, verified package-complete root already copied to target.
[[ ${USB_PROVISION_FROM_WRAPPER:-0} == 1 && ${USB_STAGE_VERIFIED:-0} == 1 ]] || { echo 'Verified staging required' >&2; exit 1; }
usb_mount_chroot "$ROOT"
rm -f "$ROOT/usr/sbin/policy-rc.d"
printf '%s\n' "$HOST" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $HOST
::1 localhost ip6-localhost ip6-loopback
EOF
echo Asia/Tokyo > "$ROOT/etc/timezone"
chroot "$ROOT" ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
chroot "$ROOT" locale-gen en_US.UTF-8 ja_JP.UTF-8
echo 'LANG=en_US.UTF-8' > "$ROOT/etc/default/locale"
chroot "$ROOT" useradd -m -u "$LUID" -s /bin/bash -G sudo "$LOGIN_USER"
chroot "$ROOT" useradd -m -u "$RUID" -s /usr/sbin/nologin "$RUNNER_USER"
chroot "$ROOT" passwd -l "$RUNNER_USER"
PASS=$(openssl rand -hex 12)
printf '%s:%s\n' "$LOGIN_USER" "$PASS" | chroot "$ROOT" chpasswd
chroot "$ROOT" chage -d 0 "$LOGIN_USER"
mkdir -p "$ROOT/home/$LOGIN_USER/.ssh"
install -m 600 "$KEY" "$ROOT/home/$LOGIN_USER/.ssh/authorized_keys"
chmod 700 "$ROOT/home/$LOGIN_USER/.ssh"
chroot "$ROOT" chown -R "$LOGIN_USER:$LOGIN_USER" "/home/$LOGIN_USER/.ssh"
mkdir -p "$ROOT/etc/systemd/network" "$ROOT/etc/ssh/sshd_config.d" \
  "$ROOT/etc/systemd/journald.conf.d" "$ROOT/var/lib/ubuntu-usb"
cat > "$ROOT/etc/systemd/network/20-usb-ethernet.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF
# CI image builder sets umask 077 for temporary credentials. A .network
# file created under that umask is root-only (0600), while networkd reads
# it as systemd-network: the NIC stays DOWN/unmanaged with no DHCP.
# Make this non-secret interface configuration readable by networkd.
chmod 0644 "$ROOT/etc/systemd/network/20-usb-ethernet.network"
cat > "$ROOT/etc/ssh/sshd_config.d/60-ubuntu-usb.conf" <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers $LOGIN_USER
EOF
cat > "$ROOT/etc/systemd/journald.conf.d/90-ubuntu-usb.conf" <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF
rm -f "$ROOT/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"
# Ubuntu 24.04 uses ssh.socket by default; both activation paths must be blocked.
# An offline console login must be present on real headless hardware.
chroot "$ROOT" systemctl enable getty@tty1.service
chroot "$ROOT" systemctl mask systemd-networkd.service systemd-networkd.socket \
  systemd-resolved.service ssh.service ssh.socket avahi-daemon.service avahi-daemon.socket
install -m 755 "$HERE/firstboot-complete.sh" "$ROOT/usr/local/sbin/usb-firstboot-complete"
install -m 755 "$HERE/register-runner.sh" "$ROOT/usr/local/sbin/usb-register-runner"
printf 'hostname=%s\nlogin_user=%s\nrunner_user=%s\n' "$HOST" "$LOGIN_USER" "$RUNNER_USER" > "$ROOT/var/lib/ubuntu-usb/identity"
: > "$ROOT/etc/machine-id"
rm -f "$ROOT/var/lib/dbus/machine-id"
ln -s /etc/machine-id "$ROOT/var/lib/dbus/machine-id"
rm -f "$ROOT"/etc/ssh/ssh_host_*_key*
RUUID=$(blkid -s UUID -o value "$ROOTPART")
EUUID=$(blkid -s UUID -o value "$ESP")
cat > "$ROOT/etc/fstab" <<EOF
UUID=$RUUID / ext4 defaults,noatime,errors=remount-ro 0 1
UUID=$EUUID /boot/efi vfat umask=0077 0 1
EOF
cat > "$ROOT/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
EOF
if [[ ${USB_CI_SERIAL:-0} == 1 ]]; then
  cat >> "$ROOT/etc/default/grub" <<'CIEOF'
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
CIEOF
  cat > "$ROOT/etc/systemd/system/ubuntu-usb-ci-ready.service" <<'CIEOF'
[Unit]
Description=USB CI boot marker
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'printf "USB_CI_BOOT_OK\\n" > /dev/ttyS0'
[Install]
WantedBy=multi-user.target
CIEOF
  chroot "$ROOT" systemctl enable ubuntu-usb-ci-ready.service
  install -m 755 "$HERE/tests/guest-onboard.sh" "$ROOT/usr/local/sbin/usb-ci-onboard-verify"
  cat > "$ROOT/etc/systemd/system/ubuntu-usb-ci-onboard.service" <<'CIEOF'
[Unit]
Description=USB CI on-guest firstboot and network tests
After=multi-user.target
[Service]
Type=oneshot
TimeoutStartSec=120
ExecStart=/usr/local/sbin/usb-ci-onboard-verify
[Install]
WantedBy=multi-user.target
CIEOF
  chroot "$ROOT" systemctl enable ubuntu-usb-ci-onboard.service
  install -m 755 "$HERE/tests/guest-dev-smoke.sh" "$ROOT/usr/local/sbin/usb-ci-dev-smoke"
  install -m 755 "$HERE/tests/guest-network-watch.sh" "$ROOT/usr/local/sbin/usb-ci-network-watch"
  install -m 755 "$HERE/tests/guest-tty1-login-check.sh" "$ROOT/usr/local/sbin/usb-ci-tty1-login-check"
  install -m 755 "$HERE/tests/guest-journal-diagnostics.sh" "$ROOT/usr/local/sbin/usb-ci-journal-diagnostics"
  # Wrap the real, unchanged firstboot program ONLY in the CI test image.
  # The wrapper emits lifecycle markers; interactive stdout remains on VGA tty1.
  mv "$ROOT/usr/local/sbin/usb-firstboot-complete" "$ROOT/usr/local/sbin/usb-firstboot-complete.real"
  install -m 755 "$HERE/tests/guest-firstboot-wrapper.sh" "$ROOT/usr/local/sbin/usb-firstboot-complete"
  cat > "$ROOT/etc/systemd/system/ubuntu-usb-ci-network-watch.service" <<'CIEOF'
[Unit]
Description=USB CI guest DHCP and SSH readiness check
After=multi-user.target
[Service]
Type=oneshot
TimeoutStartSec=750
ExecStart=/usr/local/sbin/usb-ci-network-watch
[Install]
WantedBy=multi-user.target
CIEOF
  chroot "$ROOT" systemctl enable ubuntu-usb-ci-network-watch.service
  if [[ ${USB_CI_VGA_LOGIN:-0} == 1 ]]; then
    # Test-only: a root-owned watcher verifies the real tty1 login -> shell
    # process relationship. Do not depend on shell startup profile hooks.
    touch "$ROOT/etc/ubuntu-usb-ci-vga-mode"
  fi
fi
chroot "$ROOT" update-initramfs -u -k all
chroot "$ROOT" grub-install --target=i386-pc --recheck "$DEV"
chroot "$ROOT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram --recheck
chroot "$ROOT" update-grub
