#!/usr/bin/env bash
# CI-only unprivileged developer runtime test. Never installed on a real USB.
set -Eeuo pipefail
if [[ ! -f /etc/ubuntu-usb-ci-vga-mode || $EUID == 0 ]]; then
  echo 'CI-only unprivileged guest required' >&2
  exit 2
fi
umask 077
work=$(mktemp -d /tmp/usb-ci-dev-smoke.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/hello.c" <<'CEOF'
#include <stdio.h>
int main(void) { puts("USB_CI_C_BINARY_OK"); return 0; }
CEOF
cat > "$work/hello.cpp" <<'CPPEOF'
#include <cstdio>
int main() { std::puts("USB_CI_CPP_BINARY_OK"); return 0; }
CPPEOF
cat > "$work/CMakeLists.txt" <<'CMAKEEOF'
cmake_minimum_required(VERSION 3.16)
project(usb_ci_compiler_smoke LANGUAGES C CXX)
add_executable(ci_c hello.c)
add_executable(ci_cpp hello.cpp)
target_compile_options(ci_c PRIVATE -Wall -Wextra -Werror)
target_compile_options(ci_cpp PRIVATE -Wall -Wextra -Werror)
CMAKEEOF
echo USB_CI_DEV_COMPILERS_BEGIN
if ! cmake -S "$work" -B "$work/build" -G Ninja > "$work/configure.log" 2>&1; then
  tail -n 35 "$work/configure.log" >&2
  exit 1
fi
if ! cmake --build "$work/build" > "$work/build.log" 2>&1; then
  tail -n 35 "$work/build.log" >&2
  exit 1
fi
[[ $("$work/build/ci_c") == USB_CI_C_BINARY_OK ]] || { echo 'C binary failed' >&2; exit 1; }
[[ $("$work/build/ci_cpp") == USB_CI_CPP_BINARY_OK ]] || { echo 'C++ binary failed' >&2; exit 1; }
echo USB_CI_DEV_COMPILERS_OK
python3 -m venv --without-pip "$work/venv"
"$work/venv/bin/python3" -c 'import sys, ssl, sqlite3; assert sys.prefix != sys.base_prefix'
python3 -m pip --version >/dev/null
echo USB_CI_DEV_PYTHON_VENV_OK
node -e 'if (JSON.stringify({ok:true}) !== "{\"ok\":true}") process.exit(1)'
npm --version >/dev/null
echo USB_CI_DEV_NODE_OK
printf '{"ok":true}\n' | jq -e '.ok == true' >/dev/null
printf 'rsync-ok\n' > "$work/original"
rsync -a "$work/original" "$work/copied"
cmp "$work/original" "$work/copied"
git --version >/dev/null
echo USB_CI_DEV_UTILITIES_OK
echo USB_CI_DEV_SMOKE_OK
