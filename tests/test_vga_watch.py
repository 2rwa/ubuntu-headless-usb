#!/usr/bin/env python3
"""Cheap unit regressions for the concurrent framebuffer metrics."""
import importlib.util
import pathlib

src = pathlib.Path(__file__).with_name("qemu-vga-watch.py")
spec = importlib.util.spec_from_file_location("qemu_vga_watch", src)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

w, h = 320, 200
blank = b"\0\0\0" * (w * h)
fg, rows = mod.measure_frame(w, h, blank, None)
assert fg == 0 and rows == []
text = bytearray(blank)
start = 33 * w * 3
text[start:start + 12] = b"\xff\xff\xff" * 4
fg, rows = mod.measure_frame(w, h, bytes(text), blank)
assert rows == [33] and fg >= 0
fg, rows = mod.measure_frame(w, h, bytes(text), bytes(text))
assert rows == []
print("PASS: concurrent VGA observer detects changed scanlines")
