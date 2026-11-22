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

The boot job also verifies the initial network/SSH lock, expected refusal of
premature onboarding and runner registration, a **simulated** successful local
password-change date update, firstboot service activation, public-key SSH
login, root/runner SSH denial, and idempotent repeated completion. The
interactive PAM password-change dialogue is **not** tested by this simulation.
CI-only guest test services are not installed by the physical USB builder.
QEMU user networking is restricted from external internet access. A private
test SSH key remains solely on the CI runner for boot tests and is deleted
before the job finishes; it is never uploaded as an artifact.

Actual USB boot behavior, physical USB endurance, real LAN multicast/mDNS,
interactive PAM password change and Secure Boot require separate real-machine testing.
