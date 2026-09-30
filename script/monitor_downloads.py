#!/usr/bin/env python3
"""Read-only, high-frequency filesystem recorder for CNN/Signiant experiments.

Run with no arguments for a macOS folder picker, or pass a folder path. Press
Return or Control-C to stop. Output is JSON Lines plus a readable event log.
"""

from __future__ import annotations

import argparse
import collections
import ctypes
import datetime as dt
import hashlib
import json
import os
import platform
import pwd
import grp
import shutil
import stat
import statistics
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

VERSION = "1.0"
MEDIA_EXTENSIONS = {".mpg", ".mpeg", ".m2v", ".mov", ".mp4", ".mxf", ".ts", ".m2ts", ".avi", ".mkv", ".wav", ".aif", ".aiff", ".mp3"}

if not hasattr(os, "listxattr") and sys.platform == "darwin":
    _libc = ctypes.CDLL(None, use_errno=True)
    _libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    _libc.listxattr.restype = ctypes.c_ssize_t
    _libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                               ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    _libc.getxattr.restype = ctypes.c_ssize_t


def xattr_names(path: str) -> list[str]:
    if hasattr(os, "listxattr"):
        return os.listxattr(path, follow_symlinks=False)
    if sys.platform != "darwin":
        return []
    encoded = os.fsencode(path)
    size = _libc.listxattr(encoded, None, 0, 1)
    if size < 0:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()), path)
    if size == 0:
        return []
    buffer = ctypes.create_string_buffer(size)
    count = _libc.listxattr(encoded, buffer, size, 1)
    if count < 0:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()), path)
    return [os.fsdecode(part) for part in buffer.raw[:count].split(b"\0") if part]


def xattr_value(path: str, name: str) -> bytes:
    if hasattr(os, "getxattr"):
        return os.getxattr(path, name, follow_symlinks=False)
    if sys.platform != "darwin":
        return b""
    encoded, attr = os.fsencode(path), os.fsencode(name)
    size = _libc.getxattr(encoded, attr, None, 0, 0, 1)
    if size < 0:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()), path)
    if size == 0:
        return b""
    buffer = ctypes.create_string_buffer(size)
    count = _libc.getxattr(encoded, attr, buffer, size, 0, 1)
    if count < 0:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()), path)
    return buffer.raw[:count]


def clock(start_ns: int) -> dict:
    wall_ns = time.time_ns()
    whole, fraction = divmod(wall_ns, 1_000_000_000)
    local = dt.datetime.fromtimestamp(whole, dt.timezone.utc).astimezone()
    offset = local.strftime("%z")
    zone = f"{offset[:3]}:{offset[3:]}" if offset else "+00:00"
    return {"wall_time": local.strftime("%Y-%m-%dT%H:%M:%S") + f".{fraction:09d}{zone}",
            "monotonic_ns": time.monotonic_ns() - start_ns}


def identity(row: dict) -> str:
    return f"{row['device']}:{row['inode']}"


def object_type(mode: int) -> str:
    for predicate, name in ((stat.S_ISREG, "file"), (stat.S_ISDIR, "directory"),
                            (stat.S_ISLNK, "symlink"), (stat.S_ISSOCK, "socket"),
                            (stat.S_ISFIFO, "fifo"), (stat.S_ISCHR, "character_device"),
                            (stat.S_ISBLK, "block_device")):
        if predicate(mode):
            return name
    return "other"


def safe_username(uid: int) -> str | None:
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return None


def safe_groupname(gid: int) -> str | None:
    try:
        return grp.getgrgid(gid).gr_name
    except KeyError:
        return None


def xattrs(path: str) -> tuple[dict, str | None]:
    result = {}
    try:
        names = xattr_names(path)
    except (OSError, TypeError) as exc:
        return result, str(exc)
    for name in names:
        try:
            value = xattr_value(path, name)
            short = None
            if len(value) <= 256:
                try:
                    decoded = value.decode("utf-8")
                    if decoded.isprintable() or all(ch.isprintable() or ch in "\r\n\t" for ch in decoded):
                        short = decoded
                except UnicodeDecodeError:
                    pass
            result[name] = {"length": len(value), "sha256": hashlib.sha256(value).hexdigest(),
                            "text": short}
        except OSError as exc:
            result[name] = {"error": str(exc)}
    return result, None


