#!/usr/bin/env python3
"""Publish one verified unsigned package from its successful build job."""

import hashlib
import json
import os
from pathlib import Path
import re
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

LINUX_ARCH = {"linux-x64": 62, "linux-arm64": 183}
NOTES_START = "<!-- fillr-linux-verification:start -->"
NOTES_END = "<!-- fillr-linux-verification:end -->"
NOTES_DATA = "<!-- fillr-linux-verification:data "


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
        matches = [item for item in releases if item["tag_name"] == tag]
        if matches:
            # A failed legacy publisher can leave a second empty draft for the
            # same tag. Prefer the published release, then the oldest draft.
            return min(matches, key=lambda item: (item["draft"], item["id"]))
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
            header = stream.read(20)
        if (header[:4] != b"\x7fELF" or header[8:11] != b"AI\x02" or
                int.from_bytes(header[18:20], "little") != LINUX_ARCH[kind]):
            raise ValueError(f"AppImage header or architecture is invalid: {package}")
    return package


def linux_verification(kind):
    status = os.environ.get("LINUX_RUNTIME_STATUS", "")
    reason = os.environ.get("LINUX_RUNTIME_REASON", "")
    accessibility = os.environ.get("LINUX_ACCESSIBILITY_STATUS", "")
    if status not in {"passed", "skipped"}:
        raise ValueError("Linux runtime status must be passed or skipped")
    if accessibility not in {"success", "failure"}:
        raise ValueError("Linux accessibility status must be success or failure")
    if status == "skipped" and not reason:
        raise ValueError("Skipped Linux runtime test needs a reason")
    if len(reason) > 200 or "\n" in reason or "\r" in reason:
        raise ValueError("Invalid Linux runtime skip reason")
    return {"runtime": status, "reason": reason if status == "skipped" else "",
            "accessibility": accessibility}


def update_linux_notes(body, kind, verification):
    states = {}
    if NOTES_START in body:
        before, remainder = body.split(NOTES_START, 1)
        block, after = remainder.split(NOTES_END, 1)
        match = re.search(r"<!-- fillr-linux-verification:data (\{[^\n]*\}) -->", block)
        if not match:
            raise ValueError("Cannot read existing Linux release verification")
        states = json.loads(match.group(1))
    else:
        before, after = body, ""
    states[kind] = verification
    lines = [NOTES_START, "## Linux verification"]
    for target, label in (("linux-x64", "x64"), ("linux-arm64", "ARM64")):
        if target not in states:
            continue
        result = states[target]
        if result["runtime"] == "passed":
            detail = ("**Automated runtime verified — community testing pending.** "
                      "Packaged probe and AppImage launch smoke tests passed.")
        else:
            detail = ("**Build verified — community testing pending.** Packaged artifact and "
                      f"checksum passed; AppImage launch smoke test skipped. Reason: {result['reason']}")
        optional = ("Optional Qt accessibility checks passed." if result["accessibility"] == "success"
                    else "Optional Qt accessibility checks failed; see the CI run for diagnostics.")
        lines.append(f"- **{label}:** {detail} No manual Linux runtime testing is recorded "
                     f"for this release. {optional}")
    lines.append(NOTES_DATA + json.dumps(states, sort_keys=True) + " -->")
    lines.append(NOTES_END)
    return "\n\n".join(part for part in (before.rstrip(), "\n".join(lines), after.lstrip()) if part)


def edit_notes(repository, tag, notes):
    with tempfile.TemporaryDirectory() as temporary:
        notes_file = Path(temporary) / "release-notes.md"
        notes_file.write_text(notes + "\n")
        gh("release", "edit", tag, "--repo", repository, "--notes-file", str(notes_file))


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
    verification = linux_verification(kind) if kind in LINUX_ARCH else None
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
    if verification is not None:
        old_notes = current.get("body") or ""
        notes = update_linux_notes(old_notes, kind, verification)
        if notes != old_notes:
            edit_notes(repository, tag, notes)
    if current["draft"]:
        gh("release", "edit", tag, "--repo", repository, "--draft=false", "--prerelease")
    print(f"Published and verified {package.name} SHA256 {expected_digest}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: publish_direct.py KIND ARTIFACT_DIRECTORY")
    publish(sys.argv[1], Path(sys.argv[2]))
