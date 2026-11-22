#!/usr/bin/env bash
# CI-only: verify an actual login(1) -> login-user shell process on tty1.
# Input: numeric process listing from "ps -t tty1 -o pid=,ppid=,uid=,comm=".
# The shell must be an immediate child of a root-owned login process.
set -Eeuo pipefail
[[ $# == 2 && $1 =~ ^[0-9]+$ && $2 =~ ^[a-zA-Z0-9_.+-]+$ ]] || {
  echo 'Usage: tty1-login-check UID SHELL_NAME < ps-listing' >&2
  exit 2
}
awk -v want_uid="$1" -v shell="$2" '
  NF >= 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
    if ($3 == 0 && $4 == "login") logins[$1] = 1
    if ($3 == want_uid && $4 == shell) children[$2] = 1
  }
  END {
    for (parent in children)
      if (parent in logins) exit 0
    exit 1
  }
'
