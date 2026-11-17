#!/usr/bin/env python3
"""Resumable, verified Compressor conversion of the three explicit ProRes copies.

Only MPEG-2 copies in the named experiment folders can be deleted. A successful
Compressor job, complete output validation and unchanged identities/checksums
are required first. The canonical MPEG-2 tree is always retained.
"""
import argparse
import fcntl
from concurrent.futures import ThreadPoolExecutor, as_completed
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid

BASE = "Chabot News Comps 2026-11-09_231235"
COMPRESSOR = Path("/Applications/Compressor.app/Contents/MacOS/Compressor")
PRESETS = Path("/Applications/Compressor.app/Contents/PlugIns/Compressor/CompressorKit.bundle/Contents/Frameworks/Compressor.framework/Versions/A/Frameworks/StompUI.framework/Versions/A/Resources/BuiltInSettings/ProRes")
PROFILES = {
    "422": {"folder": BASE + " ProRes 422", "preset": "proRes422Name.compressorsetting", "tag": "apcn", "profile": "Standard"},
    "lt": {"folder": BASE + " ProRes422 LT", "preset": "proRes422LTName.compressorsetting", "tag": "apcs", "profile": "LT"},
    "proxy": {"folder": BASE + " ProRes422 Proxy", "preset": "proRes422ProxyName.compressorsetting", "tag": "apco", "profile": "Proxy"},
}


class FrameCountMismatch(ValueError):
    """Only this exact validation failure is eligible for timestamp repair."""


class CompressorBatchFailed(RuntimeError):
    def __init__(self, batch_status):
        self.batch_status = batch_status
        super().__init__(f"Compressor batch ended unsuccessfully: {batch_status.get('status')}")


def ensure_compressor_app():
    # A regular LaunchServices owner keeps the background controller alive
    # after short-lived CLI submission/monitor processes exit. This changes no
    # presets, concurrency preferences, or queue history.
    subprocess.run(["open", "-g", "-a", str(COMPRESSOR.parents[2])], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def sha256(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def _no_symlinks(path):
    path = Path(os.path.abspath(path))
    for component in reversed((path,) + tuple(path.parents)):
        if component.is_symlink():
            raise ValueError(f"Symlink is not allowed: {component}")
    return path


def ensure_member(root, path):
    root, path = _no_symlinks(root), _no_symlinks(path)
    if path == root or root not in path.parents:
        raise ValueError(f"Path is outside the permitted experiment folder: {path}")
    return path


def guard_profile_root(repo, profile, root):
    if profile not in PROFILES:
        raise ValueError("Unknown ProRes profile")
    expected = Path(os.path.abspath(repo)) / "CNN Downloads" / PROFILES[profile]["folder"]
    root = _no_symlinks(root)
    if root != expected or not root.is_dir():
        raise ValueError(f"Only the explicit {profile} copy is permitted: {expected}")
    return root


def identity(path):
    path = _no_symlinks(path)
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode):
        raise ValueError(f"Expected a regular file: {path}")
    return {"device": value.st_dev, "inode": value.st_ino, "bytes": value.st_size,
            "mtime_ns": value.st_mtime_ns, "link_count": value.st_nlink}


def _probe(path, ffprobe="ffprobe", count=True):
    command = [ffprobe, "-v", "error", "-threads", "2", "-select_streams", "v:0"]
    if count:
        command += ["-count_frames"]
    command += ["-show_streams", "-show_format", "-of", "json", str(path)]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    if result.stderr.strip():
        raise RuntimeError(f"Probe reported decode errors for {path}: {result.stderr[-2000:]}")
    value = json.loads(result.stdout)
    streams = value.get("streams", [])
    if len(streams) != 1 or streams[0].get("codec_type") != "video":
        raise RuntimeError(f"Expected one selected video stream: {path}")
    return streams[0]


def _field_flags(path, ffprobe="ffprobe"):
    command = [ffprobe, "-v", "error", "-threads", "2", "-select_streams", "v:0",
               "-read_intervals", "%+#4", "-show_frames", "-show_entries",
               "frame=interlaced_frame,top_field_first", "-of", "json", str(path)]
    value = json.loads(subprocess.check_output(command, text=True))
    frames = value.get("frames", [])
    if not frames:
        raise RuntimeError(f"No decoded field flags: {path}")
    return {key: int(frames[0].get(key, 0)) for key in ("interlaced_frame", "top_field_first")}


def source_metadata(path, ffprobe="ffprobe", count=True):
    value = _probe(path, ffprobe, count=count)
    if value.get("codec_name") != "mpeg2video":
        raise ValueError(f"Input is not MPEG-2: {path}")
    if count and int(value.get("nb_read_frames", 0)) < 1:
        raise ValueError(f"Source has no complete decoded frames: {path}")
    value["decoded_field_flags"] = _field_flags(path, ffprobe)
    return value


def verify_output(source_metadata, output, profile, log, ffprobe="ffprobe", ffmpeg="ffmpeg"):
    output = Path(output)
    identity(output)
    value = _probe(output, ffprobe, count=False)
    expected = PROFILES[profile]
    for key, target in {"codec_name": "prores", "profile": expected["profile"],
                        "codec_tag_string": expected["tag"], "pix_fmt": "yuv422p10le",
                        "width": source_metadata["width"], "height": source_metadata["height"]}.items():
        if value.get(key) != target:
            raise ValueError(f"{output}: {key}: expected {target}, got {value.get(key)}")
    for key in ("r_frame_rate", "avg_frame_rate"):
        if Fraction(value[key]) != Fraction(source_metadata[key]):
            raise ValueError(f"{output}: source/output {key} differs")
    for key in ("sample_aspect_ratio", "color_space", "color_transfer", "color_primaries", "color_range"):
        source_value = source_metadata.get(key)
        if source_value and source_value not in ("unknown", "unspecified", "N/A") and value.get(key) != source_value:
            raise ValueError(f"{output}: source/output {key} differs")
    expected_frames = int(source_metadata["nb_read_frames"])
    if int(value.get("nb_frames", 0)) != expected_frames:
        raise FrameCountMismatch(f"{output}: output frame count differs from the complete source")
    duration = float(Fraction(expected_frames) / Fraction(value["avg_frame_rate"]))
    if abs(float(value.get("duration", 0)) - duration) > .00002:
        raise ValueError(f"{output}: output duration differs from exact frame count")
    fields = _field_flags(output, ffprobe)
    if fields != source_metadata.get("decoded_field_flags", fields):
        raise ValueError(f"{output}: decoded interlacing/parity changed")
    value["decoded_field_flags"] = fields
    command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-xerror", "-nostdin",
               "-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld", "-threads", "1",
               "-i", str(output), "-map", "0:v:0", "-an", "-progress", "pipe:1", "-f", "null", "-"]
    with Path(log).open("w") as stream:
        decoded = subprocess.run(command, stdout=subprocess.PIPE, stderr=stream, text=True, check=True)
    if Path(log).stat().st_size:
        raise RuntimeError(f"Full decode reported errors: {log}")
    decoded_counts = [int(line.split("=", 1)[1]) for line in decoded.stdout.splitlines() if line.startswith("frame=")]
    if not decoded_counts or decoded_counts[-1] != expected_frames or "progress=end" not in decoded.stdout:
        raise FrameCountMismatch(f"{output}: full decoded frame count differs from the complete source")
    Path(str(log) + ".progress").write_text(decoded.stdout)
    value["nb_read_frames"] = str(decoded_counts[-1])
    value["full_decode_check"] = "passed"
    return value


