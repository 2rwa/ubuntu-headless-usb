#!/usr/bin/env python3
"""Concurrent, non-persistent QEMU VGA watcher; only numerical changes are logged.

The input/keyboard monitor is a *different* QEMU HMP socket, so sampling does
not compete with sendkey. Guest password frames are never converted to PNG,
uploaded, or printed as text. Each temporary PPM lives in a 0700 directory.
"""
import argparse
import datetime
import importlib.util
import pathlib
import signal
import sys
import tempfile
import time

def load_hmp_helper():
    source = pathlib.Path(__file__).with_name("qemu-vga.py")
    spec = importlib.util.spec_from_file_location("qemu_vga_helper", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def measure_frame(width, height, pixels, previous):
    """Counts changed scanlines, plus sparse foreground samples."""
    row_size = width * 3
    background = pixels[:3]
    foreground = sum(
        pixels[i:i + 3] != background for i in range(0, len(pixels), 48)
    )
    changed_rows = []
    if previous is not None and len(previous) == len(pixels):
        changed_rows = [
            y for y in range(height)
            if previous[y * row_size:(y + 1) * row_size] !=
               pixels[y * row_size:(y + 1) * row_size]
        ]
    return foreground, changed_rows

def read_frame(helper, sock, ppm):
    # QEMU screendump is file-backed. PPM exists only under a private temp dir.
    ppm.unlink(missing_ok=True)
    helper.command(sock, "screendump " + str(ppm))
    for _ in range(30):
        if ppm.is_file() and ppm.stat().st_size > 1000:
            break
        time.sleep(0.1)
    width, height, pixels = helper.read_ppm(ppm.read_bytes())
    ppm.unlink(missing_ok=True)
    return width, height, pixels

def main():
    cli = argparse.ArgumentParser()
    cli.add_argument("socket", help="dedicated observer HMP socket")
    cli.add_argument("log", help="text-only metrics log")
    cli.add_argument("--interval", type=float, default=2.0)
    cli.add_argument("--frames", type=int, default=0,
                     help="0 runs until terminated; positive for smoke tests")
    args = cli.parse_args()
    if not 0.2 <= args.interval <= 30 or args.frames < 0:
        cli.error("invalid polling interval or frame count")
    log_path = pathlib.Path(args.log)
    if not log_path.is_absolute() or log_path.exists():
        cli.error("observer log must be a new absolute path")
    if not pathlib.Path(args.socket).is_absolute():
        cli.error("observer socket must be absolute")
    helper = load_hmp_helper()
    started = time.monotonic()
    previous = None
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    with log_path.open("x", encoding="utf-8") as output:
        def emit(message):
            timestamp = datetime.datetime.now(
                datetime.timezone.utc).isoformat(timespec="seconds")
            line = "VGA_OBSERVER " + timestamp + " " + message
            print(line, flush=True)
            print(line, file=output, flush=True)

        with tempfile.TemporaryDirectory(prefix="usb-ci-vga-private-",
                                         dir=str(log_path.parent)) as temp:
            ppm = pathlib.Path(temp) / "frame.ppm"
            sock = None
            for _ in range(75):
                try:
                    sock = helper.hmp(args.socket)
                    break
                except (OSError, RuntimeError):
                    time.sleep(0.2)
            if sock is None:
                raise RuntimeError("observer HMP socket unavailable (15s)")
            with sock:
                sock.settimeout(5)
                emit("READY socket=independent-hmp private_frames=yes")
                frame = 0
                while args.frames == 0 or frame < args.frames:
                    t0 = time.monotonic()
                    width, height, rgb = read_frame(helper, sock, ppm)
                    foreground, changed = measure_frame(
                        width, height, rgb, previous
                    )
                    frame += 1
                    rows = (
                        str(min(changed)) + "-" + str(max(changed))
                        if changed else "none"
                    )
                    emit("FRAME frame=%d elapsed=%.1fs size=%dx%d "
                         "foreground_samples=%d changed_rows=%d span=%s"
                         % (frame, time.monotonic() - started,
                            width, height, foreground, len(changed), rows))
                    previous = rgb
                    time.sleep(max(0.0, args.interval -
                                   (time.monotonic() - t0)))
                emit("DONE frames=%d" % frame)

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        print("VGA_OBSERVER_ERROR " + str(exc), file=sys.stderr, flush=True)
        sys.exit(1)
