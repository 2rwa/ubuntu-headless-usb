# CI test execution policy

## Automatic
- Push/PR: syntax, ShellCheck (errors), invalid account/UID/USB target tests. No apt mirror traffic.

## Opt-in heavyweight test
- CI creates a new sparse 25 GiB raw image and attaches it only via a loop device.
- Build uses the same lib/provision.sh as the actual USB installer.
- The 2026-11-22 one-off image test is requested without linux-firmware and without Actions cache.
- Measure total network receive/transmit bytes; report temporary disk and apt archive usage.
- Do not upload raw images, downloaded OS packages, private SSH keys, or generated passwords.
- The default manual workflow supports optional cache and optional firmware inclusion.
- Full boot checks require QEMU BIOS and UEFI to observe the userspace marker.
- Physical USB boot and Wi-Fi/hardware compatibility require separate host testing.

## Failure handling
- Classify failures as Actions runner environment, downloader/package availability, partition/GRUB, OS configuration, boot, or verification.
- Resolve root cause and preserve the regression test.
- Never turn off physical USB destructive-operation protections to make CI work.

## 2026-11-22 firstboot/SSH integration extension

- The boot job tests a network-locked image, expected refusal before password
  expiration is cleared, and a simulated local password-change date transition.
- It runs `usb-firstboot-complete` in the QEMU guest, then verifies networkd,
  resolved, SSH, Avahi, an SSH host key, and idempotent completion.
- Host-to-QEMU connections are limited to 127.0.0.1:22289 via QEMU user-mode
  networking with `restrict=on`. Test public-key SSH login, root/runner denial.
- The test key is generated on the CI worker and removed before artifacts upload.
  The disk image and password are never uploaded.
- The interactive PAM prompt and physical-LAN mDNS remain manual tests.
- Trigger this one-off integration run on push with `[boot-ci-once]`, preserving
  default static-only CI behavior for subsequent commits.

## 2026-11-22 VGA/real PAM test run

- Previous #8 failed SSH banner exchange, even though service startup markers
  succeeded; diagnosed from the uploaded QEMU serial log.
- Now verify that the guest has a QEMU DHCP IPv4 address and that sshd listens
  on port 22; capture networkctl/route/ss details to ttyS0 when booting.
- Headless QEMU's emulated standard VGA framebuffer is saved as reviewed PNG
  evidence, checked for non-blank output and keyboard injection.
- On BIOS first boot: actually log into tty1, change the generated password via
  PAM, invoke usb-firstboot-complete, then check SSH using a local forwarded port.
- On UEFI second boot: check persistence, SSH and framebuffer.
- One fresh full build, with no firmware and no upload of image/cache/secrets.
- Result must be reported separately from the initial static checks. On failure,
  inspect serial and screenshot evidence and update this documentation.

## VGA capture false-negative regression

Run #12 (2026-11-22) built the system and started getty@tty1 but aborted
because the capture code demanded three colors. A two-color console is normal.
The test now uses all-pixel statistics, preserves blank-screen PNGs, and
activates tty1. Recheck with cheap unit tests before another full-image run.

## 2026-11-22 VGA test recheck #13

- Opt-in trigger for a single new 25 GiB sparse-image build: `[boot-ci-once]`.
- Regression fixed: count all VGA pixels instead of requiring three sampled
  colors; a two-color text console is normal and must be accepted.
- Retain PNG on blank-screen failure and include diagnostic pixel counts.
- Force Linux tty1 to the VGA output before capturing the login prompt.
- Run the same BIOS→PAM password-change→network/SSH→UEFI checks, reporting
  partial success separately from full completion.
- No firmware, no package cache or raw-image artifact, no physical USB target.

## 2026-11-22 — Split smoke/minimal/full profiles

- Cheap `level=vga`: QEMU built-in BIOS only, PNG + HMP keyboard command,
  no Ubuntu packages downloaded. One-off trigger: `[vga-ci-once]`.
- Minimal Ubuntu `level=boot`, `minimal_image=true`: kernel, getty/PAM,
  SSH/networkd/Avahi. No Node/npm/build-essential or full dev dependencies.
- Full Ubuntu `minimal_image=false`: validate the actual USB package set.
- Heavy tests enable .deb-only Actions cache when opted in; separate cache
  keys distinguish package profiles and firmware options. Never cache image,
  password or test keys.
- Previous Actions #14 successfully rendered `tty1 login:` before the
  failed network-onboarding watchdog. Treat screen rendering as passing,
  keyboard/PAM interaction as unresolved.
- A temporary syntax issue from editing the minimal profile was diagnosed by
  the cheap safety checks and fixed before rerunning any full image build.

## 2026-11-22 verified VGA smoke baseline

- [Actions #44974698044](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44974698044): **success**.
- `safety`: success. `vga`: success. `image`: skipped by design.
- SeaBIOS framebuffer: 720x400, exactly 2 colors, 7050 nonbackground pixels.
- QEMU apt packages: 16.2 MB fetched, 82.9 MB installed; host traffic is
  not fully measured in this tier.
- Ubuntu tty1/PAM/SSH was not exercised by this smoke; next integration test
  should select the new CI minimal profile, with .deb archive cache enabled.
