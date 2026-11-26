#!/usr/bin/env bash
# Ubuntu 24.04 headless USB installer. No disk changes without --apply + interactive confirmation.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOST='' LINK='' KEY='' APPLY=0 LOGIN_USER=koyama RUNNER_USER=runner LUID=1000 RUID=1001
USB_SKIP_FIRMWARE=0
MIRROR='https://archive.ubuntu.com/ubuntu'
USB_APT_CACHE_DIR=${USB_APT_CACHE_DIR:-/var/cache/ubuntu-headless-usb}
source "$HERE/lib/reliable-install.sh"
source "$HERE/lib/initial-auth.sh"
set +x
unset PASS
PASS=''
ROOT='' STAGE='' USB_STAGE_VERIFIED=0
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { cat <<'HELP'
Ubuntu 24.04 minimal USB installer (amd64, no GUI)
Usage: sudo ./install.sh --device /dev/disk/by-id/usb-... --hostname usb01 \
  --ssh-key /home/USER/.ssh/id_ed25519.pub [--login-user USER] [--runner-user USER] [--login-uid 1000] [--runner-uid 1001] [--skip-firmware] [--apply]
Default is read-only dry-run. --apply additionally requires an interactive, exact confirmation.
APT archives are cached on the builder in /var/cache/ubuntu-headless-usb (override USB_APT_CACHE_DIR).
All packages are installed into a staging root and verified before the USB is erased.
With --apply, choose and confirm an initial password before the build starts.
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
[[ -f $HERE/config/packages.txt && -f $HERE/firstboot-complete.sh && -f $HERE/register-runner.sh && -f $HERE/lib/provision.sh && -f $HERE/lib/verify-apt-cache.py ]] || die 'companion files missing'
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
printf 'APT cache on builder: %s\n' "$USB_APT_CACHE_DIR"
for tool in sgdisk wipefs partprobe udevadm mkfs.vfat mkfs.ext4 debootstrap blkid mount umount openssl flock python3 findmnt rsync; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
[[ -r /etc/ssl/certs/ca-certificates.crt && -x /usr/lib/apt/apt-helper ]] || die 'missing host CA certificates or apt-helper'
((APPLY == 1)) || { echo 'Dry-run complete. No changes.'; exit 0; }
[[ -t 0 && -t 1 ]] || die '--apply requires an interactive terminal, not Actions'
printf 'Type EXACTLY: ERASE %s %s\n> ' "$HOST" "$DEV"
IFS= read -r ack </dev/tty
[[ $ack == "ERASE $HOST $DEV" ]] || die 'confirmation mismatch'
usb_prompt_password </dev/tty >/dev/tty 2>/dev/tty || die 'initial password input cancelled'
check_idle
# Persistent cache must not be on the target or writable by a non-root user.
[[ $USB_APT_CACHE_DIR == /* && ! -L $USB_APT_CACHE_DIR ]] || die 'cache must be an absolute non-symlink directory'
mkdir -p -m 0755 "$USB_APT_CACHE_DIR"
[[ $(stat -c %u "$USB_APT_CACHE_DIR") == 0 ]] || die 'cache must be root owned'
cache_mode=$(stat -c %a "$USB_APT_CACHE_DIR")
(( (8#$cache_mode & 022) == 0 )) || die 'cache must not be group/world writable'
cache_source=$(findmnt -n -o SOURCE -T "$USB_APT_CACHE_DIR")
while IFS= read -r node; do
  [[ $cache_source != "$node" && $cache_source != "${node}["* ]] || die 'cache is on target disk'
done < <(lsblk -nrpo PATH "$DEV")
exec 9>"$USB_APT_CACHE_DIR/.install.lock"
flock -n 9 || die 'another USB installation is using the cache'
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n $ROOT && $ROOT != "$STAGE" ]] && ! usb_cleanup_mounts "$ROOT"; then
    echo "ERROR: cleanup incomplete; do not unplug USB ($ROOT)" >&2
    ((rc != 0)) || rc=1
  fi
  if [[ -n $STAGE ]] && ! usb_drop_stage "$STAGE"; then
    echo "ERROR: staging cleanup incomplete: $STAGE" >&2
    ((rc != 0)) || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# No USB partition or filesystem changes before package preparation succeeds.
stage_source=$(findmnt -n -o SOURCE -T /var/tmp)
while IFS= read -r node; do
  [[ $stage_source != "$node" && $stage_source != "${node}["* ]] || die 'staging storage is on target disk'
done < <(lsblk -nrpo PATH "$DEV")
usb_stage_begin
source "$HERE/lib/stage-packages.sh"
usb_stage_finish
check_idle
[[ $(lsblk -bdnro SIZE "$DEV") == "$SIZE" ]] || die 'target size changed'
printf 'Creating GPT on %s\n' "$DEV"
usb_partition_gpt "$DEV"
partprobe "$DEV"; udevadm settle
if [[ $DEV =~ [0-9]$ ]]; then SEP=p; else SEP=''; fi
ESP="$DEV$SEP"2; ROOTPART="$DEV$SEP"3
[[ -b $ESP && -b $ROOTPART ]] || die 'partition nodes missing'
mkfs.vfat -F32 -n UBUNTU_EFI "$ESP"
mkfs.ext4 -F -L UBUNTU_ROOT "$ROOTPART"
ROOT=$(mktemp -d /mnt/ubuntu-usb.XXXXXXXX)
mount -o noatime "$ROOTPART" "$ROOT"
usb_copy_stage "$STAGE" "$ROOT"
usb_drop_stage "$STAGE"
STAGE=''
mkdir -p "$ROOT/boot/efi"
mount "$ESP" "$ROOT/boot/efi"
USB_PROVISION_FROM_WRAPPER=1
source "$HERE/lib/provision.sh"
sync
if ! usb_cleanup_mounts "$ROOT"; then
  printf 'Installation configured; use the initial password entered at startup.\n' >&2
  die "unmount incomplete: $ROOT; do not unplug"
fi
ROOT=''
unset PASS
printf '\nSUCCESS — USE THE INITIAL PASSWORD ENTERED AT STARTUP\n'
printf 'Hostname: %s  Login: %s\n' "$HOST" "$LOGIN_USER"
printf 'First boot OFFLINE; login and change password, then run:\n  sudo usb-firstboot-complete\n'
printf 'Only then will network, SSH and mDNS be enabled.\n'