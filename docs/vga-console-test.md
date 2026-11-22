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


## Run #44976878592 — minimal Ubuntu / PAM / cache postmortem (2026-11-22)

[Run log](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44976878592)

- Static/safety and minimal-image build/inspection PASSED. Sparse 25-GiB
  image occupied about 2.0 GiB on the hosted runner.
- BIOS userspace and VGA screenshot PASSED: 1280x800, two colors. The saved
  username-only screenshot visibly shows "usb-ci-01 login: developer" and
  "Password:", confirming real tty1 username keyboard delivery.
- The root watcher observed "USB_CI_NET_PAM_PASSWORD_DATE_UPDATED": the shadow
  password-change day became nonzero. This supports a genuine forced-password
  update, but does not establish a working login shell.
- The host timed out waiting for "USB_CI_VGA_LOGIN_OK", before sending
  "sudo usb-firstboot-complete". Network/SSH and UEFI were not tested.
- Likely CI harness defect: the /etc/profile.d/usb-ci-vga-login.sh hook
  attempts to write to /dev/ttyS0 as the unprivileged developer. The device
  normally belongs to root:dialout (mode 0660); the account is in sudo but
  not dialout. Confirm permissions with stat during next run. Do not relax
  production device permissions. Instead, have the login shell create a
  nonsecret marker readable by a root-owned CI watcher, which emits serial.
- Confirmed diagnostic mismatch: the watcher writes prefix "USB_CI_NET_"
  but the host greps "USB_CI_PAM_PASSWORD_DATE_UPDATED". Its resulting
  "No PAM password-change evidence" message is misleading.
- Cache RESTORE missed: "Cache not found for input keys:
  noble-amd64-debs-v2-1-...-nofw". Cache SAVE failed: tar could not
  read root-owned cache "partial" and "lock" entries (Permission denied).
  Around 900 MiB of .deb data was present, but it was NOT saved.
- Measured host RX: 917,771 to 2,083,904,689 bytes = 1,986.5 MiB delta.
  This is all runner network traffic, not only Ubuntu mirror downloads.
- Next steps: fix guest-to-serial marker via privileged CI watcher, align
  marker names, repair archive-cache ownership/exclusions after unmount,
  verify a real cache hit, then one minimal-image test. Separate PAM, login
  shell, firstboot, DHCP/SSH and UEFI outcomes; avoid another full install.


## 2026-11-22 — CI login marker & cache permission fix

- In CI VGA mode the real login shell writes a private, nonsecret marker
  to the login user's home only after entering tty1 with the expected UID.
  The root-owned guest network watcher validates the marker owner, removes
  it, and emits USB_CI_VGA_LOGIN_OK to ttyS0. No dialout group membership
  or insecure ttyS0 permission changes are needed.
- Host diagnostics now match the watcher output exactly:
  USB_CI_NET_PAM_PASSWORD_DATE_UPDATED. A shadow date update alone does not
  prove that an interactive login shell opened.
- The watchdog service timeout has been aligned with its longer CI VGA
  polling budget.
- The image job now normalizes only the protected RUNNER_TEMP archive-cache
  directory after debootstrap unmounts it: removes APT lock/partial files,
  changes cache ownership to the Actions runner, and permits the archive
  save step to read files. Neither the raw image nor secret credentials are
  included in cache.
- Preserve distinct positive assertions for screen rendering, typed username,
  PAM shadow date, tty1 login shell, onboarding, DHCP/SSH and UEFI.
- These fixes address observed defects from Actions #44976878592; full boot
  success and a subsequent cache HIT are pending integration verification.


## 2026-11-22: BIOS-test timeout accounting

The QEMU host runner previously used `wait_marker MARKER 45` with a
`for (...<45)` loop containing `sleep 5`. The intended 45-second limit
therefore actually took up to **225 seconds** (plus I/O overhead). This made
an unsuccessful tty1/PAM test look like a slow BIOS boot. Updated the checker
to use Bash `SECONDS` for real elapsed wall time, one-second polling, and
explicit per-marker timing in Actions logs. The already-started workflow
continues to run the version from its own checkout; the fix affects only
subsequent runs. Avoid a new expensive image build until the running test's
actual result and cache-save outcome are available.


## Live serial, explicit stage deadlines and BIOS/UEFI 180s caps (2026-11-22)

- `tests/qemu-boot.sh` now starts `tests/serial-relay.sh` alongside
  QEMU to forward the guest's **actual ttyS0 boot output directly to Actions
  stdout while QEMU remains alive**. The original byte log is still saved
  to `qemu-bios.log` / `qemu-uefi.log` and uploaded as an artifact.
- Log stream boundaries are `LIVE_SERIAL_BEGIN` and `LIVE_SERIAL_END`;
  individual host marker waits also record time budgets and observed durations.
- The relay subprocess is terminated when QEMU exits or fails. It uses
  `tail -n +1 -f` on the existing regular serial log. A cheap behavior test
  `tests/test_serial_relay.sh` verifies marker output **before** source
  process termination. This does not require Ubuntu debootstrap or QEMU.
- Each BIOS/UEFI boot *integration* step has a **180-second total hard limit**
  via GNU `timeout`, independent of each stage's smaller deadline. A
  timeout fails the step, preserving available logs and diagnostics. The cap
  applies to the boot+PAM+SSH integration test, not just firmware POST.
- The root-owned guest watcher emits a one-time
  `USB_CI_NET_LOGIN_MARKER_PENDING` after 10s with a changed PAM password
  date but no login-shell marker, followed by a minimal tty1 process listing.
  This may distinguish an active PAM/login process from an interactive shell;
  it does not expose passwords. Password typing occurs through VGA/HMP, not
  through ttyS0. Never stream/retain a screenshot of password entry.
- These updates affect only the CI test harness; physical USB login and
  production password handling remain unchanged.

## 2026-11-22 — parallel serial and VGA observation, no framebuffer leak

QEMU now exposes two independent **local-only** HMP Unix sockets. The input
monitor continues sending VT1 keyboard events and doing explicit safe PNG
captures. The second monitor is owned by `tests/qemu-vga-watch.py`, which
polls the VGA framebuffer independently every 2 seconds while serial is
streamed by `tests/serial-relay.sh`. Both report real-time timestamps to the
same Actions job and save separate text-only diagnostics.

The observer records framebuffer size, sparse foreground pixel count, changed
scanline count and first/last changed row. It deliberately does **not** save
PNG images, OCR text, or a full PPM artifact during password entry. QEMU's
transient screendump lives in a 0700 temporary directory and is deleted after
measurement. The two monitors avoid races between `sendkey` and `screendump`
over a single HMP socket. Background observers are terminated with QEMU.

The standalone no-Ubuntu `tests/vga-smoke.sh` exercises concurrent VGA
observation and keyboard commands against the two HMP sockets, and the cheap
Python test verifies framebuffer row-change detection. The real Ubuntu boot
integration test still has a 180-second overall timeout.

Most recent minimal Ubuntu integration run
[Actions #44980879541](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44980879541)
restored its .deb cache successfully and booted to the Linux login prompt in
37 seconds. PAM's shadow-date transition was detected, but a tty1 listing
10 seconds later still showed only the root-owned `login` process, without
an interactive user shell. Login/PAM remains **unresolved**. Parallel VGA
sampling will expose whether framebuffer content continues changing during
the login sequence without publishing the password prompts.
