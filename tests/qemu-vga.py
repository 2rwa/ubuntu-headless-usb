#!/usr/bin/env python3
"""Headless QEMU HMP keyboard & screendump test. Standard library only."""
import argparse
import pathlib
import re
import socket
import struct
import sys
import time
import zlib

def hmp(socket_path):
    sock = socket.socket(socket.AF_UNIX)
    sock.settimeout(15)
    sock.connect(socket_path)
    receive(sock)
    return sock

def receive(sock):
    output = bytearray()
    while b"(qemu)" not in output[-100:]:
        block = sock.recv(4096)
        if not block:
            raise RuntimeError("QEMU monitor closed connection")
        output.extend(block)
        if len(output) > 1048576:
            raise RuntimeError("Monitor response too large")
    result = output.decode("utf-8", errors="replace")
    if re.search(r"(?:Error:|unknown command|Could not open|invalid parameter)", result, re.I):
        raise RuntimeError(result)
    return result

def command(sock, cmd):
    sock.sendall((cmd + "\n").encode("utf-8"))
    return receive(sock)

KEYS = {" ": "spc", "_": "shift-minus", "-": "minus", ".": "dot",
        "/": "slash", "\n": "ret", "\r": "ret"}

def press(sock, value):
    for ch in value:
        if "a" <= ch <= "z" or "0" <= ch <= "9":
            key = ch
        elif "A" <= ch <= "Z":
            key = "shift-" + ch.lower()
        elif ch in KEYS:
            key = KEYS[ch]
        else:
            raise ValueError("Unsupported keyboard character (not sent)")
        command(sock, "sendkey " + key + " 30")
        time.sleep(0.04)

def read_ppm(data):
    # QEMU HMP screendump emits binary PPM (P6).
    if not data.startswith(b"P6"):
        raise ValueError("Unexpected VGA screenshot format; expected P6")
    offset = 2
    tokens = []
    while len(tokens) < 3:
        while offset < len(data) and data[offset] in b" \t\r\n":
            offset += 1
        if offset >= len(data):
            raise ValueError("Incomplete PPM header")
        if data[offset] == 35:
            offset = data.index(b"\n", offset) + 1
            continue
        end = offset
        while end < len(data) and data[end] not in b" \t\r\n":
            end += 1
        tokens.append(int(data[offset:end]))
        offset = end
    if data[offset] not in b" \t\r\n":
        raise ValueError("Missing PPM pixel separator")
    offset += 1
    width, height, max_value = tokens
    if max_value != 255 or width < 320 or height < 200 or width * height > 3000000:
        raise ValueError("VGA geometry or pixel format invalid")
    pixels = data[offset:offset + width * height * 3]
    if len(pixels) != width * height * 3:
        raise ValueError("Truncated PPM data")
    return width, height, pixels

def chunk(code, payload):
    body = code + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)

def make_png(path, w, h, rgb):
    stride = w * 3
    scanlines = b"".join(b"\0" + rgb[row * stride:(row + 1) * stride] for row in range(h))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(scanlines, 8))
    png += chunk(b"IEND", b"")
    pathlib.Path(path).write_bytes(png)

def screenshot(sock, png_path):
    path = pathlib.Path(png_path)
    if not path.is_absolute() or path.suffix != ".png":
        raise ValueError("Screenshot path must be absolute .png")
    ppm = path.with_suffix(".ppm")
    if ppm.exists() or path.exists():
        raise ValueError("Refusing screenshot overwrite")
    try:
        command(sock, "screendump " + str(ppm))
        for _ in range(30):
            if ppm.exists() and ppm.stat().st_size > 1000:
                break
            time.sleep(0.1)
        w, h, rgb = read_ppm(ppm.read_bytes())
        # A black or solid-color VGA buffer is not proof of a working console.
        colors = {rgb[i:i+3] for i in range(0, len(rgb), 291)}
        if len(colors) < 3:
            raise AssertionError("VGA framebuffer appears blank/solid")
        make_png(path, w, h, rgb)
        print("PASS: VGA framebuffer captured as PNG (%dx%d; %d sampled colors)" % (w, h, len(colors)))
    finally:
        ppm.unlink(missing_ok=True)

def main():
    cli = argparse.ArgumentParser()
    cli.add_argument("action", choices=["type", "type-file", "enter", "capture"])
    cli.add_argument("socket")
    cli.add_argument("argument", nargs="?")
    args = cli.parse_args()
    with hmp(args.socket) as sock:
        if args.action == "capture":
            screenshot(sock, args.argument)
        elif args.action == "enter":
            press(sock, "\n")
        elif args.action == "type-file":
            # Password never enters argv, stdout, GitHub Actions logs, or artifacts.
            value = pathlib.Path(args.argument).read_text().strip()
            if not re.fullmatch(r"[a-f0-9]{24}", value):
                raise ValueError("Unexpected protected password format")
            press(sock, value + "\n")
        else:
            if not args.argument:
                raise ValueError("Missing text to send")
            press(sock, args.argument + "\n")
            print("Sent console keyboard input")

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, AssertionError) as exc:
        print("VGA monitor test failed: %s" % exc, file=sys.stderr)
        sys.exit(1)