def delete_verified_source(root, entry):
    source = ensure_member(root, Path(entry["source"]))
    output = ensure_member(root, Path(entry["output"]))
    canonical = _no_symlinks(Path(entry["canonical"]))
    if (entry.get("status") != "verified" or entry.get("compressor_status") != "Successful" or
            entry.get("output_metadata", {}).get("full_decode_check") != "passed"):
        raise ValueError("Refusing to delete a source without complete successful verification")
    if source.suffix.lower() not in (".mpg", ".mpeg", ".m2v", ".m2t", ".m2ts") or output != source.with_suffix(".mov"):
        raise ValueError("Unexpected source/output filename pairing")
    if canonical == source or root == canonical or Path(root) in canonical.parents:
        raise ValueError("The retained canonical source must be outside this experiment copy")
    source_id, output_id, canonical_id = identity(source), identity(output), identity(canonical)
    if source_id != entry["source_identity"] or output_id != entry["output_identity"]:
        raise ValueError("Source or verified output changed before deletion")
    if source_id["link_count"] != 1 or (source_id["device"], source_id["inode"]) == (canonical_id["device"], canonical_id["inode"]):
        raise ValueError("Refusing to delete a hardlinked or canonical source")
    if sha256(source) != entry["source_sha256"] or sha256(output) != entry["output_sha256"]:
        raise ValueError("Source or output checksum changed before deletion")
    # The original canonical MPEG remains as an identical retained reference.
    if sha256(canonical) != entry["source_sha256"]:
        raise ValueError("Retained canonical MPEG differs from the experiment source")
    if identity(source) != source_id or identity(output) != output_id or identity(canonical) != canonical_id:
        raise ValueError("Files changed while checksums were being checked")
    source.unlink()


def _receipt(path):
    try:
        value = json.loads(Path(path).read_text())
        batch = value["batch"]
        if not isinstance(batch.get("batchID"), str) or not batch["batchID"]:
            return None
        return batch
    except (OSError, ValueError, KeyError, TypeError):
        return None


