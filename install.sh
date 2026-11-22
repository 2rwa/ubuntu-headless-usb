#!/usr/bin/env bash
# Ubuntu 24.04 headless USB installer. No disk changes without --apply + interactive confirmation.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOST='' LINK='' KEY='' APPLY=0 LOGIN_USER=koyama RUNNER_USER=runner LUID=1000 RUID=1001
USB_SKIP_FIRMWARE=0
MIRROR='http://archive.ubuntu.com/ubuntu'
ROOT=''
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { cat <<'HELP'
Ubuntu 24.04 minimal USB installer (amd64, no GUI)
Usage: sudo ./install.sh --device /dev/disk/by-id/usb-... --hostname usb01 \
  --ssh-key /home/USER/.ssh/id_ed25519.pub [--login-user USER] [--runner-user USER] [--login-uid 1000] [--runner-uid 1001] [--skip-firmware] [--apply]
Default is read-only dry-run. --apply additionally requires an interactive, exact confirmation.
HELP
}
while (($#)); do
  case "$1" in
    --device|--hostname|--ssh-key|--login-user|--runner-user|--login-uid|--koyama-uid|--runner-uid|--mirror)
      (($# >= 2)) || die "missing value for $1"
      case "$1" in
        --device) LINK=$2;; --hostname) HOST=$2;; --ssh-key) KEY=$2;;
        --login-user) LOGIN_USER=$2;; --runner-user) RUNNER_USER=$2;;
        --login-uid|--koyama-uid) LUID=$2;; --runner-uid) RUID=$2;; --mirror) MIRROR=$2;;
      esac
      shift 2;;
    --apply) APPLY=1; shift;;
    --skip-firmware) USB_SKIP_FIRMWARE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[[ $EUID == 0 ]] || die 'root required'
