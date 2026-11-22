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
MIRROR='http://archive.ubuntu.com/ubuntu'
[[ $LOGIN_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $RUNNER_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo 'invalid user names' >&2; exit 1; }
[[ $LOGIN_USER != "$RUNNER_USER" && $LOGIN_USER != root && $RUNNER_USER != root ]] || { echo 'account collision' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
DEV='' ROOT='' KEY=''
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n $ROOT ]]; then
    for d in var/cache/apt/archives run sys proc dev boot/efi; do
      mountpoint -q "$ROOT/$d" && umount -R "$ROOT/$d" || :
    done
    mountpoint -q "$ROOT" && umount "$ROOT" || :
    rmdir "$ROOT" 2>/dev/null || :
  fi
  [[ -z $DEV ]] || losetup -d "$DEV" || :
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
for tool in sgdisk partprobe udevadm mkfs.vfat mkfs.ext4 debootstrap losetup blkid chroot mount umount; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
truncate -s 25G "$IMAGE"
DEV=$(losetup --find --show --partscan "$IMAGE")
[[ $DEV =~ ^/dev/loop[0-9]+$ ]] || { echo "Unexpected loop device $DEV" >&2; exit 1; }
echo "CI test image: $IMAGE, device $DEV; firmware excluded=$USB_SKIP_FIRMWARE"
sgdisk --zap-all "$DEV"
sgdisk --clear --new=1:1MiB:+2MiB --typecode=1:EF02 --change-name=1:BIOS_BOOT \
  --new=2:0:+512MiB --typecode=2:EF00 --change-name=2:EFI \
  --new=3:0:0 --typecode=3:8300 --change-name=3:UBUNTU "$DEV"
partprobe "$DEV"
udevadm settle
ESP="${DEV}p2" ROOTPART="${DEV}p3"
[[ -b $ESP && -b $ROOTPART ]] || { echo 'Loop partitions not detected' >&2; exit 1; }
mkfs.vfat -F32 -n UBUNTU_EFI "$ESP"
mkfs.ext4 -F -L UBUNTU_ROOT "$ROOTPART"
ROOT=$(mktemp -d "$RUNNER_TEMP/ubuntu-usb-root.XXXXXXXX")
mount -o noatime "$ROOTPART" "$ROOT"
mkdir -p "$ROOT/boot/efi"
mount "$ESP" "$ROOT/boot/efi"
keybase="$RUNNER_TEMP/usb-ci-ssh-key"
[[ ! -e $keybase && ! -L $keybase && ! -e $keybase.pub ]] || { echo "CI key collision" >&2; exit 1; }
ssh-keygen -q -t ed25519 -N '' -f "$keybase"
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
