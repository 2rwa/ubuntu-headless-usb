#!/usr/bin/env python3
"""Independent QEMU VGA monitoring with pre-login boot screenshots.

Before any interactive keyboard input, save bounded timestamped screenshots
of boot console changes. After the host stop/ack handshake, only numerical
framebuffer metrics continue; sensitive authentication frames are NEVER saved.
The private screendump PPM is always removed after reading.
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
    cli.add_argument("--capture-dir", help="private destination for prelogin PNG snapshots")
    cli.add_argument("--capture-stop-file", help="host creates this before keyboard input")
    cli.add_argument("--capture-ack-file", help="observer creates when PNG capture is disabled")
    cli.add_argument("--max-captures", type=int, default=20)
    args = cli.parse_args()
    if args.capture_dir and not (args.capture_stop_file and args.capture_ack_file):
        cli.error("capture directory requires stop and acknowledgement paths")
    if (args.capture_stop_file or args.capture_ack_file) and not args.capture_dir:
        cli.error("stop and acknowledgement require a capture directory")
    if not 0.2 <= args.interval <= 30 or args.frames < 0 or not 1 <= args.max_captures <= 60:
        cli.error("invalid polling interval or frame count")
    log_path = pathlib.Path(args.log)
    if not log_path.is_absolute() or log_path.exists():
        cli.error("observer log must be a new absolute path")
    if not pathlib.Path(args.socket).is_absolute():
        cli.error("observer socket must be absolute")
    helper = load_hmp_helper()
    capture_dir = pathlib.Path(args.capture_dir) if args.capture_dir else None
    stop_file = pathlib.Path(args.capture_stop_file) if args.capture_stop_file else None
    ack_file = pathlib.Path(args.capture_ack_file) if args.capture_ack_file else None
    if capture_dir:
        if any(not p.is_absolute() or p.exists() for p in (capture_dir, stop_file, ack_file)):
            cli.error("capture paths must be new absolute paths")
        capture_dir.mkdir(mode=0o700)
    started = time.monotonic()
    previous = None
    snapshots = 0
    capture_disabled = capture_dir is None
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
                    # The ack is an explicit security barrier: the host must
                    # observe it BEFORE sending any username/password input.
                    if stop_file and stop_file.exists() and not capture_disabled:
                        capture_disabled = True
                        ack_file.touch(exist_ok=False)
                        emit("CAPTURE_DISABLED ack=yes snapshots=%d" % snapshots)
                    try:
                        width, height, rgb = read_frame(helper, sock, ppm)
                    except (OSError, ValueError, RuntimeError) as exc:
                        # Before VGA initialization, screendump can legitimately
                        # fail. Retry without saving an incomplete frame.
                        emit("FRAME_UNAVAILABLE reason=%s" % type(exc).__name__)
                        time.sleep(args.interval)
                        continue
                    foreground, changed = measure_frame(width, height, rgb, previous)
                    frame += 1
                    elapsed = time.monotonic() - started
                    rows = (str(min(changed)) + "-" + str(max(changed))
                            if changed else "none")
                    emit("FRAME frame=%d elapsed=%.1fs size=%dx%d "
                         "foreground_samples=%d changed_rows=%d span=%s"
                         % (frame, elapsed, width, height, foreground,
                            len(changed), rows))
                    # Re-check after screendump: a stop request may have been
                    # received while the QEMU monitor was creating its frame.
                    if stop_file and stop_file.exists() and not capture_disabled:
                        capture_disabled = True
                        ack_file.touch(exist_ok=False)
                        emit("CAPTURE_DISABLED ack=yes snapshots=%d" % snapshots)
                    if (capture_dir and not capture_disabled and
                            snapshots < args.max_captures and
                            (previous is None or len(changed) >= 3)):
                        name = "boot-%03d-%07dms.png" % (frame, int(elapsed * 1000))
                        helper.make_png(capture_dir / name, width, height, rgb)
                        snapshots += 1
                        emit("SNAPSHOT filename=%s elapsed=%.1fs count=%d"
                             % (name, elapsed, snapshots))
                    previous = rgb
                    time.sleep(max(0.0, args.interval -
                                   (time.monotonic() - t0)))
                emit("DONE frames=%d snapshots=%d" % (frame, snapshots))

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        print("VGA_OBSERVER_ERROR " + str(exc), file=sys.stderr, flush=True)
        sys.exit(1)
