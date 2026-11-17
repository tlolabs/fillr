#!/usr/bin/env python3
"""Experimental Metal renderer: original sources to a silent H.264 MP4.

MPEG-2 decoding and NV12 packing remain on the CPU. Supported source decoding,
deinterlacing, scaling, compositing and H.264 encoding use Apple GPU/media APIs.
The native helper links the installed FFmpeg libraries; it needs macOS/Metal.
"""
import argparse
from datetime import date as Date
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from background_crawl import generate_crawl
from background_video import LAYOUT, build_banners, decode_check, sha256, validate_output, write_json


def validate_hardware_decoding(native_stats):
    """Require runtime backend evidence; a VT-capable codec alone is insufficient."""
    sources = native_stats.get("sources", [])
    expected_comps = set(LAYOUT)
    reported_comps = [source.get("comp") for source in sources]
    if (len(reported_comps) != len(expected_comps)
            or any(type(comp) is not int for comp in reported_comps)
            or set(reported_comps) != expected_comps):
        raise RuntimeError("Hardware decode verification requires all 15 unique expected panel reports")
    for source in sources:
        if source.get("cpu_decoded_nv12_packed_frames") != 0:
            raise RuntimeError(f"Comp {source['comp']} used CPU decoding in a hardware-required test")
        segments = source.get("segments", [])
        if not segments or any(segment.get("reported_hardware_decoder") is not True for segment in segments):
            raise RuntimeError(f"Comp {source['comp']} did not confirm hardware decoding for every cut")