def inspect(path: str, root: str) -> dict:
    st = os.lstat(path)
    mode = st.st_mode
    kind = object_type(mode)
    rel = os.path.relpath(path, root)
    attrs, attrs_error = xattrs(path)
    birth_ns = getattr(st, "st_birthtime_ns", None)
    birth_source = "st_birthtime_ns" if birth_ns is not None else None
    if birth_ns is None and hasattr(st, "st_birthtime"):
        birth_ns = int(st.st_birthtime * 1_000_000_000)
        birth_source = "st_birthtime_float_approximation"
    row = {
        "path": path, "relative_path": rel, "basename": os.path.basename(path),
        "extension": Path(path).suffix.lower(), "object_type": kind,
        "is_regular_file": kind == "file", "is_directory": kind == "directory",
        "is_symlink": kind == "symlink", "is_socket": kind == "socket",
        "is_fifo": kind == "fifo", "is_device": kind in ("character_device", "block_device"),
        "inode": st.st_ino, "device": st.st_dev, "identity": f"{st.st_dev}:{st.st_ino}",
        "size": st.st_size, "blocks": getattr(st, "st_blocks", None),
        "allocated_bytes": getattr(st, "st_blocks", 0) * 512 if hasattr(st, "st_blocks") else None,
        "block_size": getattr(st, "st_blksize", None), "nlink": st.st_nlink,
        "atime_ns": st.st_atime_ns, "mtime_ns": st.st_mtime_ns,
        "ctime_ns": st.st_ctime_ns, "birthtime_ns": birth_ns,
        "birthtime_source": birth_source,
        "atime_seconds": st.st_atime, "mtime_seconds": st.st_mtime,
        "ctime_seconds": st.st_ctime, "birthtime_seconds": getattr(st, "st_birthtime", None),
        "mode": oct(mode), "permissions": oct(stat.S_IMODE(mode)),
        "uid": st.st_uid, "gid": st.st_gid,
        "username": safe_username(st.st_uid), "groupname": safe_groupname(st.st_gid),
        "file_flags": getattr(st, "st_flags", None), "xattrs": attrs,
        "xattr_error": attrs_error,
        "symlink_target": os.readlink(path) if kind == "symlink" else None,
        "real_path": os.path.realpath(path),
    }
    if kind == "file" and row["allocated_bytes"] is not None:
        row["possibly_sparse"] = row["allocated_bytes"] < row["size"]
    return row


def choose_folder() -> str | None:
    if sys.platform == "darwin" and shutil.which("osascript"):
        command = ["osascript", "-e", 'POSIX path of (choose folder with prompt "Choose the CNN download folder to record")']
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
        if "User canceled" in result.stderr or "(-128)" in result.stderr:
            return None
    try:
        return input("Folder to watch (paste or drag it here): ").strip().strip("'\"")
    except EOFError:
        return None


def subprocess_version(command: list[str]) -> str | None:
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=3)
        return (output.stdout or output.stderr).splitlines()[0][:300]
    except (OSError, subprocess.TimeoutExpired, IndexError):
        return None


class LogWriter:
    def __init__(self, folder: Path, session_id: str):
        self.folder = folder
        self.session_id = session_id
        self.lock = threading.Lock()
        self.files = {name: (folder / name).open("w", encoding="utf-8", buffering=1024 * 1024)
                      for name in ("raw.jsonl", "events.jsonl", "timeline.txt")}
        self.last_flush = time.monotonic()

    def write(self, channel: str, row: dict) -> None:
        row = {"session_id": self.session_id, **row}
        with self.lock:
            self.files[channel].write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
            if time.monotonic() - self.last_flush >= 1:
                self.flush_locked()

    def event(self, event_type: str, when: dict, path: str | None, refs: list[str], **details) -> None:
        row = {"type": "event", "event": event_type, **when, "path": path,
               "observation_refs": refs, "details": details}
        self.write("events.jsonl", row)
        brief = ", ".join(f"{k}={v}" for k, v in details.items() if v is not None)
        with self.lock:
            self.files["timeline.txt"].write(
                f"{when['wall_time']} +{when['monotonic_ns'] / 1e9:.9f}s  "
                f"{event_type}  {path or ''}  {brief}\n")

    def flush_locked(self) -> None:
        for stream in self.files.values():
            stream.flush()
        self.last_flush = time.monotonic()

    def close(self) -> None:
        with self.lock:
            self.flush_locked()
            for stream in self.files.values():
                stream.close()


