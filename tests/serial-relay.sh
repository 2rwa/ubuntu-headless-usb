#!/usr/bin/env bash
# Live, raw CI guest serial telemetry. Do not copy VGA password input here.
set -Eeuo pipefail
[[ $# == 1 && -f $1 && ! -L $1 ]] || { echo 'Expected regular serial log file' >&2; exit 2; }
# Follow the already-open output file; -F/reopen is unnecessary for QEMU's
# file-backed ttyS0. GNU tail flushes appended lines to Actions stdout.
exec tail -n +1 -f -- "$1"