[[ $(dpkg --print-architecture) == amd64 ]] || die 'amd64 host required'
[[ $HOST =~ ^[a-z][a-z0-9-]{0,62}$ && $HOST != *- ]] || die 'invalid hostname'
[[ $HOST != "$(hostname -s)" ]] || die 'target hostname must differ from builder host'
[[ $LOGIN_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $RUNNER_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die 'invalid user name'
[[ $LOGIN_USER != root && $RUNNER_USER != root && $LOGIN_USER != "$RUNNER_USER" ]] || die 'user names conflict'
[[ $LUID =~ ^[0-9]+$ && $RUID =~ ^[0-9]+$ ]] || die 'UIDs must be numeric'
((LUID >= 1000 && RUID >= 1000 && LUID != RUID)) || die 'UIDs conflict'
[[ $LINK == /dev/disk/by-id/usb-* && -L $LINK ]] || die 'use a /dev/disk/by-id/usb-* symlink'
DEV=$(readlink -f -- "$LINK")
[[ -b $DEV && $(lsblk -dnro TYPE "$DEV") == disk ]] || die 'not a whole disk'
[[ $(lsblk -dnro TRAN "$DEV") == usb ]] || die 'not USB transport'
[[ $(lsblk -dnro RO "$DEV") == 0 ]] || die 'read-only device'
SIZE=$(lsblk -bdnro SIZE "$DEV")
((SIZE >= 24 * 1024 * 1024 * 1024)) || die 'need at least 24 GiB'
[[ -r $KEY && -f $KEY ]] || die 'pass a readable SSH public key via --ssh-key'
ssh-keygen -lf "$KEY" >/dev/null || die 'invalid SSH public key'
[[ -f $HERE/config/packages.txt && -f $HERE/firstboot-complete.sh && -f $HERE/register-runner.sh ]] || die 'companion files missing'
[[ $MIRROR =~ ^https?://[a-zA-Z0-9._:/-]+$ ]] || die 'invalid mirror URL'
check_idle() {
  [[ $(readlink -f -- "$LINK") == "$DEV" ]] || die 'USB target changed'
  if lsblk -nrpo MOUNTPOINTS "$DEV" | grep -q '[^[:space:]]'; then
    die 'USB or descendant is mounted; unmount it manually first'
  fi
  if lsblk -nrpo TYPE "$DEV" | grep -Eq '^(lvm|crypt|raid[0-9]*|md)$'; then
    die 'USB has active mapped/RAID descendants'
  fi
  while IFS= read -r node; do
    [[ -n $node ]] || continue
    if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$node"; then
      die 'USB has active swap'
    fi
  done < <(lsblk -nrpo PATH "$DEV")
}
check_idle
printf '\nTARGET (ERASED ONLY WITH --apply):\n'
lsblk -dn -o PATH,MODEL,SERIAL,TRAN,SIZE "$DEV"
printf 'by-id=%s\nhostname=%s\nusers: %s=%s %s=%s\nfirmware=%s\nSSH key=%s\nmode=%s\n\n' \
  "$LINK" "$HOST" "$LOGIN_USER" "$LUID" "$RUNNER_USER" "$RUID" \
  "$([[ $USB_SKIP_FIRMWARE == 1 ]] && echo OMIT || echo INCLUDE)" "$KEY" "$([[ $APPLY == 1 ]] && echo APPLY || echo DRY-RUN)"
((APPLY == 1)) || { echo 'Dry-run complete. No changes.'; exit 0; }
[[ -t 0 && -t 1 ]] || die '--apply requires an interactive terminal, not Actions'
for tool in sgdisk partprobe udevadm mkfs.vfat mkfs.ext4 debootstrap blkid mount umount openssl; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
printf 'Type EXACTLY: ERASE %s %s\n> ' "$HOST" "$DEV"
IFS= read -r ack </dev/tty
[[ $ack == "ERASE $HOST $DEV" ]] || die 'confirmation mismatch'
check_idle
cleanup() {
  [[ -n $ROOT ]] || return 0
  local dir
  for dir in var/cache/apt/archives run sys proc dev boot/efi; do
    mountpoint -q "$ROOT/$dir" && umount -R "$ROOT/$dir" || :
  done
  mountpoint -q "$ROOT" && umount "$ROOT" || :
  rmdir "$ROOT" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 130' INT TERM
printf 'Creating GPT on %s\n' "$DEV"
sgdisk --zap-all "$DEV"
sgdisk --clear --new=1:1MiB:+2MiB --typecode=1:EF02 --change-name=1:BIOS_BOOT \
  --new=2:0:+512MiB --typecode=2:EF00 --change-name=2:EFI \
  --new=3:0:0 --typecode=3:8300 --change-name=3:UBUNTU "$DEV"
partprobe "$DEV"; udevadm settle
if [[ $DEV =~ [0-9]$ ]]; then SEP=p; else SEP=''; fi
ESP="$DEV$SEP"2; ROOTPART="$DEV$SEP"3
[[ -b $ESP && -b $ROOTPART ]] || die 'partition nodes missing'
mkfs.vfat -F32 -n UBUNTU_EFI "$ESP"
mkfs.ext4 -F -L UBUNTU_ROOT "$ROOTPART"
ROOT=$(mktemp -d /mnt/ubuntu-usb.XXXXXXXX)
mount -o noatime "$ROOTPART" "$ROOT"
mkdir -p "$ROOT/boot/efi"
mount "$ESP" "$ROOT/boot/efi"
USB_PROVISION_FROM_WRAPPER=1
source "$HERE/lib/provision.sh"
sync
printf '\nSUCCESS — WRITE DOWN ONE-TIME PASSWORD (NOT SAVED IN PLAINTEXT):\n'
printf 'Hostname: %s  Login: %s  Password: %s\n' "$HOST" "$LOGIN_USER" "$PASS"
printf 'First boot OFFLINE; login and change password, then run:\n  sudo usb-firstboot-complete\n'
printf 'Only then will network, SSH and mDNS be enabled.\n'