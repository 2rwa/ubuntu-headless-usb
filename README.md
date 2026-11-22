# ubuntu-headless-usb

Standalone Ubuntu 24.04 LTS amd64 headless USB builder, originally developed in
[2rwa/chatgpt-workspace](https://github.com/2rwa/chatgpt-workspace/tree/main/tools/ubuntu-usb).
This repository is the experimental/test copy. The original remains unchanged.

## Safety and target environment

- Real USB creation uses `install.sh`; no disk changes without `--apply`, an actual
  `/dev/disk/by-id/usb-*` symlink, root privileges, and an exact interactive
  typed confirmation. Do not launch destructive USB creation from Actions.
- Minimum usable capacity is **24 GiB** (commercial 32 GB flash drive recommended).
- GPT with BIOS GRUB, removable UEFI GRUB and ext4 root, Secure Boot unsupported.
- No GUI; SSH, network and mDNS masked until the first local password change
  and explicit completion. Each stick needs a distinct hostname and runner registration.
- `--login-user` and `--runner-user` configure independent Linux accounts;
  defaults are `koyama` and `runner`. `--login-uid` and `--runner-uid`
  default to 1000/1001. Do not use matching names or numeric UIDs.
- `--skip-firmware` omits `linux-firmware`, which substantially reduces
  download size but may break actual hardware; default real USB installation
  **includes** firmware.

## Local usage (dry-run first)

```bash
sudo ./install.sh --device /dev/disk/by-id/usb-EXACT_ID \
  --hostname usb01 --ssh-key /home/USER/.ssh/id_ed25519.pub \
  --login-user developer --runner-user buildbot \
  --login-uid 1000 --runner-uid 1001
# Inspect output and only then repeat with --apply, confirming on a real TTY.
```

Initial password is generated only after installation, printed once, and forced
to change at first local login. After changing it, run
`sudo usb-firstboot-complete` locally. Then SSH public-key login,
`hostname.local` and networking become available. Runner registration is
interactive using `sudo usb-register-runner --url https://github.com/OWNER/REPO`.

## GitHub Actions test plan

Automatic on push/PR: `tests/static-check.sh`, negative safety cases and
ShellCheck (no debootstrap or actual disk writes).

Manual **Actions -> USB builder CI -> Run workflow**:
- `level=static`: same inexpensive checks
- `level=image`: make a fresh **25 GiB sparse file** exclusively under
  `RUNNER_TEMP`, attach a loop device, partition, build rootfs, check users,
  services, fstab, BIOS/UEFI boot loaders. This **does not** prove bootability.
- `level=boot`: also boot the actual built image in QEMU TCG (BIOS and UEFI),
  require a userspace serial marker emitted by systemd.
- The image is **never** uploaded as an artifact, and the CI path never points
  the real USB installer at a host disk.
- Firmware is excluded in CI by default, to cut package downloads. Toggle
  `include_firmware` to test the full package set.
- Optional `cache_debs` stores apt's package archives using Actions Cache.
  Restoring/saving the cache itself transfers bytes; it is useful for repeated
  full builds, but less useful for one-off tests.
- RX/TX byte counters and cache/image usage are logged. They are measured on
  the GitHub-hosted runner, not a precise count of Ubuntu mirror traffic.
- Ubuntu-hosted runner capacity, loop-device availability and QEMU/OVMF
  compatibility must be verified by executing the manual jobs; no such
  successful run is claimed until logs confirm it.

**Download budget (estimate, not yet measured):** syntax/safety tests
negligible after checkout; debootstrap minimal base roughly 100-300 MB;
full kernel+tooling about 1-2 GB including firmware, often substantially
lower when omitting firmware. Packages and mirrors change over time.
Repeated builds should use pinned Ubuntu release components and compare the
observed network bytes rather than relying on these estimates.

The QEMU boot job can also capture actual VGA framebuffer PNGs (without a
desktop environment), inject virtual keyboard events, and test forced first
login/password change via tty1. See [VGA test documentation](docs/vga-console-test.md).
This is an opt-in heavyweight test; push/PR runs only cheap checks.

The minimal-image QEMU boot job now verifies the initial network/SSH lock,
expected refusal of premature onboarding and runner registration, and the
**real VGA tty1 PAM forced-password-change dialogue** on BIOS. It then runs
the actual firstboot program, checks DHCP, root-owned onboard markers,
public-key SSH login, remote network/SSH/Avahi service state, and root/runner
SSH denial on both BIOS and UEFI (the UEFI run uses a preinitialized image).
A noninteractive CI-only onboarding check still covers the separate simulated
password-date transition.
CI-only guest test services are not installed by the physical USB builder.
QEMU user networking is restricted from external internet access. A private
test SSH key remains solely on the CI runner for boot tests and is deleted
before the job finishes; it is never uploaded as an artifact.

Actual physical USB boot behavior, flash endurance, real LAN multicast/mDNS,
hardware-console PAM interaction and Secure Boot still require separate
real-machine testing. The real PAM interaction *was* verified under QEMU.

## Bandwidth-conscious CI tiers (2026-11-22)

- **VGA smoke**: choose `level=vga` in Actions, or use a one-off commit
  message containing `[vga-ci-once]`. QEMU boots only its built-in SeaBIOS;
  no Ubuntu disk image, debootstrap or Linux development packages. It captures
  a framebuffer PNG and checks HMP keyboard command acceptance. This does
  **not** verify an Ubuntu login prompt or PAM.
- **Minimal Ubuntu**: use `level=boot` with `minimal_image=true` (default)
  or `[boot-ci-once]` on a push. The CI-only package list is
  [config/packages-vga.txt](config/packages-vga.txt); it includes kernel,
  GRUB, getty/PAM, networkd, sudo, SSH and Avahi, but omits Node, npm and
  compilers. It verifies the real Ubuntu login/firstboot stack.
- **Full Ubuntu**: choose `minimal_image=false` for end-to-end validation of
  the actual development-tool profile, configured in `config/packages.txt`.
  A one-off push with `[full-boot-ci-once]` also explicitly triggers this
  full profile (without firmware by default). The job checks developer-tool
  runtimes both in the generated root filesystem and after an actual SSH login.
  Expect a larger download and cache miss on first use; no physical disks
  are written in CI.
- **Archive cache**: heavy tests can restore/save only `.deb` files using
  Actions Cache, with separate keys for minimal/full profiles. It **never**
  caches the raw disk image, test SSH keys, or temporary passwords. First-time
  cache population itself consumes upload bandwidth; use VGA smoke while
  debugging only QEMU display or keyboard transport.

The real physical USB install script is unchanged: it always installs the full
package profile and retains the interactive disk-erase confirmation.
