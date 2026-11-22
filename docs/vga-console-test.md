# QEMU VGA console and first-login integration testing

## Motivation and limitations

Ubuntu 24.04 headless systems still expose Linux virtual terminals through an
emulated VGA adapter. A graphical desktop is **not** required. The existing
BIOS/UEFI tests proved systemd boot via ttyS0; this extension independently
checks VGA framebuffer output, keyboard input, and the real PAM password-expiry
login path on tty1.

The guest test hooks and login marker are installed only when the CI image
builder sets `USB_CI_VGA_LOGIN=1`. Physical USB builds continue using normal
getty@tty1 without test-only services.

## Test flow

1. Build the usual 25 GiB sparse image once in GitHub Actions. Production
   `install.sh` is never invoked on a block device in CI.
2. On QEMU BIOS boot, wait for `USB_CI_PRE_ONBOARD_LOCK_OK`. The guest checks
   that network and SSH were masked and premature onboarding/registration fail.
   It intentionally does not simulate a password change.
3. QEMU uses `-vga std -display none` and a private Unix HMP monitor socket.
   Python standard-library monitor code requests a PPM screenshot, verifies
   the framebuffer is not blank, converts it to PNG, and removes the PPM.
4. The monitor sends actual keyboard events to tty1: username, generated
   one-time password, required PAM password change, then `sudo
   usb-firstboot-complete`. A CI-only `/etc/profile.d` hook writes a serial
   marker on successful tty1 login.
5. Test that networkd, Avahi and SSH become active. Use host-to-QEMU loopback
   port forwarding only; external QEMU network traffic is restricted. Check
   public-key SSH works while root and runner accounts are refused.
6. Reboot the same image using UEFI and verify SSH, systemd and VGA without
   redownloading OS packages.

## Secrets and diagnostic evidence

- Initial and replacement one-time passwords are created on the GitHub-hosted
  worker, stored as mode-0600 files under `RUNNER_TEMP`, and removed even on
  failure. They are never printed, uploaded, cached or committed.
- No screenshots are captured while passwords are being typed.
- Only completed nonsecret screenshots (`qemu-*-vga-*.png`) and serial logs
  are uploaded. The 25 GiB raw image itself is never uploaded.
- The monitor emits no keyboard content to logs for secret-file inputs.
- Framebuffer color diversity establishes visible output, **not** OCR text
  recognition. Successful tty1 login is separately confirmed using a guest
  login-shell serial marker.
- The CI-specific testing setup does not prove physical keyboard/VGA hardware
  compatibility, actual USB durability, Wi-Fi, real-LAN mDNS, or Secure Boot.
- Monitor socket and QEMU user-network port binding are local to the job.
- Each fresh full run costs roughly 1.14 GiB inbound without firmware or APT
  cache, based on the earlier 2026-11-22 successful run. Avoid repeated heavy
  tests when a static check can identify the failure.

## Code layout

- `tests/qemu-vga.py`: HMP monitor keyboard and PPM-to-PNG screenshot helper.
- `tests/qemu-boot.sh`: boot orchestration, VGA and SSH regression assertions.
- `tests/guest-onboard.sh`: pre-onboarding negative assertions and optional
  simulated password transition for noninteractive mode.
- `lib/provision.sh`: headless target and CI-only guest hook.
- `.github/workflows/usb-ci.yml`: explicit `[boot-ci-once]` or manual boot
  test trigger. The default push stays static-only.
