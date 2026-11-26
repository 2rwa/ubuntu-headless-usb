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

usb_mount_chroot() {
  local root=$1 dir
  for dir in dev proc sys; do
    mkdir -p "$root/$dir" || return
    mount --rbind "/$dir" "$root/$dir" || return
    mount --make-rslave "$root/$dir" || return
  done
  mkdir -p "$root/run" || return
  mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$root/run"
}
usb_stage_no_mounts() {
  local stage=$1 mounts
  mounts=$(findmnt -rn -o TARGET) || return
  if grep -Fqx "$stage" <<< "$mounts" || grep -Fq "$stage/" <<< "$mounts"; then
    echo "ERROR: mounted content in staging root: $stage" >&2
    return 1
  fi
}
usb_drop_stage() {
  local stage=$1
  [[ -n $stage ]] || return 0
  [[ $stage == /var/tmp/ubuntu-usb-stage.* && -d $stage && ! -L $stage ]] || return 1
  usb_cleanup_mounts "$stage" || return
  usb_stage_no_mounts "$stage" || return
  rm -rf --one-file-system -- "$stage"
}
usb_stage_begin() {
  local available
  available=$(df -PB1 /var/tmp | awk 'NR==2 {print $4}') || return
  [[ $available =~ ^[0-9]+$ ]] && ((available >= 8 * 1024 * 1024 * 1024)) || {
    echo 'ERROR: need at least 8 GiB free builder storage in /var/tmp' >&2; return 1;
  }
  STAGE=$(mktemp -d /var/tmp/ubuntu-usb-stage.XXXXXXXX)
  ROOT=$STAGE
  USB_PROVISION_FROM_WRAPPER=1
  echo "USB_STAGE_BEGIN: $STAGE (target not touched)"
}
usb_stage_finish() {
  usb_cleanup_mounts "$STAGE" || return
  usb_stage_no_mounts "$STAGE" || return
  # Any unbound bootstrap archives reside in staging, not the persistent cache.
  find "$STAGE/var/cache/apt/archives" -maxdepth 1 -type f -name '*.deb' -delete || return
  USB_STAGE_VERIFIED=1
  ROOT=''
  echo 'USB_STAGE_VERIFIED: safe to proceed to target partitioning'
}
usb_copy_stage() {
  local src=$1 dest=$2 differences
  [[ ${USB_STAGE_VERIFIED:-0} == 1 ]] || return 1
  usb_stage_no_mounts "$src" || return
  mountpoint -q "$dest" || return
  rsync -aHAXx --numeric-ids --exclude=/lost+found "$src/" "$dest/" || return
  sync -f "$dest" || return
  differences=$(rsync -aHAXx --numeric-ids --checksum --dry-run --itemize-changes \
    --exclude=/lost+found "$src/" "$dest/") || return
  if [[ -n $differences ]]; then
    printf 'ERROR: target differs from staging root:\n%s\n' "$differences" >&2
    return 1
  fi
  echo 'USB_STAGE_COPY_OK: root transfer verified by checksum and metadata comparison'
}
