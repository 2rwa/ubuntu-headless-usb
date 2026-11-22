#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
case_run() {
  local expected="$1"; shift
  local output
  if output=$(bash "$here/install.sh" "$@" 2>&1); then
    echo "Unsafe acceptance: $*" >&2; exit 1
  fi
  if ! grep -Fq "$expected" <<< "$output"; then
    echo "Wrong rejection reason for $*: $output" >&2; exit 1
  fi
}
[[ $EUID == 0 ]] || { echo 'Run safety tests using sudo' >&2; exit 1; }
base=(--device /dev/null --hostname usb01 --ssh-key /dev/null)
case_run "invalid user name" "${base[@]}" --login-user 'no.name'
case_run "invalid user name" "${base[@]}" --runner-user 'bad/name'
case_run "user names conflict" "${base[@]}" --login-user root
case_run "user names conflict" "${base[@]}" --login-user dev --runner-user dev
case_run "UIDs conflict" "${base[@]}" --login-uid 1001 --runner-uid 1001
case_run "UIDs conflict" "${base[@]}" --login-uid 999
case_run "use a /dev/disk/by-id/usb-" "${base[@]}" --login-user developer --runner-user buildbot
case_run "use a /dev/disk/by-id/usb-" "${base[@]}" --apply
case_run "unknown option" "${base[@]}" --totally-unknown
echo "PASS: invalid account names, UID conflicts, non-USB devices, and --apply safety"
