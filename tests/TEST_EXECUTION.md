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


## 2026-11-22 one-off CI live-serial integration check

- The lightweight serial relay test passed on Actions #44980836549.
- Perform a single minimal Ubuntu boot integration run with cached .deb
  packages. Verify that ttyS0 logs stream into the Actions BIOS step before
  QEMU exits; preserve the complete file as a separate artifact.
- BIOS and UEFI total runtime limits: 180s each, and individual marker limits
  remain bounded in seconds.
- Check for actual APT cache restore HIT. In case of login failure inspect
  PAM_PASSWORD_DATE_UPDATED, LOGIN_MARKER_PENDING and tty1 process listing.
- Do not rerun the full development-tool package profile for this test.

## 2026-11-22 concurrent VGA + serial diagnostic plan

- Build-free regression: independent HMP monitor sockets used concurrently by
  a VGA watcher and the keyboard/screenshot command; no full Ubuntu rebuild.
- Serial: live raw ttyS0 output and preserved complete log as before.
- VGA: every 2 seconds report framebuffer geometry and row-change metrics to
  Actions stdout plus text log; transient PPM stored in private 0700 directory
  and removed immediately. Do not upload frames collected during secrets.
- Keep full 180-second BIOS/UEFI budget and per-marker wait timeouts.
- The prior minimal run #44980879541 was **not** a successful PAM login; even
  though the shadow date changed, guest tty1 showed root-owned `login` but
  not a user shell. APT restore did produce a cache hit.


## 2026-11-22: real concurrent QEMU monitor smoke verified

