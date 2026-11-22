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