def validate_journal_plan(journal, folder, root, canonical_root):
    expected = {item["relative_path"]: item for item in folder["files"]}
    if len(expected) != len(folder["files"]) or set(journal.get("entries", {})) != set(expected):
        raise ValueError("Journal entry set differs from the original complete inventory")
    for relative, entry in journal["entries"].items():
        source = ensure_member(root, Path(root) / relative)
        canonical = ensure_member(canonical_root, Path(canonical_root) / relative)
        item = expected[relative]
        if (entry.get("source") != str(source) or entry.get("output") != str(source.with_suffix(".mov")) or
                entry.get("canonical") != str(canonical) or str(source) != item["path"] or
                str(canonical) != item["canonical_path"]):
            raise ValueError("Journal source/output/canonical paths differ from the original inventory")
        target_id = {"device": item["device"], "inode": item["inode"], "bytes": item["bytes"]}
        if entry.get("inventory_identity") != target_id:
            raise ValueError("Journal initial identity differs from the original inventory")


def _monitor(batch_id, directory, timeout_seconds):
    ensure_compressor_app()
    started = time.monotonic()
    while True:
        command = [str(COMPRESSOR), "-monitor", "-batchid", batch_id,
                   "-outputformat", "json", "-once", "-timeout", "5"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        (directory / f"{batch_id}-monitor-latest.stdout").write_text(result.stdout)
        (directory / f"{batch_id}-monitor-latest.stderr").write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"Compressor monitor failed: {result.stderr}")
        try:
            rows = json.loads(result.stdout)
        except ValueError:
            rows = []
        for row in rows if isinstance(rows, list) else []:
            status = row.get("batchStatus", {})
            if status.get("batchid") != batch_id:
                continue
            label = status.get("status", "")
            if label == "Successful":
                jobs = status.get("jobs", [])
                if not jobs or any(job.get("jobStatus", {}).get("status") != "Successful" for job in jobs):
                    raise RuntimeError("Batch success did not include success for every job")
                return status
            if any(word in label.lower() for word in ("failed", "cancel", "error")):
                raise CompressorBatchFailed(status)
        if time.monotonic() - started > timeout_seconds:
            raise TimeoutError(f"Compressor batch is not successfully complete: {batch_id}")
        time.sleep(3)


