#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
source "$here/lib/initial-auth.sh"
unset PASS
# Feed a too-short password, mismatched confirmation, then matching pair.
usb_prompt_password < <(printf '%s\n' 'short' '12345678' '87654321' 'abcdefgh' 'abcdefgh') 2>/dev/null
[[ $PASS == abcdefgh ]]
if usb_prompt_password < /dev/null 2>/dev/null; then exit 1; fi
usb_password_valid '12345678'
! usb_password_valid '1234567'
! usb_password_valid 'abc defgh'
! usb_password_valid '日本語12345678'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '# LOGIN_TIMEOUT 60\nLOGIN_TIMEOUT 60\nLOGIN_TIMEOUT 90\nOTHER 1\n' > "$work/login.defs"
usb_set_login_timeout "$work/login.defs"
usb_set_login_timeout "$work/login.defs"
[[ $(grep -c '^LOGIN_TIMEOUT' "$work/login.defs") == 1 ]]
grep -Fxq 'LOGIN_TIMEOUT 180' "$work/login.defs"
grep -Fxq 'OTHER 1' "$work/login.defs"
echo 'PASS: initial password validation, confirmation, EOF and idempotent console timeout'
