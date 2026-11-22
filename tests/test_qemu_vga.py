#!/usr/bin/env python3
"""No QEMU required: image encoding and keyboard mapping regressions."""
import importlib.util
import pathlib
import struct
import tempfile
import unittest
import zlib

here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("qemu_vga", here / "qemu-vga.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class FakeMonitor:
    def __init__(self):
        self.sent = []
    def sendall(self, value):
        self.sent.append(value.decode())
    def recv(self, amount):
        return b"OK\n(qemu)"

class VGATests(unittest.TestCase):
    def test_ppm_and_png(self):
        w, h = 320, 200
        rgb = (b"\0\0\0" + b"\xff\xff\xff" + b"\x30\x50\x70") * (w * h // 3)
        rgb += b"\0\0\0" * (w * h - len(rgb) // 3)
        data = b"P6\n320 200\n255\n" + rgb
        self.assertEqual(module.read_ppm(data), (w, h, rgb))
        with tempfile.TemporaryDirectory() as td:
            target = pathlib.Path(td) / "test.png"
            module.make_png(target, w, h, rgb)
            raw = target.read_bytes()
            self.assertTrue(raw.startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertEqual(struct.unpack(">II", raw[16:24]), (w, h))
            self.assertIn(b"IDAT", raw)
    def test_bad_ppm_rejected(self):
        for data in (b"BAD", b"P6\n4 2\n255\n", b"P6\n320 200\n255\n"):
            with self.assertRaises(ValueError):
                module.read_ppm(data)
    def test_two_color_tty_is_not_blank(self):
        # Real VGA text mode often contains exactly two colors, not three.
        w, h = 320, 200
        rgb = bytearray(b"\x00\x00\x00" * (w * h))
        for row in range(30, 55):
            for col in range(35, 95):
                offset = (row * w + col) * 3
                rgb[offset:offset+3] = b"\xd0\xd0\xd0"
        with tempfile.TemporaryDirectory() as td:
            target = pathlib.Path(td) / "two-color.png"
            original = module.command
            module.command = lambda sock, cmd: pathlib.Path(
                cmd.split(" ", 1)[1]).write_bytes(
                    b"P6\n320 200\n255\n" + bytes(rgb))
            try:
                module.screenshot(FakeMonitor(), target)
                self.assertTrue(target.exists())
            finally:
                module.command = original

    def test_blank_screenshot_retained_on_failure(self):
        w, h = 320, 200
        with tempfile.TemporaryDirectory() as td:
            target = pathlib.Path(td) / "blank.png"
            original = module.command
            module.command = lambda sock, cmd: pathlib.Path(
                cmd.split(" ", 1)[1]).write_bytes(
                    b"P6\n320 200\n255\n" + b"\x00\x00\x00" * (w * h))
            try:
                with self.assertRaisesRegex(AssertionError, "diagnostic PNG retained"):
                    module.screenshot(FakeMonitor(), target)
                self.assertTrue(target.exists())
            finally:
                module.command = original

    def test_keyboard(self):
        fake = FakeMonitor()
        module.press(fake, "abc-09_\n")
        self.assertEqual(fake.sent[0], "sendkey a 30\n")
        self.assertEqual(fake.sent[3], "sendkey minus 30\n")
        self.assertEqual(fake.sent[-2], "sendkey shift-minus 30\n")
        self.assertEqual(fake.sent[-1], "sendkey ret 30\n")
        with self.assertRaises(ValueError):
            module.press(fake, "非法")
if __name__ == "__main__":
    unittest.main()
