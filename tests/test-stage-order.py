#!/usr/bin/env python3
from pathlib import Path
root = Path(__file__).resolve().parents[1]
for filename in ("install.sh", "tests/build-image.sh"):
    content = (root / filename).read_text()
    sequence = ('usb_stage_begin', 'source "$HERE/lib/stage-packages.sh"', 'usb_stage_finish',
                'usb_partition_gpt "$DEV"', 'usb_copy_stage "$STAGE" "$ROOT"',
                'source "$HERE/lib/provision.sh"')
    positions = [content.index(s) for s in sequence]
    assert positions == sorted(positions), filename
    assert "usb_stage_begin" in content
stage = (root / "lib/stage-packages.sh").read_text()
assert 'usb_apt_transaction install' in stage and 'usb_apt_transaction upgrade' in stage
provision = (root / "lib/provision.sh").read_text()
assert "apt-get" not in provision and "debootstrap" not in provision
assert "USB_STAGE_VERIFIED" in provision
print("PASS: both entrypoints prepare packages before target writes; offline final configuration")
