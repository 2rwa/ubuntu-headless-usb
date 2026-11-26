#!/usr/bin/env bash
# Build the package-complete root on builder storage before target partitioning.
[[ ${USB_PROVISION_FROM_WRAPPER:-0} == 1 ]] || { echo 'Validated wrapper required' >&2; exit 1; }
source "$HERE/lib/reliable-install.sh"
printf 'Building Ubuntu 24.04 (noble) on builder storage\n'
DEBOOTSTRAP_ARGS=(--arch=amd64 --variant=minbase)
if [[ -n ${USB_APT_CACHE_DIR:-} ]]; then
  mkdir -p -m 0755 "$USB_APT_CACHE_DIR/debootstrap"
  DEBOOTSTRAP_ARGS+=("--cache-dir=$USB_APT_CACHE_DIR/debootstrap")
fi
debootstrap "${DEBOOTSTRAP_ARGS[@]}" noble "$ROOT" "$MIRROR"
chmod 0755 "$ROOT"
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR noble main restricted universe multiverse
deb $MIRROR noble-updates main restricted universe multiverse
deb https://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
# minbase may not contain CA certificates yet; bootstrap HTTPS using the host bundle.
install -D -m 0644 /etc/ssl/certs/ca-certificates.crt "$ROOT/etc/ssl/certs/ca-certificates.crt"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod 755 "$ROOT/usr/sbin/policy-rc.d"
usb_mount_chroot "$ROOT"
if [[ -n ${USB_APT_CACHE_DIR:-} ]]; then
  mkdir -p "$ROOT/var/cache/apt/archives"
  chmod 0755 "$USB_APT_CACHE_DIR"
  mount --bind "$USB_APT_CACHE_DIR" "$ROOT/var/cache/apt/archives"
fi
updated=0
for attempt in 1 2 3; do
  if usb_apt_update; then updated=1; break; fi
  sleep "$((attempt * 2))"
done
((updated == 1)) || die 'APT index download failed after three attempts'
package_file="$HERE/config/packages.txt"
if [[ ${USB_CI_MINIMAL:-0} == 1 ]]; then
  [[ ${USB_CI_EXPLICIT:-} == yes && ${GITHUB_ACTIONS:-} == true && ${USB_CI_SERIAL:-0} == 1 ]] ||
    die 'CI minimal profile not allowed for physical USB'
  package_file="$HERE/config/packages-vga.txt"
fi
mapfile -t PKGS < <(grep -E '^[a-z0-9][a-z0-9+.-]*$' "$package_file")
if [[ ${USB_SKIP_FIRMWARE:-0} == 1 ]]; then
  mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | grep -v '^linux-firmware$')
fi
printf 'Package profile: %s (%d direct packages)\n' "$package_file" "${#PKGS[@]}"
((${#PKGS[@]} > 0)) || die 'empty package list'
usb_apt_transaction install --no-install-recommends "${PKGS[@]}"
usb_apt_transaction upgrade
# Do not leave installer-only cache configuration in the guest.
rm -f "$ROOT/etc/apt/apt.conf.d/91-usb-cache"
audit=$(chroot "$ROOT" dpkg --audit)
[[ -z $audit ]] || { printf '%s\n' "$audit" >&2; die 'incomplete package configuration'; }
usb_apt check
compgen -G "$ROOT/boot/vmlinuz-*" >/dev/null || die 'staged root missing kernel'
compgen -G "$ROOT/boot/initrd.img-*" >/dev/null || die 'staged root missing initramfs'
echo 'USB_STAGE_PACKAGES_OK: all downloads and package installation completed'
