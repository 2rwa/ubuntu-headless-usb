#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
source "$here/lib/reliable-install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/lists" "$work/cache"
printf 'correct bytes' > "$work/cache/test_1_all.deb"
printf 'corrupt bytes' > "$work/cache/bad_1_all.deb"
hash=$(sha256sum "$work/cache/test_1_all.deb" | cut -d' ' -f1)
cat > "$work/lists/mirror_Packages" <<EOF
Package: test
Version: 1
Architecture: all
Filename: pool/test_1_all.deb
SHA256: $hash

Package: bad
Version: 1
Architecture: all
Filename: pool/bad_1_all.deb
SHA256: $hash

EOF
if python3 "$here/lib/verify-apt-cache.py" "$work/lists" "$work/cache"; then
  echo 'corrupt same-size archive was accepted' >&2; exit 1
fi
test -f "$work/cache/test_1_all.deb"
test ! -e "$work/cache/bad_1_all.deb"
python3 "$here/lib/verify-apt-cache.py" "$work/lists" "$work/cache"
echo 'PASS: corrupt same-size archive removed; valid archive retained'
# Test the actual retry orchestration without network/dpkg.
downloads=0 installs=0 updates=0 checks=0
sleep() { :; }
usb_apt_update() { updates=$((updates+1)); }
usb_verify_archives() { checks=$((checks+1)); return 0; }
usb_apt() {
  case "$1" in
    --download-only) downloads=$((downloads+1)); (( downloads > 1 ));;
    --no-download) installs=$((installs+1)); return 0;;
    *) return 99;;
  esac
}
usb_apt_transaction install example
[[ $downloads == 2 && $installs == 1 && $updates == 1 ]]
echo 'PASS: failed download retried, dpkg started once'
downloads=0 installs=0
usb_apt() {
  case "$1" in
    --download-only) downloads=$((downloads+1)); return 0;;
    --no-download) installs=$((installs+1)); return 9;;
  esac
}
if usb_apt_transaction install example; then exit 1; fi
[[ $downloads == 1 && $installs == 1 ]]
echo 'PASS: dpkg failure not blindly retried'
usb_apt() {
  case "$1" in
    --download-only) return 0;;
    --no-download) echo 'dpkg must not run'; return 99;;
  esac
}
usb_verify_archives() { [[ ${1:-} == --prune ]]; }
if usb_apt_transaction install example; then exit 1; fi
echo 'PASS: hash verification failure exhausts retry without success'
# Real GPT regression, disposable regular file only; never a real disk.
if command -v sgdisk >/dev/null && command -v wipefs >/dev/null; then
  img="$work/gpt.raw"
  truncate -s 1G "$img"
  sgdisk --clear --new=1:2048:+4MiB "$img"
  # Destroy backup header while leaving primary header intact.
  dd if=/dev/zero of="$img" bs=512 count=1 seek=2097151 conv=notrunc status=none
  usb_partition_gpt "$img"
  LC_ALL=C sgdisk --print "$img" | grep -F 'UBUNTU'
  echo 'PASS: real corrupt backup GPT replaced with valid 3-partition GPT'
elif [[ ${REQUIRE_GPT_TEST:-0} == 1 ]]; then
  echo 'missing sgdisk or wipefs' >&2; exit 1
else
  echo 'SKIP: GPT regression requires gdisk and util-linux'
fi
