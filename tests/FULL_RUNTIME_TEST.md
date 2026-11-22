# Full developer profile runtime acceptance (CI-only)

After static safety checks, use a one-shot `[full-boot-ci-once]` commit.
This builds a fresh 25 GiB sparse Ubuntu 24.04 image from
`config/packages.txt`, without `linux-firmware` in CI and without
writing or erasing any physical USB media.

Both SeaBIOS and OVMF must finish within 180 seconds each. The BIOS
path must actually change the login password via tty1/PAM. Both paths
must obtain DHCP, pass unprivileged public-key SSH, check SSH/networkd/
Avahi service state, and deny root and runner-account SSH access.

The CI-only `usb-ci-dev-smoke` script must, *from an SSH session as the
login user*, compile C/C++ with CMake and Ninja and execute both binaries.
It must also create and execute Python from a virtual environment, run
Node.js/npm, parse JSON with jq, and copy/compare a file using rsync.
Every stage must emit a distinct marker. No pass claim based on a
package list or executable --version alone. The helper is never
installed on a physical USB build.

No raw image, private key, or password is uploaded to artifacts.
An actual USB drive, hardware firmware, and real LAN/mDNS still require
separate real-machine validation.
