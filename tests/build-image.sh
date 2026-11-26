#!/usr/bin/env bash
# GitHub-hosted, opt-in destructive work is strictly confined to a fresh loop image.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 && ${GITHUB_ACTIONS:-} == true && ${USB_CI_EXPLICIT:-} == yes ]] || { echo "Actions explicit opt-in required" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${1:-}
[[ -n ${RUNNER_TEMP:-} && $IMAGE == "$RUNNER_TEMP"/ubuntu-usb-*.raw ]] || { echo 'Image must be in RUNNER_TEMP as ubuntu-usb-*.raw' >&2; exit 1; }
[[ ! -e $IMAGE && ! -L $IMAGE ]] || { echo 'Image already exists: refusing overwrite' >&2; exit 1; }
HOST=usb-ci-01 LOGIN_USER=${USB_LOGIN_USER:-developer} RUNNER_USER=${USB_RUNNER_USER:-buildbot}
LUID=1000 RUID=1001 USB_SKIP_FIRMWARE=${USB_SKIP_FIRMWARE:-1} USB_CI_SERIAL=1
USB_CI_MINIMAL=${USB_CI_MINIMAL:-0}
MIRROR='https://archive.ubuntu.com/ubuntu'
source "$HERE/lib/reliable-install.sh"
[[ $LOGIN_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $RUNNER_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo 'invalid user names' >&2; exit 1; }
[[ $LOGIN_USER != "$RUNNER_USER" && $LOGIN_USER != root && $RUNNER_USER != root ]] || { echo 'account collision' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
DEV='' ROOT='' KEY='' STAGE='' USB_STAGE_VERIFIED=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n $ROOT && $ROOT != "$STAGE" ]]; then
    usb_cleanup_mounts "$ROOT" || rc=1
  fi
  if [[ -n $STAGE ]]; then usb_drop_stage "$STAGE" || rc=1; fi
  if [[ -n $DEV ]]; then losetup -d "$DEV" || rc=1; fi
  if [[ ${USB_CI_KEEP_KEY:-0} != 1 ]]; then
    [[ -z $KEY ]] || rm -f "$KEY" "${KEY%.pub}"
  fi
  if [[ -e $IMAGE ]]; then
    du -h "$IMAGE" || :
    if [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
      chown "$SUDO_UID:$SUDO_GID" "$IMAGE" || :
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
for tool in sgdisk wipefs partprobe udevadm mkfs.vfat mkfs.ext4 debootstrap losetup blkid chroot mount umount rsync; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
usb_stage_begin
source "$HERE/lib/stage-packages.sh"
usb_stage_finish
# Regression: no target image may exist until acquisition/installation succeeds.
[[ ! -e $IMAGE ]] || die 'image created before stage completed'
echo 'USB_CI_TARGET_UNTOUCHED_UNTIL_STAGE_OK'
truncate -s 25G "$IMAGE"
DEV=$(losetup --find --show --partscan "$IMAGE")
[[ $DEV =~ ^/dev/loop[0-9]+$ ]] || { echo "Unexpected loop device $DEV" >&2; exit 1; }
echo "CI test image: $IMAGE, device $DEV; firmware excluded=$USB_SKIP_FIRMWARE"
usb_partition_gpt "$DEV"
partprobe "$DEV"
udevadm settle
ESP="${DEV}p2" ROOTPART="${DEV}p3"
[[ -b $ESP && -b $ROOTPART ]] || { echo 'Loop partitions not detected' >&2; exit 1; }
mkfs.vfat -F32 -n UBUNTU_EFI "$ESP"
mkfs.ext4 -F -L UBUNTU_ROOT "$ROOTPART"
ROOT=$(mktemp -d "$RUNNER_TEMP/ubuntu-usb-root.XXXXXXXX")
mount -o noatime "$ROOTPART" "$ROOT"
usb_copy_stage "$STAGE" "$ROOT"
usb_drop_stage "$STAGE"
STAGE=''
mkdir -p "$ROOT/boot/efi"
mount "$ESP" "$ROOT/boot/efi"
keybase="$RUNNER_TEMP/usb-ci-ssh-key"
[[ ! -e $keybase && ! -L $keybase && ! -e $keybase.pub ]] || { echo "CI key collision" >&2; exit 1; }
ssh-keygen -q -t ed25519 -N '' -f "$keybase"
# Image creation runs under sudo with umask 077. SSH authentication runs
# later as the unprivileged Actions runner; keeping the private key
# root-owned made ssh fail locally with "Load key: Permission denied".
# Transfer only this CI test key to the invoking runner, not credentials in
# the guest image. Preserve SSH's restrictive private-key mode.
[[ ${SUDO_UID:-} =~ ^[0-9]+$ && ${SUDO_GID:-} =~ ^[0-9]+$ ]] || {
  echo 'Missing numeric sudo runner identity for CI SSH key' >&2
  exit 1
}
[[ $(stat -c %u "$RUNNER_TEMP") == "$SUDO_UID" ]] || {
  echo 'Runner temp directory ownership does not match sudo invoker' >&2
  exit 1
}
chown "$SUDO_UID:$SUDO_GID" "$keybase" "$keybase.pub"
chmod 0600 "$keybase"
chmod 0644 "$keybase.pub"
KEY="$keybase.pub"
USB_PROVISION_FROM_WRAPPER=1
source "$HERE/lib/provision.sh"
if [[ ${USB_CI_VGA_LOGIN:-0} == 1 ]]; then
  passfile="$RUNNER_TEMP/usb-ci-initial-password"
  [[ ! -e $passfile && ! -L $passfile ]] || die 'CI password file collision'
  printf '%s\n' "$PASS" > "$passfile"
  chmod 600 "$passfile"
  chown "$(stat -c %u "$RUNNER_TEMP")":"$(stat -c %g "$RUNNER_TEMP")" "$passfile"
fi
bash "$HERE/tests/inspect-root.sh" "$ROOT" "$LOGIN_USER" "$RUNNER_USER" "$LUID" "$RUID" "$ROOTPART" "$ESP"
sync
echo "PASS: provisioned and inspected $IMAGE"