def main(argv=None):
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", help="YYYY-MM-DD; prompted when omitted")
    parser.add_argument("--intro", type=Path, help="Video to loop in Comp 1; prompted when omitted")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--test-label", default="TEST-07_GPU-METAL_FULL10MIN")
    parser.add_argument("--source-map", type=Path,
                        help="Verified canonical-source to converted-source JSON mapping")
    parser.add_argument("--require-hardware-decode", action="store_true",
                        help="Fail verification if any panel used CPU decoding")
    parser.add_argument("--prepare-only", action="store_true", help="Plan and flatten artwork, without rendering")
    parser.add_argument("--run-prepared", action="store_true", help="Use an existing GPU job in --output-dir")
    parser.add_argument("--skip-build", action="store_true", help="Use the existing native development helper")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", args.test_label):
        parser.error("Invalid filename label")
    output = args.output_dir.expanduser().resolve()
    report_path = output / "report.json"
    job_path = output / "job.json"
    commands = []
    started = time.perf_counter()
    if args.run_prepared:
        job = json.loads(job_path.read_text())
        report = json.loads(report_path.read_text())
        if job.get("pipeline") != "metal-native-hybrid" or job.get("frames") != 17982:
            parser.error("Prepared job must be a full 10-minute GPU job")
        if job.get("test_label") != args.test_label:
            parser.error("Prepared job label differs from --test-label")
        commands = report.setdefault("commands", [])
        # A resumed invocation may strengthen the saved requirement. Persist it
        # so both the native helper and post-render verification enforce it;
        # omitting the flag must never weaken an existing hardware requirement.
        if args.require_hardware_decode:
            job["require_hardware_decode"] = True
            write_json(job_path, job)
    else:
        command = [sys.executable, str(repo / "script/background_video.py"), "--pipeline", "direct",
                   "--plan-only", "--encoder", "hardware", "--duration", "600",
                   "--output-dir", str(output), "--test-label", args.test_label]
        if args.date:
            command += ["--date", args.date]
        if args.intro:
            command += ["--intro", str(args.intro)]
        if args.source_map:
            command += ["--source-map", str(args.source_map.expanduser().resolve(strict=True))]
        subprocess.run(command, check=True)
        job = json.loads(job_path.read_text())
        report = json.loads(report_path.read_text())
        commands = report.setdefault("commands", [])
        commands.append(command)
        report["pipeline"] = job["pipeline"] = "metal-native-hybrid"
        crawl = output / "crawl-flattened.png"
        try:
            report["crawl"] = generate_crawl(job["psd_template"], Date.fromisoformat(job["date"]), crawl)
            bands = build_banners(crawl, output, "magick", commands)
        except BaseException as error:
            report.update(status="failed", error=f"Artwork preparation: {type(error).__name__}: {error}")
            write_json(report_path, report)
            raise
        for band in bands:
            band["tile_path"] = str(output / f"{band['name']}-tile.png")
        job["bands"] = bands
        job["require_hardware_decode"] = args.require_hardware_decode
        if args.source_map:
            report["source_map_path"] = str(args.source_map.expanduser().resolve())
            report["source_map_sha256"] = sha256(args.source_map)
        job["thread_counts"] = {"source_decoder": 1, "source_filter": 1,
                                "source_workers": 15, "gpu_compositor": 1}
        job["gpu_limitations"] = [
            ("This test requires hardware ProRes decoding for every panel."
             if args.require_hardware_decode else
             "MPEG-2 is CPU decoded on this Mac; same-size NV12 packing/upload is CPU work."),
            "GPU YADIF replaces CPU BWDIF; GPU Lanczos scaling and chroma sampling can differ.",
            "VideoToolbox hardware codec engines are separate from general Metal GPU cores.",
        ]
        report["limitations"] = list(report.get("limitations", [])) + job["gpu_limitations"]
        report["preparation_seconds"] = time.perf_counter() - started
        report["status"] = "prepared"
        write_json(job_path, job)
        write_json(report_path, report)
    if args.prepare_only:
        print(job_path, flush=True)
        return 0

    try:
        if not args.skip_build:
            build_started = time.perf_counter()
            build = ["bash", str(repo / "script/build_background_gpu.sh")]
            commands.append(build)
            subprocess.run(build, check=True)
            report["native_build_seconds_excluded_from_render"] = time.perf_counter() - build_started
        native = repo / ".build/background_gpu/fillr-background-gpu"
        if not native.is_file():
            raise RuntimeError("Build the native helper first")
        provenance = sorted((repo / "script/background_gpu").glob("*")) + [
            Path(__file__).resolve(), repo / "script/build_background_gpu.sh"]
        source_hashes = {str(path.relative_to(repo)): sha256(path)
                         for path in provenance if path.is_file()}
        manifest = json.loads((native.parent / "build-manifest.json").read_text())
        if manifest["source_sha256"] != source_hashes or manifest["native_binary_sha256"] != sha256(native):
            raise RuntimeError("Native build is stale; rebuild without --skip-build")
        report.update(manifest)
        dest = output / f"{args.test_label}.mp4"
        native_report = output / "native-report.json"
        command = [str(native), "--job", str(job_path), "--output", str(dest),
                   "--progress", str(output / "progress.json"), "--report", str(native_report)]
        commands.append(command)
        report["status"] = "rendering"
        write_json(report_path, report)
        render_started = time.perf_counter()
        with (output / "native-render.log").open("w") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = process.wait()
            except BaseException:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise
            if code:
                raise subprocess.CalledProcessError(code, command)
        render_seconds = time.perf_counter() - render_started
        native_stats = json.loads(native_report.read_text())
        if native_stats["status"] != "encoded" or native_stats["completed_frames"] != job["frames"]:
            raise RuntimeError("Native render did not encode the complete timeline")
        if job.get("require_hardware_decode"):
            validate_hardware_decoding(native_stats)
        metadata = validate_output(dest, job["frames"], "ffprobe")
        decode_check(dest, "ffmpeg", commands)
        report["native"] = native_stats
        report["encodes"] = {"h264_videotoolbox": {
            "path": str(dest), "render_seconds": render_seconds,
            "total_seconds": report["preparation_seconds"] + render_seconds,
            "render_speed_vs_realtime": job["duration_seconds"] / render_seconds,
            "sha256": sha256(dest), "bytes": dest.stat().st_size,
            "full_decode_check": "passed", "ffprobe": metadata,
        }}
        report["status"] = "verified"
        write_json(report_path, report)
        (output / "SHA256SUMS.txt").write_text(f"{sha256(dest)}  {dest.name}\n")
        print(json.dumps({"output": str(dest), "render_seconds": render_seconds,
                          "total_seconds": report["preparation_seconds"] + render_seconds,
                          "full_decode_check": "passed"}, indent=2), flush=True)
        return 0
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
        native_report = output / "native-report.json"
        if native_report.is_file():
            report["native"] = json.loads(native_report.read_text())
        write_json(report_path, report)
        print(f"GPU render failed: {error}; see {report_path}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
