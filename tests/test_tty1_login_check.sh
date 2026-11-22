#!/usr/bin/env bash
# No privileged process or VM needed: process parentage and UID must match.
set -Eeuo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
checker="$here/tests/guest-tty1-login-check.sh"
positive=$' 314 1 0 login\n 411 314 1000 bash\n'
printf '%s' "$positive" | bash "$checker" 1000 bash
# Neither PAM alone nor any background bash should count as tty1 login.
for sample in   $'314 1 0 login\n'   $'314 1 0 login\n411 314 1001 bash\n'   $'314 1 0 login\n411 1 1000 bash\n'   $'314 1 0 getty\n411 314 1000 bash\n'   $'314 1 0 login\n411 314 1000 sshd\n'   $'314 1 0 login\n411 999 1000 bash\n'; do
  if printf '%s' "$sample" | bash "$checker" 1000 bash; then
    echo 'FAIL: non-login process incorrectly accepted' >&2
    exit 1
  fi
done
# Process ordering is not meaningful: shell can appear before parent login.
printf '411 314 1000 bash\n314 1 0 login\n' | bash "$checker" 1000 bash
echo 'PASS: tty1 login PID/PPID/UID/shell verification'