def reconcile_failed_batch(journal, batch, batch_status, directory, save, unknown_job_ids=()):
    """Preserve a terminal controller failure and retry only its failed jobs.

    Successful children keep their genuine status and still require complete
    verification. Failed children are never relabeled successful. Their old
    partial output is retained before a new submission can use that filename.
    """
    if batch_status.get("batchid") != batch.get("batch_id") or not batch_status.get("status", "").lower().startswith("failed"):
        raise ValueError("Recovery requires the exact failed batch's terminal snapshot")
    received = batch.get("receipt", {}).get("jobs", [])
    keys = batch.get("entries", [])
    if len(received) != len(keys):
        raise ValueError("Cannot bind every failed-batch source to its submission job ID")
    outcomes = {x.get("jobStatus", {}).get("jobid"): x.get("jobStatus", {}) for x in batch_status.get("jobs", [])}
    if len(outcomes) != len(batch_status.get("jobs", [])):
        raise ValueError("Failed batch contains duplicate or ambiguous child records")
    ids = [x.get("jobID") for x in received]
    unknown_job_ids = set(unknown_job_ids)
    if (None in ids or len(set(ids)) != len(ids) or set(ids) - set(outcomes) != unknown_job_ids or
            set(outcomes) - set(ids)):
        raise ValueError("Failed batch job IDs are incomplete or ambiguous")
    if unknown_job_ids and not any("job controller down" in x.get("status", "").lower() for x in outcomes.values()):
        raise ValueError("Missing job statuses lack evidence of the diagnosed controller failure")
    if unknown_job_ids:
        command = batch.get("command", [])
        submitted_sources = [command[n+1] for n,x in enumerate(command[:-1]) if x == "-jobpath"]
        if submitted_sources != [journal["entries"][key]["source"] for key in keys]:
            raise ValueError("Cannot bind unknown child IDs to the exact original submitted source order")
    for key, job_id in zip(keys, ids):
        if job_id in unknown_job_ids:
            outcomes[job_id] = {"jobid": job_id, "batchid": batch["batch_id"],
                "name": Path(journal["entries"][key]["source"]).name,
                "status": "Unknown: omitted after job controller failure", "reported_by_compressor": False,
                "recovery_policy": "Preserve existing output and obtain a new successful job; never infer prior success"}
    for key, job_id in zip(keys, ids):
        entry, outcome = journal["entries"][key], outcomes[job_id]
        root = Path(journal["root"])
        source = ensure_member(root, Path(entry["source"]))
        output = ensure_member(root, Path(entry["output"]))
        if output != source.with_suffix(".mov"):
            raise ValueError("Recovery output is not the inventoried source's MOV path")
        source_before = identity(source)
        if source_before != entry["source_identity"] or sha256(source) != entry["source_sha256"] or identity(source) != source_before:
            raise ValueError("Source changed before failed-batch recovery")
        label = outcome.get("status", "")
        if outcome.get("name") != Path(entry["source"]).name:
            raise ValueError("Failed batch job name does not match its inventoried source")
        if label != "Successful" and job_id not in unknown_job_ids and "job controller down" not in label.lower():
            raise RuntimeError(f"Failed job is not the diagnosed controller-lifetime failure: {label}")
        if label != "Successful" and job_id not in unknown_job_ids and not label.lower().startswith("failed"):
            raise ValueError("A child job may still be active; refusing to retry or move its output")
        if (label != "Successful" and len(entry.get("backend_failures", [])) >= 2 and
                not any(x.get("job_id") == job_id for x in entry["backend_failures"])):
            raise RuntimeError("Repeated controller failures require a new diagnosis before another retry")
    batch.update(status="failed", failure_snapshot=batch_status, recovery_state="reconciling",
                 reconciled_job_outcomes=outcomes, unknown_job_ids=sorted(unknown_job_ids))
    save()
    for key, job_id in zip(keys, ids):
        entry, outcome = journal["entries"][key], outcomes[job_id]
        label = outcome["status"]
        if label == "Successful":
            entry.update(status="converted", compressor_status="Successful")
            save()
            continue
        history = entry.setdefault("backend_failures", [])
        previous = next((x for x in history if x["job_id"] == job_id), None)
        if previous is None:
            output = Path(entry["output"])
            archive_dir = Path(directory) / "backend-failures" / batch["batch_id"]
            ensure_member(directory, archive_dir)
            archive_dir.mkdir(parents=True, exist_ok=True)
            archive = archive_dir / (job_id + "-FAILED-PARTIAL.mov")
            previous = {"batch_id": batch["batch_id"], "job_id": job_id, "status": label,
                        "outcome": outcome, "archive_path": str(archive), "stage": "archive_pending",
                        "output_existed": output.exists(), "recorded_unix": time.time()}
            if output.exists():
                previous.update(output_identity=identity(output), output_sha256=sha256(output))
            history.append(previous)
            save()
        output, archive = Path(entry["output"]), Path(previous["archive_path"])
        ensure_member(directory, archive)
        if previous["stage"] == "archive_pending":
            if previous["output_existed"]:
                if output.exists():
                    if identity(output) != previous["output_identity"] or sha256(output) != previous["output_sha256"] or archive.exists():
                        raise ValueError("Failed output changed before its recorded archive operation")
                    output.rename(archive)
                if not archive.exists() or identity(archive) != previous["output_identity"] or sha256(archive) != previous["output_sha256"]:
                    raise ValueError("Cannot establish the archived failed output")
            elif output.exists() or archive.exists():
                raise ValueError("Unexpected output appeared after the terminal failed-job snapshot")
            previous["stage"] = "archived"
            entry.update(status="pending", compressor_status=label)
            save()
    batch["recovery_state"] = "reconciled"
    save()
    return {"successful": sum(x.get("status") == "Successful" for x in outcomes.values()),
            "retry_pending": sum(x.get("status") != "Successful" for x in outcomes.values())}


def video_packet_manifest(path, ffprobe="ffprobe"):
    """Hash every compressed video packet; timestamps are intentionally omitted."""
    command = [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_packets",
               "-show_data_hash", "sha256", "-show_entries", "packet=size,data_hash", "-of", "json", str(path)]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    if result.stderr.strip():
        raise ValueError("Video packet inspection reported an error")
    packets = json.loads(result.stdout).get("packets", [])
    if not packets or any(not p.get("data_hash", "").startswith("SHA256:") for p in packets):
        raise ValueError("Missing compressed video packet hashes")
    return {"count": len(packets), "sha256": hashlib.sha256(json.dumps(packets, sort_keys=True).encode()).hexdigest()}


