#!/usr/bin/env python3
"""Stage an exact optional Hermes plugin source tree outside any profile.

This command deliberately does not install, enable, update, or pair a plugin.
The operator must name one locked plugin and a new output directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "plugins" / "lock.json"


def load_lock() -> dict:
    with LOCK_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)


def archive_url(entry: dict) -> str:
    return f"https://github.com/{entry['repository']}/archive/{entry['commit']}.tar.gz"


def verify_digest(path: Path, expected: str) -> None:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual != expected:
        raise ValueError(f"archive SHA-256 mismatch: expected {expected}, got {actual}")


def safe_members(archive: tarfile.TarFile) -> tuple[str, list[tarfile.TarInfo]]:
    members = archive.getmembers()
    if not members:
        raise ValueError("plugin archive is empty")
    roots: set[str] = set()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise ValueError(f"unsafe archive path: {member.name}")
        if member.issym() or member.islnk() or member.isdev():
            raise ValueError(f"unsupported archive member: {member.name}")
        roots.add(path.parts[0])
    if len(roots) != 1:
        raise ValueError("plugin archive must contain exactly one top-level directory")
    return roots.pop(), members


def extract_archive(path: Path, destination: Path) -> None:
    with tarfile.open(path, "r:gz") as archive:
        root, members = safe_members(archive)
        for member in members:
            relative = PurePosixPath(member.name).relative_to(root)
            if str(relative) == ".":
                continue
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError(f"cannot read archive member: {member.name}")
                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                os.chmod(target, member.mode & 0o777)


def manifest_version(path: Path) -> tuple[str, str]:
    text = path.read_text(encoding="utf-8")
    name = re.search(r"(?m)^name:\s*[\"']?([^\"'\s]+)", text)
    version = re.search(r"(?m)^version:\s*[\"']?([^\"'\s]+)", text)
    if not name or not version:
        raise ValueError("plugin.yaml lacks a simple name/version declaration")
    return name.group(1), version.group(1)


def stage(plugin: str, output: Path, supplied_archive: Path | None) -> None:
    lock = load_lock()
    try:
        entry = lock["plugins"][plugin]
    except KeyError as exc:
        raise ValueError(f"unknown locked plugin: {plugin}") from exc
    if output.exists():
        raise ValueError(f"output already exists; refusing to overwrite: {output}")
    lowered_parts = {part.lower() for part in output.parts}
    if output.parent.name.lower() == "plugins" or "plugin-data" in lowered_parts:
        raise ValueError(
            "output looks like a live Hermes profile path; stage elsewhere, review, "
            "then install explicitly"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hermes-plugin-stage-", dir=output.parent) as temp:
        temp_path = Path(temp)
        archive = temp_path / "source.tar.gz"
        if supplied_archive:
            shutil.copyfile(supplied_archive, archive)
        else:
            with urllib.request.urlopen(archive_url(entry), timeout=60) as response, archive.open("wb") as handle:
                shutil.copyfileobj(response, handle)
        verify_digest(archive, entry["archive_sha256"])
        extracted = temp_path / "source"
        extracted.mkdir()
        extract_archive(archive, extracted)
        got_name, got_version = manifest_version(extracted / "plugin.yaml")
        if (got_name, got_version) != (plugin, entry["version"]):
            raise ValueError(
                f"plugin manifest mismatch: expected {plugin} {entry['version']}, "
                f"got {got_name} {got_version}"
            )
        receipt = {
            "plugin": plugin,
            "version": entry["version"],
            "repository": entry["repository"],
            "tag": entry["tag"],
            "commit": entry["commit"],
            "archive_sha256": entry["archive_sha256"],
            "compatible_hermes": lock["hermes"],
            "runtime": entry["runtime"],
            "installed": False,
            "enabled": False,
            "paired": False,
        }
        (extracted / "WOOWTECH-SOURCE-RECEIPT.json").write_text(
            json.dumps(receipt, indent=2) + "\n", encoding="utf-8"
        )
        extracted.rename(output)
    print(f"staged {plugin} {entry['version']} at {output}")
    print("not installed, not enabled, not paired; profile data was not accessed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="list locked plugins without network access")
    parser.add_argument("--plugin", help="locked plugin name to stage")
    parser.add_argument("--output", type=Path, help="new staging directory (must not exist)")
    parser.add_argument("--archive", type=Path, help="use an already-downloaded archive (tests/offline use)")
    args = parser.parse_args()
    lock = load_lock()
    if args.list:
        for name, entry in lock["plugins"].items():
            print(f"{name}\t{entry['version']}\t{entry['commit']}\t{entry['runtime']}")
        return 0
    if not args.plugin or not args.output:
        parser.error("--plugin and --output are required unless --list is used")
    stage(args.plugin, args.output.resolve(), args.archive.resolve() if args.archive else None)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, tarfile.TarError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
