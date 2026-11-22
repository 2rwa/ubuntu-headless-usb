#!/usr/bin/env bash
# Cumulative network RX/TX bytes excluding loopback, as observed by this runner.
set -Eeuo pipefail
awk 'NR>2 {gsub(/:/, "", $1); if ($1!="lo") {rx+=$2; tx+=$10}} END {printf "%.0f %.0f\n", rx, tx}' /proc/net/dev