def repair_frame_count(entry, profile, directory, journal, save, timeout_seconds):
    """Repair source timing without recoding video, then use the same preset.

    The original mismatched MOV is archived only after the replacement has
    passed all normal checks. Every submission/adoption stage is durable.
    """
    source, target = Path(entry["source"]), Path(entry["output"])
    directory = Path(directory)
    if entry.get("compressor_status") != "Successful" or not entry.get("frame_count_mismatch"):
        raise ValueError("Timestamp repair requires a successful job with a recorded frame-count mismatch")
    if identity(source) != entry["source_identity"] or sha256(source) != entry["source_sha256"]:
        raise ValueError("MPEG source changed before timestamp repair")
    work = directory / "timing-repairs" / hashlib.sha256(str(source).encode()).hexdigest()[:20]
    ensure_member(directory, work)
    work.mkdir(parents=True, exist_ok=True)
    paths = {"input_path": str(work / "source-streamcopy-genpts.mov"),
             "output_path": str(work / "repaired-prores.mov"),
             "archive_path": str(work / "original-frame-count-mismatch.mov"),
             "receipt_path": str(work / "compressor-submission.stdout")}
    preset = PRESETS / PROFILES[profile]["preset"]
    if "timing_repair" not in entry:
        entry["timing_repair"] = {**paths, "stage": "planned", "profile": profile,
            "source_sha256": entry["source_sha256"], "preset": str(preset), "preset_sha256": sha256(preset),
            "original_output_identity": identity(target), "original_output_sha256": sha256(target),
            "batch_name": f"FILLR_TIMING_REPAIR_{profile}_{uuid.uuid4().hex[:12]}", "started_unix": time.time()}
        save()
    repair = entry["timing_repair"]
    if (any(repair.get(k) != v for k,v in paths.items()) or repair.get("profile") != profile or
            repair.get("source_sha256") != entry["source_sha256"] or repair.get("preset_sha256") != sha256(preset)):
        raise ValueError("Timing repair journal identity/path changed")
    remux, replacement, archive, receipt = (Path(repair[k]) for k in ("input_path", "output_path", "archive_path", "receipt_path"))
    for path in (remux, replacement, archive, receipt): ensure_member(directory, path)
    if repair["stage"] == "planned":
        started = time.monotonic()
        command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-fflags", "+genpts",
                   "-i", str(source), "-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-video_track_timescale", "30000",
                   "-avoid_negative_ts", "disabled", "-shortest", "-movflags", "+faststart", str(remux)]
        repair["remux_command"] = command
        save()
        if not remux.exists():
            with (work / "remux.log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        original_packets = video_packet_manifest(source)
        repaired_packets = video_packet_manifest(remux)
        expected_frames = int(entry["source_metadata"]["nb_read_frames"])
        if original_packets != repaired_packets or original_packets["count"] != expected_frames:
            raise ValueError("Timestamp remux did not preserve every compressed video packet byte-for-byte")
        info = _probe(remux, count=False)
        if info.get("codec_name") != "mpeg2video" or int(info.get("nb_frames", 0)) != expected_frames:
            raise ValueError("Remux video frame count/codec differs from the complete MPEG source")
        repair.update(stage="remuxed", packet_proof=original_packets, input_metadata=info,
                      input_sha256=sha256(remux), input_identity=identity(remux), remux_seconds=time.monotonic()-started)
        journal["timing_repair_preparation_seconds"] = journal.get("timing_repair_preparation_seconds", 0) + repair["remux_seconds"]
        save()
    if repair["stage"] == "remuxed":
        if identity(remux) != repair["input_identity"] or sha256(remux) != repair["input_sha256"]:
            raise ValueError("Verified stream-copy remux changed before Compressor submission")
        if replacement.exists() or receipt.exists():
            raise FileExistsError("Untracked repair output/receipt exists; refusing to overwrite or resubmit")
        command = [str(COMPRESSOR), "-batchname", repair["batch_name"], "-outputformat", "json",
                   "-jobpath", str(remux), "-settingpath", str(preset), "-locationpath", str(replacement)]
        repair.update(stage="submitting", command=command)
        save()
        ensure_compressor_app()
        started = time.monotonic()
        with receipt.open("w") as stdout, receipt.with_suffix(".stderr").open("w") as stderr:
            result = subprocess.run(command, stdout=stdout, stderr=stderr)
        repair["submission_returncode"] = result.returncode
        journal["conversion_wait_seconds"] += time.monotonic() - started
        save()
        if result.returncode:
            raise RuntimeError("Compressor timing-repair submission failed; preserved receipt/logs require inspection")
    if repair["stage"] == "submitting":
        received = _receipt(receipt)
        if not received:
            raise RuntimeError("Timing repair has no unambiguous receipt; refusing duplicate submission")
        repair.update(stage="submitted", receipt=received, batch_id=received["batchID"])
        save()
    if repair["stage"] == "submitted":
        started = time.monotonic()
        monitor = _monitor(repair["batch_id"], work, timeout_seconds)
        journal["conversion_wait_seconds"] += time.monotonic() - started
        repair.update(stage="converted", monitor=monitor)
        save()
    if repair["stage"] == "converted":
        started = time.monotonic()
        before = identity(replacement)
        metadata = verify_output(entry["source_metadata"], replacement, profile, work / "repaired-full-decode.log")
        digest = sha256(replacement)
        if identity(replacement) != before:
            raise ValueError("Repaired ProRes changed during full verification")
        repair.update(stage="verified", output_metadata=metadata, output_identity=before, output_sha256=digest)
        journal["verification_wall_seconds"] += time.monotonic() - started
        save()
    if repair["stage"] in ("verified", "adopting"):
        repair["stage"] = "adopting"
        save()
        # Recover safely if interrupted between the two renames. Never replace
        # an existing file unless its prior durable identity/hash is recognized.
        if target.exists() and identity(target) == repair["original_output_identity"]:
            if sha256(target) != repair["original_output_sha256"] or archive.exists():
                raise ValueError("Original mismatched MOV changed or archive already exists")
            target.rename(archive)
        if not archive.exists() or identity(archive) != repair["original_output_identity"] or sha256(archive) != repair["original_output_sha256"]:
            raise ValueError("Cannot establish the preserved original mismatched MOV")
        if not target.exists():
            if identity(replacement) != repair["output_identity"] or sha256(replacement) != repair["output_sha256"]:
                raise ValueError("Verified replacement changed before adoption")
            replacement.rename(target)
        if identity(target) != repair["output_identity"] or sha256(target) != repair["output_sha256"]:
            raise ValueError("Unexpected output at the intended repaired MOV path")
        repair.update(stage="adopted", completed_unix=time.time())
        entry.update(status="verified", output_metadata=repair["output_metadata"], output_identity=identity(target),
                     output_sha256=repair["output_sha256"], verified_unix=time.time(), compressor_status="Successful")
        save()
    if repair["stage"] != "adopted":
        raise ValueError("Unknown timing repair stage")
    return entry["output_metadata"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--initial-receipt", type=Path)
    parser.add_argument("--chunk-size", type=int, default=16)
    parser.add_argument("--verify-workers", type=int, default=2)
    parser.add_argument("--batch-timeout", type=int, default=7200)
    parser.add_argument("--keep-mpeg", action="store_true", help="Verify conversions but keep experiment MPEG copies")
    parser.add_argument("--submit-only", action="store_true", help="Prepare and submit remaining complete sources; do not verify or delete yet")
    args = parser.parse_args(argv)
    if not 1 <= args.chunk_size <= 153 or not 1 <= args.verify_workers <= 4:
        parser.error("Chunk size must be1..153; verification workers1..4")
    repo = Path(__file__).resolve().parents[1]
    inventory = json.loads(args.inventory.read_text())
    canonical_root = _no_symlinks(repo / "CNN Downloads" / BASE)
    if Path(inventory["canonical_folder"]) != canonical_root:
        parser.error("Inventory canonical folder differs from the retained source tree")
    spec = PROFILES[args.profile]
    folder = next((f for f in inventory["folders"] if f["name"] == spec["folder"]), None)
    if not folder:
        parser.error("Inventory does not include this exact experiment folder")
    root = guard_profile_root(repo, args.profile, Path(folder["path"]))
    preset = PRESETS / spec["preset"]
    directory = args.state_dir.expanduser().absolute() / ("conversion-" + args.profile)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "converter.lock").open("a") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return run_conversion(args, repo, inventory, root, canonical_root, preset, directory, folder)


def run_conversion(args, repo, inventory, root, canonical_root, preset, directory, folder):
    journal_path = directory / "journal.json"
    if journal_path.exists():
        journal = json.loads(journal_path.read_text())
        if journal.get("profile") != args.profile or journal.get("root") != str(root):
            raise ValueError("Journal identity does not match this experiment")
        if journal.get("preset_sha256") != sha256(preset):
            raise ValueError("Compressor preset changed since this journal was created")
    else:
        journal = {"version": 1, "profile": args.profile, "root": str(root),
                   "canonical_root": str(canonical_root), "preset": str(preset),
                   "preset_sha256": sha256(preset), "status": "preparing", "entries": {},
                   "batches": [], "started_unix": time.time(), "source_preparation_seconds": 0,
                   "conversion_wait_seconds": 0, "verification_wall_seconds": 0, "deletion_wall_seconds": 0}
        for item in folder["files"]:
            relative = item["relative_path"]
            source = ensure_member(root, root / relative)
            canonical = ensure_member(canonical_root, canonical_root / relative)
            if source != Path(item["path"]) or canonical != Path(item["canonical_path"]):
                raise ValueError("Inventory relative and absolute source paths differ")
            journal["entries"][relative] = {"source": str(source), "output": str(source.with_suffix(".mov")),
                "canonical": str(canonical), "status": "pending", "inventory_identity": {
                    "device": item["device"], "inode": item["inode"], "bytes": item["bytes"]}}
        write_json(journal_path, journal)
    validate_journal_plan(journal, folder, root, canonical_root)
    save = lambda: write_json(journal_path, journal)
    all_sources = set(entry["source"] for entry in journal["entries"].values())
    for path in root.rglob("*"):
        ensure_member(root, path)
        if path.is_file() and path.suffix.lower() in (".mpg", ".mpeg", ".m2v", ".m2t", ".m2ts") and str(path) not in all_sources:
            raise ValueError(f"Uninventoried MPEG file in target folder: {path}")
    try:
        # Adopt only the specifically recorded first complete-source conversion.
        if args.initial_receipt:
            initial = json.loads(args.initial_receipt.read_text())
            entry = next((e for e in journal["entries"].values() if e["source"] == initial["source"]), None)
            if not entry or entry["output"] != initial["output"] or initial["preset"] != str(preset):
                raise ValueError("Initial receipt does not belong to this exact profile/source")
            if entry["status"] == "pending":
                if identity(entry["source"]) != {**initial["source_stat"], "link_count": 1} or sha256(entry["source"]) != initial["source_sha256"]:
                    raise ValueError("Initial source changed after its conversion was submitted")
                batch = json.loads(initial["stdout"])["batch"]
                entry.update(status="submitted", batch_id=batch["batchID"], source_identity=identity(entry["source"]),
                             source_sha256=initial["source_sha256"], source_metadata=source_metadata(entry["source"], count=False))
                journal["batches"].append({"batch_id": batch["batchID"], "entries": [next(k for k,e in journal["entries"].items() if e is entry)],
                    "status": "submitted", "imported_receipt": str(args.initial_receipt), "started_unix": initial["started_unix"]})
                save()
        for entry in journal["entries"].values():
            if entry["status"] in ("deleted", "verified"):
                if identity(entry["output"]) != entry["output_identity"]:
                    raise ValueError("Previously verified output changed")
                if sha256(entry["output"]) != entry["output_sha256"]:
                    raise ValueError("Previously verified output checksum changed")
                if entry["status"] == "deleted" and Path(entry["source"]).exists():
                    raise ValueError("A deleted MPEG source reappeared")
                if entry["status"] == "verified" and not Path(entry["source"]).exists():
                    if not entry.get("deletion_intent_unix") or identity(entry["output"]) != entry["output_identity"]:
                        raise ValueError("Verified source disappeared without a durable deletion intent")
                    if sha256(entry["canonical"]) != entry["source_sha256"] or sha256(entry["output"]) != entry["output_sha256"]:
                        raise ValueError("Interrupted deletion recovery checksums differ")
                    entry.update(status="deleted", recovered_absent_source=True, deleted_unix=time.time())
                    save()
                continue
            source = Path(entry["source"])
            ident = identity(source)
            if any(ident[k] != v for k,v in entry["inventory_identity"].items()) or ident["link_count"] != 1:
                raise ValueError(f"Inventoried source identity changed: {source}")
            if "source_identity" not in entry:
                started = time.monotonic()
                entry.update(source_identity=ident, source_sha256=sha256(source), source_metadata=source_metadata(source, count=False))
                if identity(source) != ident:
                    raise ValueError("Source changed during preflight")
                journal["source_preparation_seconds"] += time.monotonic() - started
                save()
            elif ident != entry["source_identity"]:
                raise ValueError("Source changed since preparation")
        # A repair may have archived the original MOV and been interrupted
        # before moving the verified replacement into its normal path. Resume
        # from its durable stage before the ordinary output validation loop.
        if not args.submit_only:
            for entry in journal["entries"].values():
                repair = entry.get("timing_repair")
                if repair and repair.get("stage") != "adopted":
                    repair_frame_count(entry, args.profile, directory, journal, save, args.batch_timeout)
        if args.submit_only and not any(e["status"] == "pending" for e in journal["entries"].values()):
            print(f"{args.profile}: no unsubmitted sources remain", flush=True)
            return 0
        while True:
            pending = [(k,e) for k,e in journal["entries"].items() if e["status"] == "pending"]
            active = None if args.submit_only else next((b for b in journal["batches"]
                if b["status"] not in ("successful", "not_submitted") and b.get("recovery_state") != "reconciled"), None)
            if not active and pending:
                selected = pending[:args.chunk_size]
                key = str(uuid.uuid4())
                receipt = directory / f"{key}-submission.stdout"
                command = [str(COMPRESSOR), "-batchname", f"FILLR_PRORES_{args.profile}_{key[:8]}", "-outputformat", "json"]
                for _, entry in selected:
                    ensure_member(root, entry["output"])
                    if Path(entry["output"]).exists():
                        raise FileExistsError(f"Untracked output exists; refusing to overwrite: {entry['output']}")
                    command += ["-jobpath", entry["source"], "-settingpath", str(preset), "-locationpath", entry["output"]]
                active = {"local_id": key, "entries": [k for k,_ in selected], "status": "submitting",
                          "receipt_path": str(receipt), "command": command, "started_unix": time.time()}
                journal["batches"].append(active)
                for _,entry in selected: entry["status"] = "submitting"
                save()
                started = time.monotonic()
                ensure_compressor_app()
                with receipt.open("w") as stdout, receipt.with_suffix(".stderr").open("w") as stderr:
                    result = subprocess.run(command, stdout=stdout, stderr=stderr)
                journal["conversion_wait_seconds"] += time.monotonic() - started
                active["submission_returncode"] = result.returncode
                save()
                if result.returncode:
                    raise RuntimeError(f"Compressor submission failed; see {receipt}")
            if active:
                if active["status"] == "submitting":
                    received = _receipt(active["receipt_path"])
                    if not received:
                        raise RuntimeError("No unambiguous batch receipt; refuse duplicate submission. Inspect preserved receipt/logs before resuming.")
                    active.update(batch_id=received["batchID"], status="submitted", receipt=received)
                    for key in active["entries"]:
                        journal["entries"][key].update(status="submitted", batch_id=received["batchID"])
                    save()
                if args.submit_only:
                    journal.update(status="submitted", last_submission_unix=time.time())
                    save()
                    print(f"Submitted {len(active['entries'])} {args.profile} sources: {active['batch_id']}", flush=True)
                    return 0
                started = time.monotonic()
                try:
                    status = _monitor(active["batch_id"], directory, args.batch_timeout)
                except CompressorBatchFailed as error:
                    journal["conversion_wait_seconds"] += time.monotonic() - started
                    reported_ids = {x.get("jobStatus", {}).get("jobid") for x in error.batch_status.get("jobs", [])}
                    missing_ids = {x.get("jobID") for x in active.get("receipt", {}).get("jobs", [])} - reported_ids
                    result = reconcile_failed_batch(journal, active, error.batch_status, directory, save, missing_ids)
                    print(f"Preserved failed batch {active['batch_id']}; {result['successful']} genuinely successful, {result['retry_pending']} require new jobs", flush=True)
                    continue
                journal["conversion_wait_seconds"] += time.monotonic() - started
                active.update(status="successful", completed_unix=time.time(), monitor=status)
                for key in active["entries"]:
                    journal["entries"][key].update(status="converted", compressor_status="Successful")
                save()
            converted = [(k,e) for k,e in journal["entries"].items() if e["status"] == "converted"]
            if converted:
                started = time.monotonic()
                def validate(item):
                    key,entry = item
                    output = Path(entry["output"])
                    before = identity(output)
                    cache_dir = args.state_dir.expanduser().absolute() / "source-metadata-cache"
                    cache_dir.mkdir(exist_ok=True)
                    cache_file = cache_dir / (entry["source_sha256"] + ".json")
                    if cache_file.exists():
                        source_info = json.loads(cache_file.read_text())
                    else:
                        source_info = source_metadata(entry["source"])
                        write_json(cache_file, source_info)
                    try:
                        metadata = verify_output(source_info, output, args.profile,
                                                 directory / (hashlib.sha256(key.encode()).hexdigest()[:16] + ".decode.log"))
                    except FrameCountMismatch as mismatch:
                        return key, None, before, None, source_info, str(mismatch)
                    digest = sha256(output)
                    if identity(output) != before:
                        raise ValueError("Output changed during validation")
                    return key, metadata, before, digest, source_info, None
                mismatches = []
                with ThreadPoolExecutor(max_workers=args.verify_workers) as pool:
                    futures = [pool.submit(validate,item) for item in converted]
                    for future in as_completed(futures):
                        key,metadata,ident,digest,source_info,mismatch = future.result()
                        if mismatch is not None:
                            journal["entries"][key].update(source_metadata=source_info, frame_count_mismatch=mismatch)
                            mismatches.append(key)
                            save()
                            continue
                        journal["entries"][key].update(status="verified", output_metadata=metadata,
                            output_identity=ident, output_sha256=digest, source_metadata=source_info, verified_unix=time.time())
                        save()
                journal["verification_wall_seconds"] += time.monotonic() - started
                save()
                for key in mismatches:
                    repair_frame_count(journal["entries"][key], args.profile, directory, journal, save, args.batch_timeout)
            if not args.keep_mpeg:
                started = time.monotonic()
                for entry in journal["entries"].values():
                    if entry["status"] == "verified":
                        entry["deletion_intent_unix"] = time.time()
                        save()
                        delete_verified_source(root, entry)
                        entry.update(status="deleted", deleted_unix=time.time())
                        save()
                journal["deletion_wall_seconds"] += time.monotonic() - started
                save()
            complete = sum(e["status"] in ("verified", "deleted") for e in journal["entries"].values())
            print(f"{args.profile}: verified {complete}/{len(journal['entries'])}", flush=True)
            if complete == len(journal["entries"]):
                break
        mapping = {entry["canonical"]: entry["output"] for entry in journal["entries"].values()}
        write_json(directory / "source-map.json", mapping)
        journal.update(status="complete", completed_unix=time.time(), source_map=str(directory / "source-map.json"))
        journal["source_bytes"] = sum(e["source_identity"]["bytes"] for e in journal["entries"].values())
        journal["output_bytes"] = sum(e["output_identity"]["bytes"] for e in journal["entries"].values())
        save()
        print(directory / "source-map.json", flush=True)
        return 0
    except BaseException as error:
        journal.update(status="failed", error=f"{type(error).__name__}: {error}", last_error_unix=time.time())
        save()
        raise


if __name__ == "__main__":
    raise SystemExit(main())
