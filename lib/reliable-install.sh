#!/usr/bin/env bash
# Shared helpers. Only call disk operations after the caller validates the target.
usb_partition_gpt() {
  local disk=$1 report
  # Remove detectable old signatures first. A corrupt backup GPT can make
  # sgdisk --zap-all report failure even though it erased the table.
  wipefs --all --force "$disk" || return
  sgdisk --zap-all "$disk" || return
  sgdisk --clear --new=1:1MiB:+2MiB --typecode=1:EF02 --change-name=1:BIOS_BOOT \
    --new=2:0:+512MiB --typecode=2:EF00 --change-name=2:EFI \
    --new=3:0:0 --typecode=3:8300 --change-name=3:UBUNTU "$disk" || return
  report=$(LC_ALL=C sgdisk --verify "$disk") || return
  printf '%s\n' "$report"
  grep -Fq 'No problems found' <<< "$report"
}
usb_cleanup_mounts() {
  local root=$1 dir n failed=0
  [[ -n $root ]] || return 0
  for dir in var/cache/apt/archives run sys proc dev boot/efi ''; do
    local target="$root${dir:+/$dir}"
    for n in 1 2 3; do
      mountpoint -q "$target" || break
      umount -R "$target" && break
      sleep 1
    done
    if mountpoint -q "$target"; then
      echo "ERROR: still mounted: $target" >&2
      findmnt -R "$target" >&2 || :
      if command -v fuser >/dev/null; then fuser -vm "$target" >&2 || :; fi
      failed=1
    fi
  done
  if ((failed == 0)); then rmdir "$root" 2>/dev/null || :; fi
  return "$failed"
}
usb_apt() {
  chroot "$ROOT" apt-get -o Acquire::Retries=3 \
    -o Acquire::http::No-Cache=true -o Acquire::https::No-Cache=true \
    -o Acquire::http::Timeout=60 -o Acquire::https::Timeout=60 \
    -o APT::Keep-Downloaded-Packages=true "$@"
}
usb_apt_update() {
  usb_apt -o APT::Update::Error-Mode=any update
}
usb_verify_archives() {
  python3 "$HERE/lib/verify-apt-cache.py" "$ROOT/var/lib/apt/lists" "$ROOT/var/cache/apt/archives" "$@"
}
usb_apt_transaction() {
  local attempt
  # Download and independently verify the archive bytes before starting
  # dpkg. Retry only acquisition, never blindly repeat a failed dpkg run.
  for attempt in 1 2 3; do
    printf 'APT acquisition attempt %s/3: %s\n' "$attempt" "$1"
    if ((attempt > 1)); then
      sleep "$((attempt * 2))"
      usb_apt_update || continue
    fi
    usb_verify_archives --prune || continue
    if usb_apt --download-only -y "$@" && usb_verify_archives; then
      usb_apt --no-download -y "$@" || return
      return 0
    fi
    echo 'APT acquisition/integrity failed; retaining verified cache for retry.' >&2
  done
  echo 'ERROR: APT acquisition exhausted; verified archives retained on builder.' >&2
  return 1
}
