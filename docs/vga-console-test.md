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

## CI regression and network diagnosis

- 2026-11-22 [Actions #8](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44971209887):
  basic OS construction and BIOS boot succeeded. The guest reported networkd,
  Avahi and sshd *active*, but host-forwarded SSH stalled before the banner.
  This is a regression in the extended network test, **not** a passing SSH check.
- `tests/guest-network-watch.sh` now reports IPv4 addresses, routes,
  `networkctl` and listening sockets over the serial console. It fails if
  QEMU DHCP did not assign an address or if port 22 is not listening.
- `tests/qemu-boot.sh` waits for `USB_CI_NET_READY` before trying SSH.
  It does **not** disable QEMU's `restrict=on` isolation to hide forwarding
  problems.

## Code layout

- `tests/qemu-vga.py`: HMP monitor keyboard and PPM-to-PNG screenshot helper.
- `tests/qemu-boot.sh`: boot orchestration, VGA and SSH regression assertions.
- `tests/guest-onboard.sh`: pre-onboarding negative assertions and optional
  simulated password transition for noninteractive mode.
- `lib/provision.sh`: headless target and CI-only guest hook.
- `.github/workflows/usb-ci.yml`: explicit `[boot-ci-once]` or manual boot
  test trigger. The default push stays static-only.

## 2026-11-22 10:37 JST — run #12 failure analysis

- [Actions #12](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44971965177)
  successfully built Ubuntu 24.04 and reached the BIOS systemd marker.
- The uploaded serial log explicitly confirms that `getty@tty1.service` was
  started, in addition to serial getty, and reports
  `USB_CI_PRE_ONBOARD_LOCK_OK`.
- The previous image classifier inspected one pixel out of 97 and demanded
  **three distinct colors**. A legitimate two-color VGA text console would fail.
  Moreover, it deleted the PPM before saving a PNG, eliminating diagnostic
  evidence whenever this check failed.
- The new capture logic counts all pixels, accepts genuine two-color text with
  sufficient foreground area, and **always writes PNG before asserting**.
- The QEMU monitor now explicitly switches to `tty1` using
  `sendkey ctrl-alt-f1`. Blank images and framebuffer metrics will be
  retained in Actions artifacts on failure, with no passwords visible.
- Two cheap unit regressions check (1) a two-color console passes and
  (2) a black VGA image fails **but its PNG remains available**.
- This fixes the **test harness**, not an asserted hardware fault. Actual
  VGA login, PAM password change, SSH and UEFI tests remain unverified until
  the next opt-in integration run.

## 2026-11-22 — VGA is working; shrink test cost

Actions [#14](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44973725447)
recorded an actual 1280×800, two-color `tty1` login prompt screenshot
(`usb-ci-01 login:`). The guest reached `USB_CI_PRE_ONBOARD_LOCK_OK` but
failed `USB_CI_NET_FAILED:no-onboard-marker` after the interactive login
flow did not complete. Thus **VGA framebuffer rendering is proven**, but
**PAM and keyboard-input correctness are still unverified**.

The new lightweight `tests/vga-smoke.sh` runs SeaBIOS without Ubuntu to
regress QEMU VGA capture and HMP input at low bandwidth cost. For real Linux
console/PAM tests, use `config/packages-vga.txt` instead of a large full
development image. Normal development package installation should be tested
only after the console flow is fixed.

Archive-only Actions cache is available for repeated minimal/full builds;
report transfer cost as well as saved download volume. Cache contains no
root filesystem, credentials or private keys.

## Verified lightweight VGA smoke result — 2026-11-22

[GitHub Actions #44974698044](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44974698044) **passed**.
Ubuntu image building was skipped completely. QEMU SeaBIOS used its own
firmware, and the HMP monitor captured a visible two-color VGA framebuffer:

- Framebuffer: **720 × 400**, 2 colors, 7,050 minority pixels.
- Monitor keyboard command accepted; does **not** prove keyboard input into
  Ubuntu/PAM (that remains a separate minimal-image integration test).
- QEMU host packages downloaded: **16.2 MB** per apt output, installed disk
  footprint **82.9 MB**; apt-index transfer and runner traffic not included.
- This is dramatically smaller than the earlier roughly **1.14 GiB** full
  Ubuntu image run. The exact ratio varies with mirror/cache state.
- Screenshot/diagnostics: [Actions #44974698044 artifact](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44974698044).

Next expensive run should use the **CI-only minimal Ubuntu profile** with
archive caching. Do not rerun the full development-package profile solely
to troubleshoot VGA. BIOS and UEFI OS boot were already proven by #44969403610;
real tty1/PAM login and SSH remain incomplete in the extended scenario.