- [Actions #44983218828](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44983218828): safety + VGA smoke PASSED without Ubuntu image build.
- Observer produced three consecutive 720x400 frames while independent HMP
  keyboard/capture calls ran. Changed scanlines included rows 221-222, proving
  frames were sampled while the guest video state changed; observer and
  input sockets did not contend. No secret frames were uploaded.
- Next single minimal-boot test uses the existing cache to inspect the root
  login process that previously remained after a PAM password-date change.
- Correlate VGA_OBSERVER FRAME timestamps with USB_CI_* serial markers and
  respect the 180-second maximum for BIOS/UEFI integrations. No full package
  image is needed to test the concurrency feature.


## 2026-11-22 — VGA image capture and serial correlation

- Retain a bounded sequence of boot-only VGA PNG frames with elapsed-time
  names and per-frame log markers, alongside the unmodified ttyS0 boot log.
- The monitor is a separate HMP connection from keyboard input.
- A stop-file/ack-file synchronization barrier is required **before any
  simulated keyboard or password entry**; continue VGA change metrics but
  never save frames from the PAM/password phase.
- Run the no-Ubuntu QEMU smoke before any minimal-image boot; it checks PNG
  presence, simultaneous keyboard/observer operation, and no new PNG after
  stopping. Upload saved boot frames as a diagnostic artifact on failure.


## 2026-11-22 boot-frame capture smoke verified and integration dispatch

- [Actions #44983752506](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44983752506):
  no-Ubuntu QEMU test PASS. A timestamped boot PNG was captured, the
  screenshot disable/ACK barrier completed, and nine VGA samples continued
  while separate keyboard/screenshot HMP commands ran. PNG count did not
  increase after ACK. Syntax/safety checks also PASS.
- The next opt-in CI run uses the cached minimal Ubuntu configuration and
  exercises real BIOS boot with a bounded, time-aligned VGA boot-image series
  plus a separate live ttyS0 stream, and retains the images on failure.
- Verify the uploaded PNGs depict readable guest boot activity, not simply a
  successful screenshot API call. Password-entry frames must remain unretained.


## 2026-11-22 — fix false negative after genuine tty1 login

Evidence from minimal BIOS run #44983890046: PAM's last-change day updated
and the guest reported root-owned `login` on tty1 with direct child
`developer` bash. The /etc/profile.d marker did not appear. Therefore the
previous BIOS failure was the **CI success signal**, not a missing login
shell. New checker verifies root login PID/child shell UID and command
and the existing shadow-date transition, then emits the same serial success
marker. Test exact process-parent/UID cases without building Ubuntu; only
after safety success launch one cached minimal boot test.


## 2026-11-22: one-off cached minimal integration after tty1 checker

- Static/safety and PID/PPID/UID login verifier tests passed in
  [Actions #44987020713](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44987020713).
- Invoke only one [boot-ci-once] minimal build with .deb cache and both
  BIOS/UEFI attempts. Expect the root watcher to observe a tty1 user bash
  immediately descended from root-owned login(1) **after** the PAM shadow
  date transition, then send USB_CI_VGA_LOGIN_OK over serial.
- After this marker, the host sends sudo usb-firstboot-complete; check the
  real network-enabled flag, DHCP IPv4, SSH key authentication, root/runner
  SSH denial and UEFI boot. Preserve precise failure stage if blocked.
- Retain serial logs and only precredential VGA PNGs, never passwords.
- Each BIOS or UEFI stage has a 180-second overall limit; the heavy CI job
  retains the 120-minute workflow guard for image building.



## 2026-11-22 — Serial system journal and independent UEFI smoke

Observed: [BIOS #44987057196](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/44987057196)
passed real tty1 shell + PAM update; failed waiting for USB_CI_NET_READY.
Production journald uses Storage=volatile, so the guest's runtime journal is
not recoverable after the VM exits. UART logging alone is not a full journal.

Changes:
1. CI-only wrapper calls the unchanged real usb-firstboot-complete and
   reports BEGIN, OK or FAILED via ttyS0, only after valid PAM transition.
   Ordinary physical USB initialization is untouched.
2. Root CI watcher exports limited `journalctl -b` records for sudo,
   ssh/networkd/resolved/Avahi/getty units, plus service and tty1 state,
   after a 12s pending period. The wrapper also exports it on error.
3. Host waits separately for command BEGIN/OK before network READY;
   firstboot errors stop the test with journal evidence in the artifact.
4. UEFI boot/VGA is attempted after a BIOS integration failure when the
   disk image exists. Only if BIOS passed is full UEFI network/SSH checked.
5. Physical USB journal remains volatile (32 MiB). No persistent guest
   journal is requested and no passwords/raw images are uploaded.

Validate new static checks first; then one cached minimal Ubuntu boot test.
A full green CI result requires BIOS onboarding+network+SSH and UEFI.


## 2026-11-22 opt-in live journal/UEFI fallback integration

- Previous revision commit 190fa951: CI-only firstboot wrapper, bounded
  sudo/systemd journal excerpts over ttyS0, and independent UEFI boot-only
  fallback on BIOS failure. Static/safety: Actions #45001004461 PASS.
- Rebuild one minimal Ubuntu image only, with existing .deb archive cache.
- Expect to distinguish sudo command not reached (no FIRSTBOOT_BEGIN) from
  guest firstboot command start, failure, success, and network readiness.
- On a BIOS integration failure, check that the UEFI boot+VGA-only step
  actually executes; the bare UEFI pass is not an onboarding/SSH pass.
- Assert that logs contain real journal records when the 12-second pending
  diagnostic is reached; do not publish credentials or password frames.


## 2026-11-22 — #45001068699: onboard success, network watcher race

- Minimal Ubuntu build and .deb cache hit: passed.
- Legacy BIOS systemd boot: 27s; PAM password change and tty1 user login:
  passed. sudo firstboot actually executed as root (journal verified).
- FIRSTBOOT_BEGIN and FIRSTBOOT_OK: both observed (24s). At the first
  pending snapshot, resolved was activating, while networkd, ssh, and Avahi
  were still inactive; this was before the firstboot script completed.
- Host waited 60s for USB_CI_NET_READY. Guest also waited up to 60s for
  10.0.2.* DHCP before reporting details. Both timers expired together;
  host terminated QEMU before the guest could report whether DHCP failed.
  No claim of a networkd failure is justified from this evidence alone.
- UEFI boot + readable VGA: passed in fallback mode (26s to systemd);
  full UEFI network/SSH not yet tested.
- Fix: emit guest ONBOARD_MARKER_SEEN; progressive network status at 8/25s;
  45s guest DHCP deadline with journal/status before explicit FAILED;
  75s host wait, still below 180s BIOS integration ceiling.
- Next run must assert whether 10.0.2.* DHCP is obtained or why it fails,
  and whether public-key SSH becomes available. Avoid relaxing the actual
  DHCP/network/SSH acceptance criteria merely to turn CI green.


## 2026-11-22 — one-off network diagnosis after wait race fix

- New fast/safety test successful: [#45011682762](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/45011682762).
- Run one minimal Ubuntu image + cached APT packages through BIOS,
  guest firstboot, DHCP/SSH, then UEFI (boot fallback even after BIOS failure).
- Expect guest ONBOARD_MARKER_SEEN and either NET_READY or explicit
  NET_FAILED with early IP/routes/networkctl/journal evidence within the
  host's 75s window. This test must not bypass DHCP or SSH assertions.
- Distinguish failure of DHCP itself from a guest/host synchronization race
  and from SSH not listening. Full success is not assumed in advance.



## 2026-11-22 — Suspected root cause of DHCP unmanaged

- Actions #45011740252 confirmed enp0s2 was DOWN/unmanaged (no address)
  after firstboot succeeded and all networking services became active.
- Network config match `Name=en* eth*` covers the QEMU NIC.
- CI builder inherits `umask 077` into provisioning, making its `cat >`
  systemd `.network` file mode 0600, which is unreadable by the non-root
  systemd-networkd daemon. This can explain the unmanaged result.
- Explicitly chmod that one nonsecret `.network` file 0644. Do not relax
  private credential permissions.
- Inspect the *built* image for exact .network mode and match/DHCP content;
  guest diagnostics print the effective mode and full networkctl status.
- Next run must verify a real 10.0.2.* DHCP lease, local forwarded SSH,
  and full UEFI boot/SSH rather than merely a green static check.


## 2026-11-22 — one-off minimal boot validation after .network permission fix

- Static/safety workflow [#45013222992](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/45013222992) passed.
- Previous CI binary image's Ethernet file was created under a 0077 umask;
  provisioning now sets its readable mode to 0644. The root inspector now
  fails if the generated file isn't 0644, or lacks Name=en* eth*/DHCP=yes.
- Run exactly one cached minimal Ubuntu BIOS→PAM→firstboot→DHCP→SSH and
  UEFI integration. Read serial/networkctl diagnostics and cache hit status.
- Confirm the real guest reports enp0s2 as managed, with a 10.0.2.* lease
  and successful public-key SSH before claiming DHCP/SSH fixed.
- If BIOS fails, still collect independent UEFI boot/VGA evidence.


## 2026-11-22 — CI host SSH private key file ownership after DHCP fix

- Actions #45013270141 built the image, booted both Legacy BIOS and UEFI,
  completed the actual tty1 PAM+firstboot flow, and obtained 10.0.2.15 via
  DHCP with enp0s2 routable/configured on both boots. This confirms the
  networkd .network file permission fix.
- BIOS SSH check failed *locally*, repeatedly reporting
  `Load key ".../usb-ci-ssh-key": Permission denied`. The CI key was
  created by sudo/root in tests/build-image.sh under umask 077; it was
  never chowned to the invoking Actions runner. The SSH server did start,
  so this is not evidence of a guest-side SSH authorization rejection.
- Fix: validate numeric SUDO_UID/SUDO_GID against the runner temp directory;
  set ownership of only the temporary CI SSH keypair to that user, private
  mode 0600, public mode 0644. Keep password files, guest keys, and physical
  installer behavior unchanged. Before QEMU boot, have the actual non-root
  Actions runner check private key owner/mode and run `ssh-keygen -y -f`
  with output discarded. This tests real key readability, not only syntax.
- Recheck BIOS public-key-only SSH, deny root and runner SSH, and full UEFI
  onboarding/SSH. No full success until these real checks pass.


## 2026-11-22 — one-off cached CI after SSH key owner fix

- Static/safety passed in [Actions #45014145909](https://github.com/2rwa/ubuntu-headless-usb/actions/runs/45014145909).
- A real cached minimal image integration should check that the *runner*
  can read the CI SSH key with ssh-keygen -y (0600), then complete BIOS
  login/PAM, firstboot, DHCP, positive public-key SSH and negative root/runner
  SSH tests, and full UEFI onboarding/SSH. Preserve the 180s per-boot cap.
- Do not infer success from the preflight alone; real SSH handshake is required.


## 2026-11-22 — #45014205440 authentication failure ambiguity

- Host generated private key now passes the actual non-root readability
  check (ssh-keygen -y). BIOS boots, PAM+firstboot pass, DHCP 10.0.2.15 and
  guest READY pass. 15 SSH attempts returned nonzero, with no key permission
  error. The old test ran authentication *and* remote marker/service checks
  in one compound SSH command with quiet errors, so this does not prove
  whether SSH authentication failed or remote systemctl assertions failed.
- Split the verification into: SSH command `id -un` (actual public-key
  authentication and expected identity), then guest service/marker checks
  with explicit per-unit success or failure. On authentication failure,
  restrict debug output to selected transport/key-exchange result messages,
  not private key material or a full SSH trace. Only five short retries.
- A green static test does not prove real SSH. Run a cached minimal boot
  to measure the actual outcome, and recheck full UEFI once BIOS passes.


## 2026-11-22 — one-shot CI after SSH stage separation

- Static/safety verification passed in Actions #45016709142.
- One cached minimal Ubuntu integration is required. Specifically verify
  whether authenticated SSH `id -un` returns expected login user or the
  client reports transport/public-key failure; only then execute remote
  per-service checks, preserve root/runner login denials, and run full UEFI
  onboarding if BIOS succeeds. Keep 180s per-firmware hard caps.
- A successful local key-read preflight is not an SSH handshake result.


## 2026-11-22 — firstboot TCG timing variation #45016787335

- BIOS systemd and the actual tty1 PAM password change completed; CI observed
  FIRSTBOOT_BEGIN but the fixed 40s wait expired while SSH was starting.
  Previous cached runs had firstboot complete in 22–36s, so a fixed 40s
  limit is too narrow for the measured TCG variation. SSH verification was
  **not reached** in this run, despite the earlier SSH diagnostic code.
- Record every security-sensitive *stage name and timing only* for host keys,
  sshd preflight, unmask, resolved, networkd, SSH, and Avahi. On all physical
  installs the CI-only marker file is absent, so no serial diagnostics run.
  Do not dump passwords, keys, raw tty1 content or SSH debug traces.
- Raise firstboot host marker deadline to 55s but retain the 180s overall
  per-firmware QEMU timeout. The new markers must show which systemctl stage
  consumes the elapsed time; don't label a 40s deadline as a systemd failure.
- Execute safety tests first; run exactly one opt-in cached minimal Ubuntu
  integration for BIOS DHCP/SSH then UEFI fallback/full verification.