def lsof_observation(root: str, timeout: float) -> tuple[dict[str, list[dict]], str | None]:
    """Parse lsof field output; names outside root are discarded."""
    try:
        run = subprocess.run(["lsof", "-nP", "-Fpcufan", "+D", root],
                             capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {}, str(exc)
    # lsof returns 1 when there are no matching open files.
    if run.returncode not in (0, 1):
        return {}, run.stderr.decode("utf-8", "replace")[:500]
    result: dict[str, list[dict]] = collections.defaultdict(list)
    process: dict = {}
    file_info: dict = {}
    for field in run.stdout.decode("utf-8", "replace").splitlines():
        if not field:
            continue
        key, value = field[0], field[1:]
        if key == "p":
            process = {"pid": value}
            file_info = {}
        elif key == "c":
            process["process_name"] = value
        elif key == "u":
            process["user"] = value
        elif key == "f":
            file_info = {"file_descriptor": value}
        elif key == "a":
            file_info["access_mode"] = value
        elif key == "n" and value.startswith(root + os.sep):
            result[value].append({**process, **file_info})
    return dict(result), None


class Recorder:
    def __init__(self, args: argparse.Namespace, root: str, output: Path):
        self.args, self.root, self.output = args, root, output
        self.start_ns = time.monotonic_ns()
        self.stop = threading.Event()
        self.session_id = str(uuid.uuid4())
        self.logs = LogWriter(output, self.session_id)
        self.previous: dict[str, dict] = {}
        self.summaries: dict[str, dict] = {}
        self.path_history: dict[str, set[str]] = collections.defaultdict(set)
        self.process_lock = threading.Lock()
        self.process_state: dict[str, list[dict]] = {}
        self.process_when: dict | None = None
        self.process_ref: str | None = None
        self.probe_lock = threading.Lock()
        self.probe_candidates: dict[str, dict] = {}
        self.probe_previous: dict[str, dict] = {}
        bundled_probe = Path(__file__).resolve().parent.parent / "dist" / "ffprobe-universal"
        self.ffprobe_path = None if args.no_ffprobe else (
            str(bundled_probe) if os.access(bundled_probe, os.X_OK) else None)
        self.intervals_ns: list[int] = []
        self.scan_ns: list[int] = []
        self.late_cycles = 0
        self.cycles = 0
        self.errors = 0
        self.threads: list[threading.Thread] = []

    def metadata(self) -> dict:
        ffprobe_version = subprocess_version([self.ffprobe_path, "-version"]) if self.ffprobe_path else None
        lsof_version = subprocess_version(["lsof", "-v"]) if not self.args.no_lsof else None
        return {"type": "session_start", **clock(self.start_ns), "monitor_version": VERSION,
                "python_version": sys.version, "platform": platform.platform(),
                "architecture": platform.machine(), "watched_folder": self.root,
                "log_folder": str(self.output),
                "settings": {key: str(value) if isinstance(value, Path) else value
                             for key, value in vars(self.args).items()},
                "ffprobe_path": self.ffprobe_path, "ffprobe_version": ffprobe_version,
                "lsof_version": lsof_version,
                "filesystem_type": subprocess_version(["stat", "-f", "%T", self.root]) if sys.platform == "darwin" else None,
                "timestamp_note": "Wall clock has nanosecond formatting; observation accuracy is limited by scan timing and OS timestamps.",
                "filesystem_note": "st_ctime is metadata change time on macOS; birthtime may be converted from floating point."}

    def excluded(self, path: str) -> bool:
        if path == str(self.output) or path.startswith(str(self.output) + os.sep):
            return True
        relative = os.path.relpath(path, self.root)
        if os.path.basename(path) == ".DS_Store":
            return True
        return any(Path(relative).match(pattern) or Path(path).match(pattern) for pattern in self.args.exclude)

    def scan(self) -> tuple[dict[str, dict], list[dict]]:
        found: dict[str, dict] = {}
        problems = []
        pending = [self.root]
        while pending:
            folder = pending.pop()
            if self.excluded(folder):
                continue
            try:
                found[folder] = inspect(folder, self.root)
                with os.scandir(folder) as entries:
                    children = list(entries)
                found[folder]["entry_count"] = len(children)
            except OSError as exc:
                problems.append({"path": folder, "error": str(exc)})
                continue
            for entry in children:
                if self.excluded(entry.path):
                    continue
                try:
                    if entry.is_dir(follow_symlinks=False) and self.args.recursive:
                        pending.append(entry.path)
                    else:
                        found[entry.path] = inspect(entry.path, self.root)
                        if entry.is_dir(follow_symlinks=False):
                            try:
                                with os.scandir(entry.path) as subentries:
                                    found[entry.path]["entry_count"] = sum(1 for _ in subentries)
                            except OSError as exc:
                                found[entry.path]["entry_count_error"] = str(exc)
                except OSError as exc:
                    problems.append({"path": entry.path, "error": str(exc)})
        return found, problems

    def update_summary(self, row: dict, when: dict, previous: dict | None, process: list[dict]) -> None:
        key = identity(row)
        summary = self.summaries.get(key)
        if summary is None:
            summary = {"identity": key, "device": row["device"], "inode": row["inode"],
                       "object_type": row["object_type"], "first_observation": when,
                       "original_path": row["path"], "initial_size": row["size"],
                       "birthtime_ns": row["birthtime_ns"], "samples": 0,
                       "changing_samples": 0, "unchanged_samples": 0,
                       "total_positive_growth": 0, "peak_bytes_per_second": 0.0,
                       "write_intervals_ns": [], "longest_pause_ns": 0,
                       "write_bursts": [], "pauses": [], "active_burst_start_ns": None,
                       "active_pause_start_ns": None, "replacements": [],
                       "processes": [], "xattr_changes": 0, "permission_changes": 0,
                       "ffprobe_timeline": [], "rename_history": [], "observed_xattrs": set()}
            self.summaries[key] = summary
        summary["samples"] += 1
        summary["last_observation"] = when
        summary["final_path"] = row["path"]
        summary["final_size"] = row["size"]
        summary["observed_xattrs"].update(row["xattrs"])
        summary["processes"].extend(p for p in process if p not in summary["processes"])
        self.path_history[key].add(row["path"])
        if previous and previous["identity"] == key:
            delta = row["size"] - previous["size"]
            elapsed = when["monotonic_ns"] - previous["observation_monotonic_ns"]
            if delta:
                summary["changing_samples"] += 1
                if delta > 0:
                    if summary["active_pause_start_ns"] is not None:
                        summary["pauses"].append(when["monotonic_ns"] - summary["active_pause_start_ns"])
                        summary["active_pause_start_ns"] = None
                    if summary["active_burst_start_ns"] is None:
                        summary["active_burst_start_ns"] = previous["observation_monotonic_ns"]
                    summary["total_positive_growth"] += delta
                    if elapsed > 0:
                        rate = delta * 1e9 / elapsed
                        summary["peak_bytes_per_second"] = max(summary["peak_bytes_per_second"], rate)
                        summary["write_intervals_ns"].append(elapsed)
                    summary["last_growth_monotonic_ns"] = when["monotonic_ns"]
            else:
                summary["unchanged_samples"] += 1
                if summary["active_burst_start_ns"] is not None:
                    summary["write_bursts"].append(previous["observation_monotonic_ns"] - summary["active_burst_start_ns"])
                    summary["active_burst_start_ns"] = None
                    summary["active_pause_start_ns"] = previous["observation_monotonic_ns"]
                last = summary.get("last_growth_monotonic_ns", summary["first_observation"]["monotonic_ns"])
                summary["longest_pause_ns"] = max(summary["longest_pause_ns"], when["monotonic_ns"] - last)
            if row["xattrs"] != previous["xattrs"]:
                summary["xattr_changes"] += 1
            if row["permissions"] != previous["permissions"]:
                summary["permission_changes"] += 1

    def compare(self, path: str, row: dict, old: dict | None, when: dict, ref: str) -> None:
        if old is None:
            self.logs.event("DIRECTORY_APPEARED" if row["object_type"] == "directory" else "FILE_APPEARED",
                            when, path, [ref], identity=row["identity"], size=row["size"])
            return
        old_ref = old["observation_id"]
        refs = [old_ref, ref]
        if row["identity"] != old["identity"]:
            self.logs.event("INODE_CHANGED", when, path, refs,
                            previous_identity=old["identity"], identity=row["identity"])
        for field, event in (("size", "SIZE_CHANGED"), ("mtime_ns", "MTIME_CHANGED"),
                             ("ctime_ns", "CTIME_CHANGED"), ("xattrs", "XATTR_CHANGED"),
                             ("permissions", "PERMISSIONS_CHANGED"), ("entry_count", "ENTRY_COUNT_CHANGED")):
            if row.get(field) != old.get(field):
                details = {"before": old.get(field), "after": row.get(field)}
                if field == "size":
                    delta = row["size"] - old["size"]
                    elapsed = when["monotonic_ns"] - old["observation_monotonic_ns"]
                    details.update(delta_bytes=delta, elapsed_ns=elapsed,
                                   bytes_per_second=delta * 1e9 / elapsed if elapsed > 0 else None)
                self.logs.event(event, when, path, refs, **details)
                if field == "size":
                    self.logs.event("SIZE_INCREASED" if delta > 0 else "SIZE_DECREASED", when, path, refs,
                                    delta_bytes=delta)

    def process_worker(self) -> None:
        previous: dict[str, list[dict]] = {}
        index = 0
        while not self.stop.is_set():
            began = time.monotonic()
            when = clock(self.start_ns)
            state, error = lsof_observation(self.root, max(0.5, self.args.process_poll_interval * 3))
            index += 1
            ref = f"process:{index}"
            self.logs.write("raw.jsonl", {"type": "process_observation", "observation_id": ref,
                                           **when, "source": "lsof", "duration_ns": int((time.monotonic() - began) * 1e9),
                                           "open_files": state, "error": error})
            if error:
                self.logs.event("LSOF_ERROR", when, None, [ref], error=error)
            else:
                state = {path: value for path, value in state.items() if not self.excluded(path)}
                for path in set(previous) | set(state):
                    before = {(p.get("pid"), p.get("file_descriptor")) for p in previous.get(path, [])}
                    after = {(p.get("pid"), p.get("file_descriptor")) for p in state.get(path, [])}
                    for proc in state.get(path, []):
                        if (proc.get("pid"), proc.get("file_descriptor")) in after - before:
                            self.logs.event("PROCESS_OPENED_FILE", when, path, [ref], process=proc)
                    for proc in previous.get(path, []):
                        if (proc.get("pid"), proc.get("file_descriptor")) in before - after:
                            self.logs.event("PROCESS_CLOSED_FILE", when, path, [ref], process=proc)
                with self.process_lock:
                    self.process_state, self.process_when, self.process_ref = state, when, ref
                previous = state
            self.stop.wait(max(0, self.args.process_poll_interval - (time.monotonic() - began)))

    def probe_worker(self) -> None:
        next_due: dict[str, float] = {}
        index = 0
        while not self.stop.is_set():
            with self.probe_lock:
                candidates = list(self.probe_candidates.items())
            now = time.monotonic()
            due = [(path, row) for path, row in candidates if next_due.get(path, 0) <= now]
            if not due:
                self.stop.wait(min(0.1, self.args.ffprobe_interval))
                continue
            for path, row in due:
                if self.stop.is_set():
                    break
                next_due[path] = time.monotonic() + self.args.ffprobe_interval
                command = [self.ffprobe_path, "-v", "error", "-print_format", "json",
                           "-show_format", "-show_streams", "-show_error", path]
                when = clock(self.start_ns)
                began = time.monotonic_ns()
                try:
                    run = subprocess.run(command, capture_output=True, text=True, timeout=self.args.ffprobe_timeout)
                    parsed = json.loads(run.stdout) if run.stdout.strip() else {}
                    failure = None
                    success = run.returncode == 0 and bool(parsed.get("format") or parsed.get("streams"))
                    exit_status = run.returncode
                    stderr = run.stderr[:1000]
                except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
                    parsed, failure, success, exit_status, stderr = {}, str(exc), False, None, str(exc)
                index += 1
                ref = f"ffprobe:{index}"
                result = {"type": "ffprobe_observation", "observation_id": ref, **when,
                          "path": path, "identity": row["identity"], "size_at_last_snapshot": row["size"],
                          "snapshot_ref": row["observation_id"], "command": command,
                          "duration_ns": time.monotonic_ns() - began, "exit_status": exit_status,
                          "success": success, "stderr": stderr, "error": failure,
                          "format": parsed.get("format"), "streams": parsed.get("streams"),
                          "probe_error": parsed.get("error")}
                self.logs.write("raw.jsonl", result)
                previous = self.probe_previous.get(row["identity"])
                if not success:
                    self.logs.event("FFPROBE_FAILED", when, path, [row["observation_id"], ref],
                                    exit_status=exit_status, stderr=stderr)
                elif not previous or not previous["success"]:
                    self.logs.event("FFPROBE_BECAME_READABLE", when, path, [row["observation_id"], ref],
                                    format_name=(parsed.get("format") or {}).get("format_name"))
                elif result["format"] != previous["format"] or result["streams"] != previous["streams"]:
                    self.logs.event("FFPROBE_METADATA_CHANGED", when, path, [previous["observation_id"], ref])
                self.probe_previous[row["identity"]] = result
                summary = self.summaries.get(row["identity"])
                if summary is not None:
                    summary["ffprobe_timeline"].append({"observation_id": ref, "when": when,
                                                         "success": success, "format": result["format"],
                                                         "streams": result["streams"]})

    def run(self) -> None:
        metadata = self.metadata()
        self.start_ns = time.monotonic_ns()
        metadata.update(clock(self.start_ns))
        self.logs.write("raw.jsonl", metadata)
        (self.output / "session.json").write_text(json.dumps({"session_id": self.session_id, **metadata}, indent=2), encoding="utf-8")
        if not self.args.no_lsof and shutil.which("lsof"):
            self.threads.append(threading.Thread(target=self.process_worker, name="lsof", daemon=True))
        if self.ffprobe_path:
            self.threads.append(threading.Thread(target=self.probe_worker, name="ffprobe", daemon=True))
        for worker in self.threads:
            worker.start()
        if self.args.duration is None and sys.stdin.isatty():
            def stop_on_return() -> None:
                try:
                    input("Recording. Press Enter to STOP and save summary...\n")
                    self.stop.set()
                except EOFError:
                    pass
            threading.Thread(target=stop_on_return, name="stop-control", daemon=True).start()
        else:
            print("Recording. Press Control-C to stop.")
        deadline = time.monotonic() + self.args.duration if self.args.duration else None
        intended_ns = int(self.args.poll_interval * 1e9)
        next_cycle = time.monotonic_ns()
        last_start = None
        try:
            while not self.stop.is_set() and (deadline is None or time.monotonic() < deadline):
                now_ns = time.monotonic_ns()
                if now_ns < next_cycle:
                    self.stop.wait((next_cycle - now_ns) / 1e9)
                    if self.stop.is_set():
                        break
                start_ns = time.monotonic_ns()
                when = clock(self.start_ns)
                self.cycles += 1
                cycle = self.cycles
                actual_ns = start_ns - last_start if last_start is not None else None
                if actual_ns is not None:
                    self.intervals_ns.append(actual_ns)
                if start_ns > next_cycle + intended_ns:
                    self.late_cycles += 1
                found, problems = self.scan()
                with self.process_lock:
                    processes, process_when, process_ref = self.process_state, self.process_when, self.process_ref
                old_paths = self.previous
                old_by_id: dict[str, list[dict]] = collections.defaultdict(list)
                for old in old_paths.values():
                    old_by_id[old["identity"]].append(old)
                current_by_id: dict[str, list[dict]] = collections.defaultdict(list)
                for index, (path, row) in enumerate(found.items()):
                    ref = f"fs:{cycle}:{index}"
                    row["observation_id"] = ref
                    row["observation_monotonic_ns"] = when["monotonic_ns"]
                    current_by_id[row["identity"]].append(row)
                    self.logs.write("raw.jsonl", {"type": "snapshot", **when, "cycle": cycle,
                                                   **row, "open_processes": processes.get(path, []),
                                                   "process_observation_ref": process_ref,
                                                   "process_observation_time": process_when})
                    old = old_paths.get(path)
                    self.compare(path, row, old, when, ref)
                    self.update_summary(row, when, old, processes.get(path, []))
                    if old and old["identity"] != row["identity"]:
                        replacement = {"when": when, "path": path,
                                       "old_identity": old["identity"], "new_identity": row["identity"]}
                        self.summaries[old["identity"]]["replacements"].append(replacement)
                        self.summaries[row["identity"]]["replacements"].append(replacement)
                for path, old in old_paths.items():
                    if path not in found:
                        self.logs.event("DIRECTORY_DISAPPEARED" if old["object_type"] == "directory" else "FILE_DISAPPEARED",
                                        when, path, [old["observation_id"]], identity=old["identity"])
                for key in set(old_by_id) & set(current_by_id):
                    old_names = {r["path"] for r in old_by_id[key]}
                    new_names = {r["path"] for r in current_by_id[key]}
                    if old_names - new_names and new_names - old_names:
                        for former in old_names - new_names:
                            for newer in new_names - old_names:
                                before = next(r for r in old_by_id[key] if r["path"] == former)
                                after = next(r for r in current_by_id[key] if r["path"] == newer)
                                self.logs.event("PROBABLE_RENAME", when, newer,
                                                [before["observation_id"], after["observation_id"]],
                                                previous_path=former, identity=key)
                                self.logs.event("PATH_CHANGED", when, newer,
                                                [before["observation_id"], after["observation_id"]],
                                                previous_path=former, identity=key)
                                self.summaries[key]["rename_history"].append({"when": when, "from": former, "to": newer})
                with self.probe_lock:
                    self.probe_candidates = {p: r for p, r in found.items()
                                             if r["object_type"] == "file" and r["extension"] in MEDIA_EXTENSIONS}
                self.previous = found
                end_ns = time.monotonic_ns()
                scan_duration = end_ns - start_ns
                self.scan_ns.append(scan_duration)
                self.errors += len(problems)
                self.logs.write("raw.jsonl", {"type": "cycle", "cycle": cycle, **when,
                                               "cycle_end": clock(self.start_ns),
                                               "intended_interval_ns": intended_ns,
                                               "actual_interval_ns": actual_ns,
                                               "scan_duration_ns": scan_duration,
                                               "objects_inspected": len(found), "errors": problems})
                if scan_duration > intended_ns and cycle % max(1, int(5 / self.args.poll_interval)) == 0:
                    print(f"Warning: scanning takes {scan_duration / 1e6:.1f} ms; requested interval is {intended_ns / 1e6:.1f} ms.", file=sys.stderr)
                last_start = start_ns
                next_cycle += intended_ns
                if next_cycle < end_ns:
                    next_cycle = end_ns
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            for worker in self.threads:
                worker.join(timeout=self.args.ffprobe_timeout + 2)
            self.finish()

    def finish(self) -> None:
        def metrics(samples: list[int]) -> dict:
            if not samples:
                return {"count": 0}
            ordered = sorted(samples)
            return {"count": len(samples), "minimum_ns": ordered[0],
                    "median_ns": int(statistics.median(ordered)),
                    "p95_ns": ordered[min(len(ordered) - 1, int((len(ordered) - 1) * .95))],
                    "maximum_ns": ordered[-1], "average_ns": int(statistics.mean(ordered))}
        objects = []
        for key, summary in self.summaries.items():
            intervals = summary.pop("write_intervals_ns")
            burst_start = summary.pop("active_burst_start_ns")
            summary.pop("active_pause_start_ns")
            if burst_start is not None:
                summary["write_bursts"].append(summary["last_observation"]["monotonic_ns"] - burst_start)
            summary["write_burst_durations_ns"] = summary.pop("write_bursts")
            summary["pause_durations_ns"] = summary.pop("pauses")
            summary["zero_growth_samples"] = summary["unchanged_samples"]
            summary["observed_xattrs"] = sorted(summary["observed_xattrs"])
            summary["all_observed_paths"] = sorted(self.path_history[key])
            summary["total_growth"] = summary["final_size"] - summary["initial_size"]
            elapsed = summary["last_observation"]["monotonic_ns"] - summary["first_observation"]["monotonic_ns"]
            summary["average_net_bytes_per_second"] = summary["total_growth"] * 1e9 / elapsed if elapsed > 0 else None
            summary["shortest_observed_write_interval_ns"] = min(intervals) if intervals else None
            summary["final_stable_period_ns"] = (summary["last_observation"]["monotonic_ns"] - summary.get("last_growth_monotonic_ns", summary["first_observation"]["monotonic_ns"]))
            timeline = summary["ffprobe_timeline"]
            summary["first_successful_ffprobe"] = next((item for item in timeline if item["success"]), None)
            summary["last_media_metadata"] = next((item for item in reversed(timeline) if item["success"]), None)
            objects.append(summary)
        ending = clock(self.start_ns)
        report = {"session_id": self.session_id, "ended": ending,
                  "cycles": self.cycles, "late_cycles": self.late_cycles,
                  "scan_errors": self.errors, "actual_sampling_intervals": metrics(self.intervals_ns),
                  "scan_durations": metrics(self.scan_ns), "objects": objects,
                  "interpretation": "Observed stability, process closes, and ffprobe success do not prove download completion."}
        (self.output / "summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
        self.logs.write("raw.jsonl", {"type": "session_end", **ending, "cycles": self.cycles})
        self.logs.close()
        print(f"\nStopped. Logs and summary: {self.output}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Record filesystem, process, and ffprobe observations for FILLR.")
    parser.add_argument("folder", nargs="?", help="Folder to watch; omit for a macOS folder picker")
    parser.add_argument("--poll-interval", type=float, default=0.05, help="Filesystem sample interval in seconds (default: 0.05)")
    parser.add_argument("--process-poll-interval", type=float, default=0.25, help="lsof interval in seconds (default: 0.25)")
    parser.add_argument("--ffprobe-interval", type=float, default=1.0, help="Per-media-file ffprobe interval in seconds (default: 1.0)")
    parser.add_argument("--ffprobe-timeout", type=float, default=5.0, help="Maximum seconds per ffprobe attempt (default: 5)")
    parser.add_argument("--recursive", action=argparse.BooleanOptionalAction, default=True, help="Scan subfolders (default: on)")
    parser.add_argument("--log-directory", type=Path, help="Parent directory for a new session log folder")
    parser.add_argument("--exclude", action="append", default=[], metavar="GLOB", help="Exclude matching relative path; repeatable")
    parser.add_argument("--no-ffprobe", action="store_true", help="Disable media probes")
    parser.add_argument("--no-lsof", action="store_true", help="Disable process/open-file samples")
    parser.add_argument("--verbose", action="store_true", help="Print session details")
    parser.add_argument("--duration", type=float, help="Stop automatically after N seconds (useful for controlled runs)")
    parser.add_argument("--no-prompt", action="store_true", help="Start immediately and stop with Control-C")
    args = parser.parse_args()
    for name in ("poll_interval", "process_poll_interval", "ffprobe_interval", "ffprobe_timeout"):
        if getattr(args, name) <= 0:
            parser.error(f"--{name.replace('_', '-')} must be positive")
    if args.duration is not None and args.duration <= 0:
        parser.error("--duration must be positive")
    selected = args.folder or choose_folder()
    if not selected:
        print("No folder selected.")
        return 0
    root = os.path.realpath(os.path.expanduser(selected))
    if not os.path.isdir(root):
        parser.error(f"Not a folder: {root}")
    base = (args.log_directory or Path.home() / "Documents" / "FILLR Monitor Logs").expanduser().resolve()
    output = base / (dt.datetime.now().strftime("%Y-%m-%d_%H-%M-%S") + "_" + uuid.uuid4().hex[:8])
    if root.startswith(str(output) + os.sep):
        parser.error("The watched folder cannot be inside the new log folder")
    print(f"Watch: {root}\nLogs:  {output}")
    if not args.no_prompt and args.duration is None:
        try:
            input("Press Enter to START recording (or Control-C to cancel)...")
        except (KeyboardInterrupt, EOFError):
            print("Canceled.")
            return 0
    output.mkdir(parents=True, exist_ok=False)
    recorder = Recorder(args, root, output)
    if args.verbose:
        print(f"Session ID: {recorder.session_id}; ffprobe: {recorder.ffprobe_path or 'unavailable/disabled'}")
    recorder.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
