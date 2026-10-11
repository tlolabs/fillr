#!/usr/bin/env python3
"""Publish one verified unsigned package from its successful build job."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import zipfile

from version import version


ASSETS = {
    "macos": "FILLR-universal-unsigned.zip",
    "windows-x64": "FILLR-win-x64-unsigned.zip",
    "windows-arm64": "FILLR-win-arm64-unsigned.zip",
    "linux-x64": "FILLR-linux-x86_64.AppImage",
    "linux-arm64": "FILLR-linux-aarch64.AppImage",
}


def gh(*args, check=True):
    result = subprocess.run(["gh", *args], text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result


def release(repository, tag):
    # GitHub's release-by-tag endpoint omits drafts, although the release list
    # includes drafts visible to this token. The first publisher must resume
    # its draft after creation or a transient failure.
    for page in range(1, 6):
        result = gh("api", f"repos/{repository}/releases?per_page=100&page={page}")
        releases = json.loads(result.stdout)
        current = next((item for item in releases if item["tag_name"] == tag), None)
        if current is not None:
            return current
        if len(releases) < 100:
            return None
    raise RuntimeError("Release lookup exceeded five pages")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def validate_package(kind, directory):
    filename = ASSETS[kind]
    package = directory / filename
    if not directory.is_dir() or set(directory.iterdir()) != {package}:
        raise ValueError(f"Expected exactly {filename} in {directory}")
    if not package.is_file() or package.stat().st_size < 1024 * 1024:
        raise ValueError(f"Package is missing or unexpectedly small: {package}")
    if filename.endswith(".zip"):
        with zipfile.ZipFile(package) as archive:
            if not archive.namelist() or archive.testzip() is not None:
                raise ValueError(f"Package ZIP is corrupt: {package}")
    else:
        with package.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                raise ValueError(f"AppImage is not an ELF executable: {package}")
    return package


def verify_uploaded(repository, tag, package, expected_digest):
    for attempt in range(3):
        with tempfile.TemporaryDirectory() as temporary:
            result = gh("release", "download", tag, "--repo", repository,
                        "--pattern", package.name,
                        "--dir", temporary, check=False)
            downloaded = Path(temporary) / package.name
            if result.returncode == 0 and downloaded.is_file():
                if digest(downloaded) != expected_digest:
                    raise ValueError(f"Published asset differs from verified package: {package.name}")
                return
        if attempt < 2:
            time.sleep(2)
    raise RuntimeError(f"Could not verify published asset: {package.name}")


def publish(kind, directory):
    if kind not in ASSETS:
        raise ValueError(f"Unknown package kind: {kind}")
    tag = os.environ["GITHUB_REF_NAME"]
    if os.environ["GITHUB_REF"] != f"refs/tags/{tag}" or tag != f"v{version()}":
        raise ValueError("Direct publication requires the exact version tag")
    repository = os.environ["GITHUB_REPOSITORY"]
    package = validate_package(kind, directory)
    expected_digest = digest(package)
    title = f"FILLR {version()} unsigned downloads"

    current = release(repository, tag)
    if current is None:
        notes = ("Unsigned direct-download packages. Install manually. These assets are "
                 "not signed automatic updates; the updater continues to require "
                 "authenticated metadata and platform trust.")
        created = gh("release", "create", tag, "--repo", repository, "--verify-tag",
                     "--draft", "--prerelease", "--latest=false", "--title", title,
                     "--notes", notes, check=False)
        for attempt in range(3):
            current = release(repository, tag)
            if current is not None:
                break
            if attempt < 2:
                time.sleep(2)
        if current is None:
            raise RuntimeError(f"Could not create release: {created.stderr.strip()}")
    if (current["tag_name"] != tag or current["name"] != title or
            not current["prerelease"]):
        raise ValueError("Refusing to add unsigned package to another release channel")

    existing = next((asset for asset in current["assets"] if asset["name"] == package.name), None)
    if existing is None:
        uploaded = gh("release", "upload", tag, str(package), "--repo", repository,
                      check=False)
        for attempt in range(3):
            current = release(repository, tag)
            existing = next((asset for asset in current["assets"]
                             if asset["name"] == package.name), None)
            if existing is not None:
                break
            if attempt < 2:
                time.sleep(2)
        if existing is None:
            raise RuntimeError(f"Could not upload {package.name}: {uploaded.stderr.strip()}")
    if existing["size"] != package.stat().st_size:
        raise ValueError(f"Published asset has different size: {package.name}")
    verify_uploaded(repository, tag, package, expected_digest)
    if current["draft"]:
        gh("release", "edit", tag, "--repo", repository, "--draft=false", "--prerelease")
    print(f"Published and verified {package.name} SHA256 {expected_digest}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: publish_direct.py KIND ARTIFACT_DIRECTORY")
    publish(sys.argv[1], Path(sys.argv[2]))
