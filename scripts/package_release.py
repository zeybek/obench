#!/usr/bin/env python3
"""Packs the release archives so the same inputs always give the same bytes.

    python3 scripts/package_release.py --tag v0.4.0 --epoch 1763600000 --dist dist --out release

writes into --out:

- obench-<tag>-library.tar.gz and .zip: the obench folder (obench/*.odin and LICENSE)
- obench-<tag>-<target>.tar.gz, or .zip for Windows: the CLI from --dist/cli-<target>/
- a .sha256 file next to each archive, in the format of sha256sum

Entries are sorted, every timestamp is --epoch (the release commit's time), owners are 0 and
nameless, modes are 0644 for files and 0755 for directories and executables, and the gzip
header carries no name or time. The release workflow runs it after building the CLIs.
"""

import argparse
import gzip
import hashlib
import io
import pathlib
import sys
import tarfile
import time
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def tar_gz(path, entries, epoch):
    """`entries` is a list of (archive name, bytes or None for a directory, mode)."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data, mode in sorted(entries):
            info = tarfile.TarInfo(name)
            info.mtime = epoch
            info.mode = mode
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if data is None:
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    with open(path, "wb") as out:
        with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9) as gz:
            gz.write(raw.getvalue())


def zip_file(path, entries, epoch):
    stamp = time.gmtime(max(epoch, 315532800))[:6]  # zip can't store times before 1980
    with zipfile.ZipFile(path, "w") as z:
        for name, data, mode in sorted(entries):
            info = zipfile.ZipInfo(name + "/" if data is None else name, date_time=stamp)
            info.create_system = 3  # Unix, so the mode below is kept
            info.external_attr = ((0o040000 if data is None else 0o100000) | mode) << 16
            if data is None:
                z.writestr(info, b"")
            else:
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, data, compresslevel=9)


def write_sha256(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    path.with_name(path.name + ".sha256").write_text(f"{digest}  {path.name}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tag", required=True)
    ap.add_argument("--epoch", required=True, type=int)
    ap.add_argument("--dist", required=True, type=pathlib.Path)
    ap.add_argument("--out", required=True, type=pathlib.Path)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    archives = []

    library = [("obench", None, 0o755)]
    for src in sorted((ROOT / "obench").glob("*.odin")) + [ROOT / "LICENSE"]:
        library.append((f"obench/{src.name}", src.read_bytes(), 0o644))
    for ext, pack in ((".tar.gz", tar_gz), (".zip", zip_file)):
        path = args.out / f"obench-{args.tag}-library{ext}"
        pack(path, library, args.epoch)
        archives.append(path)

    targets = sorted(p for p in args.dist.glob("cli-*") if p.is_dir())
    if not targets:
        sys.exit(f"no cli-<target> folders in {args.dist}")
    for folder in targets:
        target = folder.name.removeprefix("cli-")
        windows = target.startswith("windows")
        exe = folder / ("obench.exe" if windows else "obench")
        if not exe.is_file():
            sys.exit(f"{exe} is missing")
        # Workflow artifacts don't keep the executable bit, so it's set here.
        entries = [(exe.name, exe.read_bytes(), 0o755)]
        path = args.out / f"obench-{args.tag}-{target}{'.zip' if windows else '.tar.gz'}"
        (zip_file if windows else tar_gz)(path, entries, args.epoch)
        archives.append(path)

    for path in archives:
        write_sha256(path)
        print(path)


if __name__ == "__main__":
    main()
