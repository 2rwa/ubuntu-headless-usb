#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
for script in install.sh lib/provision.sh firstboot-complete.sh register-runner.sh tests/static-check.sh; do
  bash -n "$here/$script"
done
bash "$here/install.sh" --help | grep -q -- '--apply'
bash "$here/register-runner.sh" --help | grep -q -- '--url'
# Prevent a future accidental Actions job from performing destructive USB operations.
grep -q '\[\[ -t 0 && -t 1 \]\]' "$here/install.sh"
grep -q 'ERASE ' "$here/install.sh"
grep -q 'read -r ack </dev/tty' "$here/install.sh"
grep -Fq 'chage -d 0 "$LOGIN_USER"' "$here/lib/provision.sh"
grep -q 'PasswordAuthentication no' "$here/lib/provision.sh"
grep -q 'sha256sum -c -' "$here/register-runner.sh"
# A harmless fake path must fail even with --apply.
if bash "$here/install.sh" --hostname usb01 --device /dev/null --ssh-key /dev/null --apply >/dev/null 2>&1; then
  echo 'ERROR: invalid device was accepted' >&2; exit 1
fi
printf 'PASS: static and safety checks (no actual disk I/O)\n'