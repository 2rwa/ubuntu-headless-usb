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

## 2026-11-22 minimal image and PAM diagnostic run

The first opt-in minimal boot run tests CI-only `config/packages-vga.txt` and
archives downloaded .deb files separately from the disk and secrets.
It captures a *username-only* VGA screen before sending password input;
no image is captured while a password could be visible. A separate guest
watcher emits `USB_CI_PAM_PASSWORD_DATE_UPDATED` after PAM has modified
the shadow password-change date. This distinguishes password-transition
failure from a successful PAM change with a failed tty1 login-shell marker.
No conclusions are inferred from a QEMU process merely exiting cleanly.


## 2026-11-22 run #44976878592 — result and root cause candidates

- PASSED: static safety; CI minimal image construction; BIOS boot; visible
  login prompt; QEMU keyboard input of username.
- Observed shadow password-date update, but no login-shell serial marker.
  The unprivileged hook's /dev/ttyS0 permissions are the leading cause,
  subject to confirmation with device stat and login-session evidence.
- The host also searched the wrong serial marker (missing NET_ prefix).
- NOT TESTED: firstboot completion, SSH networking, UEFI in this run.
- Cache restore MISS and cache save FAILURE: root-owned partial/lock files
  caused tar permission errors; approx 900 MiB of archives not retained.
- RX delta: 1,986.5 MiB including runner-wide network traffic.
- Fix cheap checks and cache permission before any next image build.


## 2026-11-22 fix following #44976878592

1. CI-only shell marker now goes to a private file in the user's home,
   not to protected root:dialout ttyS0. A root-owned guest watcher checks the
   marker UID before relaying USB_CI_VGA_LOGIN_OK over the serial console.
2. Host looks for USB_CI_NET_PAM_PASSWORD_DATE_UPDATED exactly; separate
   password-expiry and login-shell assertions are retained.
3. Workflow strips stale APT lock/partial files and chowns only the guarded
   cache directory to the Actions runner before actions/cache/save.
4. Low-cost tests check the marker boundary and cache permission step.
   Run cheap safety checks first, then one opt-in minimal-image integration.
   Full success and the next cache hit still require real validation.


## 2026-11-22 one-off minimal integration rerun

- CI shell-to-serial marker and archive permission fix committed in 7f79075.
- Static/safety checks passed in Actions #44979829510.
- Explicitly rerun a minimal-image BIOS→tty1/PAM→onboarding/SSH→UEFI boot test.
- This run should **populate** the previously missing archive cache. Record the
  result of actions/cache/save (which failed on #44976878592) and distinguish
  a completed cache write from a *future* cache restore hit.
- If the shell marker is absent, check the guest serial diagnostics and
  separately identify whether the shadow password date updated.
- Do not upload the raw image, passwords, or private SSH keys; preserve
  QEMU text-mode screenshots only before password entry and after login.


## Live ttyS0 telemetry and bounded waits

- BIOS and UEFI integrated boot stages now stream the pre-existing QEMU
  `-serial file:` log into the running Actions step, retain the file as
  artifact, and enforce **180s overall per-boot** hard failure.
- Each marker wait counts seconds, not polling iterations, and reports
  stage duration. When PAM updates shadow but login marker remains absent,
  guest root watcher emits a pending marker and safe tty1 process status.
- Run `tests/test_serial_relay.sh` in cheap checks; it verifies log
  forwarding before the source has finished. Avoid image rebuilds for
  serial-stream test changes alone.
