#!/usr/bin/env python3
"""Verify cached debs against SHA256 from authenticated APT package indexes."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

def index_hashes(lists):
    expected = {}
    files = sorted(p for p in lists.glob("*_Packages*") if p.is_file()
                   and p.name.rsplit("_Packages", 1)[1] in ("", ".lz4", ".gz", ".xz", ".zst"))
    if not files:
        raise RuntimeError("No APT package indexes; refusing to trust cache")
    for path in files:
        with subprocess.Popen(["/usr/lib/apt/apt-helper", "cat-file", str(path)],
                              stdout=subprocess.PIPE, text=True, encoding="utf-8",
                              errors="replace") as proc:
            fields = {}
            def record():
                if all(k in fields for k in ("Package", "Version", "Architecture", "Filename", "SHA256")):
                    digest = fields["SHA256"].lower()
                    if len(digest) != 64:
                        return
                    pkg, ver, arch = (fields[k] for k in ("Package", "Version", "Architecture"))
                    names = {Path(fields["Filename"]).name,
                             f"{pkg}_{ver.replace(':', '%3a')}_{arch}.deb",
                             f"{pkg}_{ver.replace(':', '%3A')}_{arch}.deb",
                             f"{pkg}_{ver.split(':', 1)[-1]}_{arch}.deb",
                             f"{pkg}_{ver}_{arch}.deb"}
                    for name in names:
                        expected.setdefault(name, set()).add(digest)
            for line in proc.stdout:
                if not line.strip():
                    record()
                    fields = {}
                elif not line[0].isspace() and ": " in line:
                    key, value = line.rstrip("\n").split(": ", 1)
                    if key in ("Package", "Version", "Architecture", "Filename", "SHA256"):
                        fields[key] = value
            record()
            if proc.wait():
                raise RuntimeError(f"Cannot read index {path.name}")
    if not expected:
        raise RuntimeError("No SHA256 package records; refusing to trust cache")
    return expected

def main():
    p = argparse.ArgumentParser()
    p.add_argument("lists", type=Path)
    p.add_argument("archives", type=Path)
    p.add_argument("--prune", action="store_true")
    args = p.parse_args()
    expected = index_hashes(args.lists)
    good = bad = 0
    for path in sorted(args.archives.glob("*.deb")):
        if path.is_symlink() or not path.is_file():
            raise RuntimeError(f"Unsafe cache entry: {path.name}")
        with path.open("rb") as f:
            digest = hashlib.file_digest(f, "sha256").hexdigest()
        if digest in expected.get(path.name, ()):
            good += 1
        else:
            print(f"Rejecting unverified archive: {path.name}", file=sys.stderr)
            path.unlink()
            bad += 1
    print(f"APT archive SHA256: verified={good} removed={bad}", flush=True)
    return 0 if args.prune or not bad else 1

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as exc:
        print(f"Cache verification failed: {exc}", file=sys.stderr)
        sys.exit(2)
