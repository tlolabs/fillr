#!/usr/bin/env python3
"""Adobe-free, headless Chabot background rendering experiment.

Prompts are only a CLI convenience. Pass --date and --intro to call this from
another program; job.json and report.json are the machine-readable interface.
The saved Premiere project supplies cut order, not alphabetical folder order.
The AE layout below is a deliberately versioned template, not an AEP importer.
"""

from __future__ import annotations

import argparse
import concurrent.futures
from datetime import date as Date
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from background_crawl import generate_crawl
from background_project import load_project

FPS = Fraction(30000, 1001)
RATE = "30000/1001"
COLOR_PARAMS = "setparams=field_mode=prog:range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709"
TEMPLATE = "chabot-v27-experimental-1"
# AE centers and scale; borders are a 20px centered black layer stroke in output
# space. Crop the 10px inside half, leaving the outside half on the black canvas.
LAYOUT = {
    1: (479, 270, .5), 2: (1199, 135, .25), 3: (1679, 135, .25),
    4: (1199, 405, .25), 5: (1679, 405, .25),
    7: (1079, 607.5, .125), 8: (1319, 607.5, .125),
    9: (1559, 607.5, .125), 10: (1798, 606.5, .125),
    11: (1079, 741.5, .125), 12: (1319, 741.5, .125),
    13: (1559, 741.5, .125), 14: (1798, 741.5, .125),
    15: (1199, 944, .25), 16: (1679, 945, .25),
}
ANIMATION_END = 14384800 / 23976
LIMITATIONS = [
    "AE layout is reconstructed from the saved v27 binary and reference frames; this is not a general AEP importer.",
    "Adobe and FFmpeg scaling, field interpretation, color conversion and antialiasing can differ.",
    "Crawl motion uses quarter-pixel sampling and the saved unequal copy offsets, rather than Adobe's rasterizer.",
    "VideoToolbox and libx264 rate control differ from Adobe; 16 Mbps is a target/ceiling, not an identical bitstream.",
    "Current FILLR app bundles ffprobe only; the experiment requires separate ffmpeg and ImageMagick installations.",
]


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(command, log, commands):
    commands.append([str(value) for value in command])
    with Path(log).open("wb") as stream:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=stream,
                                stderr=subprocess.STDOUT)
    if result.returncode:
        tail = Path(log).read_text(errors="replace")[-3500:]
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{tail}")


def probe(path, ffprobe, count=False):
    command = [ffprobe, "-v", "error"]
    if count:
        command += ["-count_packets"]
    command += ["-show_streams", "-show_format", "-of", "json", str(path)]
    return json.loads(subprocess.check_output(command, stdin=subprocess.DEVNULL))


def video_stream(metadata):
    return next(stream for stream in metadata["streams"] if stream["codec_type"] == "video")


def frame_count(seconds):
    if not math.isfinite(seconds) or not 0 < seconds <= 600:
        raise ValueError("Duration must be greater than zero and at most 600 seconds")
    return round(Fraction(str(seconds)) * FPS)


def panel_geometry(number):
    cx, cy, scale = LAYOUT[number]
    width, height = round(1920 * scale), round(1080 * scale)
    return {"width": width, "height": height,
            "x": round(cx - width / 2) + 10,
            "y": round(cy - height / 2) + 10,
            "visible_width": width - 20, "visible_height": height - 20}


def sequence_segments(sequence, frames):
    if sequence["unsupported"] or sequence["gaps"] or sequence["overlaps"]:
        raise ValueError("Only contiguous cut-only timelines are supported: " +
                         str({key: sequence[key] for key in ("unsupported", "gaps", "overlaps")}))
    remaining = frames
    result = []
    for source in sequence["segments"]:
        if remaining <= 0:
            break
        if source["duration_frames"] is None or source["frame_rate_mismatch"]:
            raise ValueError("Timeline and source must use the template frame rate")
        count = min(remaining, source["duration_frames"])
        result.append({"path": source["path"], "source_in_seconds": source["source_in_seconds"],
                       "frames": count})
        remaining -= count
    if remaining:
        raise ValueError(f"Timeline is {remaining} frames shorter than the requested output")
    return result


def concat_file(path, inputs):
    # FFconcat uses its own single-quote escaping, not shell quoting.
    lines = ["ffconcat version 1.0"]
    for value in inputs:
        text = str(Path(value).resolve())
        if "\n" in text or "\r" in text:
            raise ValueError("FFconcat paths must not contain newlines")
        lines.append("file '" + text.replace("'", "'\\''") + "'")
    Path(path).write_text("\n".join(lines) + "\n")


def normalization_filters(geometry):
    return (f"setpts=PTS-STARTPTS,bwdif=mode=send_frame:parity=auto:deint=interlaced,"
            f"fps={RATE},scale={geometry['width']}:{geometry['height']}:flags=bicubic,"
            f"setsar=1,format=yuv444p,{COLOR_PARAMS},tpad=stop=1:stop_mode=clone")


def normalize_clip(segment, geometry, dest, ffmpeg, ffprobe, commands):
    # Premiere's inclusive MPEG end can require one final rounding frame. Never
    # turn a genuinely truncated clip into an arbitrarily long frozen picture.
    command = [ffmpeg, "-hide_banner", "-loglevel", "warning", "-xerror", "-nostdin", "-n",
               "-threads", "2", "-ss", str(segment["source_in_seconds"]),
               "-i", segment["path"], "-map", "0:v:0", "-an", "-sn", "-dn",
               "-vf", normalization_filters(geometry), "-filter_threads", "1", "-frames:v", str(segment["frames"]),
               "-c:v", "ffv1", "-level", "3", "-threads", "2", "-pix_fmt", "yuv444p",
               "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
               "-color_range", "tv", str(dest)]
    run(command, dest.with_suffix(".log"), commands)
    metadata = probe(dest, ffprobe, count=True)
    actual = int(video_stream(metadata)["nb_read_packets"])
    if actual != segment["frames"]:
        raise RuntimeError(f"Incomplete normalized clip {dest}: {actual} frames")


def build_banners(crawl, folder, magick, commands):
    """Static copies at four times final size permit quarter-pixel scrolling."""
    bands = []
    for name, scale, position, end_x, offsets in [
        ("small", .89, (1062, 411), -21840, [0, 2110] + [2124 * n for n in range(2, 12)]),
        ("big", 1.6, (1083, 777), -11212, [3800 * n for n in range(7)]),
    ]:
        factor = scale * 2  # .5 main-comp scale * 4 supersampling
        width, height = round(2376 * factor), round(32 * factor)
        tile = folder / f"{name}-tile.png"
        run([magick, str(crawl), "-resize", f"{width}x{height}!", "-alpha", "off",
             f"PNG24:{tile}"], folder / f"{name}-tile.log", commands)
        banner = folder / f"{name}-banner.png"
        canvas_width = round(offsets[-1] * 2) + width + 4000
        command = [magick, "-size", f"{canvas_width}x{height}", "xc:black"]
        for offset in offsets:
            command += [str(tile), "-geometry", f"+{round(offset * 2)}+0", "-compose", "Over", "-composite"]
        command += ["-alpha", "off", f"PNG24:{banner}"]
        run(command, folder / f"{name}-banner.log", commands)
        left = (position[0] - 1188 * scale) * .5
        top = 539 + (position[1] - 16 * scale) * .5
        bands.append({"path": str(banner), "name": name,
                      "height": max(1, round(height / 4)), "source_height": height,
                      "y": round(top), "start_x": (10 - left) * 4,
                      "speed": (position[0] - end_x) / ANIMATION_END * 2})
    return bands


def composition_filters(panels, bands):
    filters = [f"color=c=black:s=1920x1080:r={RATE},format=yuv444p[base]"]
    previous = "base"
    for index, panel in enumerate(panels):
        geom = panel["geometry"]
        filters.append(f"[{index}:v]settb=expr=1001/30000,setpts=N,setsar=1,{COLOR_PARAMS},"
                       f"crop={geom['visible_width']}:{geom['visible_height']}:10:10[p{index}]")
        output = f"b{index}"
        filters.append(f"[{previous}][p{index}]overlay=x={geom['x']}:y={geom['y']}:"
                       f"format=yuv444:shortest=1[{output}]")
        previous = output
    for offset, band in enumerate(bands):
        index = len(panels) + offset
        label = f"crawl{offset}"
        filters.append(f"[{index}:v]format=yuv444p,loop=loop=-1:size=1:start=0,"
                       f"settb=expr=1001/30000,setpts=N,crop=3760:{band['source_height']}:"
                       f"x='{band['start_x']:.8f}+{band['speed']:.8f}*n/({RATE})':y=0:exact=1,"
                       f"scale=940:{band['height']}:flags=bicubic[{label}]")
        output = f"text{offset}"
        filters.append(f"[{previous}][{label}]overlay=x=10:y={band['y']}:format=yuv444:shortest=1[{output}]")
        previous = output
    filters.append(f"[{previous}]setsar=1,format=yuv444p,{COLOR_PARAMS}[out]")
    return ";\n".join(filters) + "\n"


def compose_master(panels, bands, frames, dest, ffmpeg, commands):
    command = [ffmpeg, "-hide_banner", "-loglevel", "warning", "-nostdin", "-n",
               "-filter_complex_threads", "2"]
    for panel in panels:
        command += ["-threads", "1", "-f", "concat", "-safe", "0", "-i", panel["concat"]]
    for band in bands:
        command += ["-framerate", RATE, "-i", band["path"]]
    graph = dest.with_suffix(".filtergraph.txt")
    graph.write_text(composition_filters(panels, bands))
    command += ["-filter_complex", graph.read_text(), "-map", "[out]", "-an", "-sn", "-dn",
                "-frames:v", str(frames), "-r", RATE, "-c:v", "ffv1", "-level", "3",
                "-threads", "4", "-pix_fmt", "yuv444p", "-color_primaries", "bt709",
                "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", str(dest)]
    run(command, dest.with_suffix(".log"), commands)


def encoding_options(encoder):
    command = ["-r", RATE, "-fps_mode", "cfr", "-c:v", encoder,
               "-profile:v", "high", "-level:v", "4.2", "-b:v", "16M", "-maxrate", "16M",
               "-bufsize", "32M"]
    if encoder == "libx264":
        command += ["-preset", "medium", "-threads", "0"]
    elif encoder == "h264_videotoolbox":
        command += ["-allow_sw", "0", "-realtime", "0"]
    else:
        raise ValueError(f"Unsupported encoder {encoder}")
    command += ["-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709",
                "-colorspace", "bt709", "-color_range", "tv", "-movflags", "+faststart"]
    return command


def encode_master(master, output, encoder, ffmpeg, commands):
    command = [ffmpeg, "-hide_banner", "-loglevel", "warning", "-nostdin", "-n",
               "-threads", "4", "-i", str(master), "-map", "0:v:0", "-an", "-sn", "-dn",
               "-vf", f"format=yuv420p,{COLOR_PARAMS}"]
    command += encoding_options(encoder) + [str(output)]
    run(command, output.with_suffix(".log"), commands)


def validate_output(path, expected_frames, ffprobe):
    metadata = probe(path, ffprobe, count=True)
    streams = metadata["streams"]
    stream = video_stream(metadata)
    expected = {"codec_name": "h264", "profile": "High", "level": 42, "width": 1920,
                "height": 1080, "pix_fmt": "yuv420p", "r_frame_rate": RATE,
                "color_space": "bt709", "color_transfer": "bt709", "color_primaries": "bt709",
                "color_range": "tv", "field_order": "progressive", "sample_aspect_ratio": "1:1"}
    failures = [f"{key}: expected {value}, got {stream.get(key)}"
                for key, value in expected.items() if stream.get(key) != value]
    if len(streams) != 1:
        failures.append("Expected exactly one video stream and no audio, subtitles or data")
    if int(stream.get("nb_frames", 0)) != expected_frames:
        failures.append("Encoded frame count differs from the requested timeline")
    if int(stream.get("nb_read_packets", 0)) != expected_frames:
        failures.append("Packet count differs from the requested timeline")
    duration = float(stream.get("duration", 0))
    if abs(duration - float(expected_frames / FPS)) > .00001:
        failures.append("Encoded duration differs from exact frame duration")
    if failures:
        raise RuntimeError(f"Output verification failed for {path}: " + "; ".join(failures))
    return metadata


def decode_check(path, ffmpeg, commands):
    run([ffmpeg, "-hide_banner", "-loglevel", "error", "-xerror", "-nostdin", "-threads", "4",
         "-i", str(path), "-map", "0:v:0", "-an", "-f", "null", "-"],
        path.with_suffix(".decode.log"), commands)


def main(argv=None):
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media-root", type=Path, default=repo / "CNN Downloads")
    parser.add_argument("--project", type=Path)
    parser.add_argument("--psd", type=Path)
    parser.add_argument("--date", help="YYYY-MM-DD; prompted when omitted")
    parser.add_argument("--intro", type=Path, help="Clip to repeat in Comp 1; prompted when omitted")
    parser.add_argument("--duration", type=float, default=600)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--encoder", choices=["both", "hardware", "software"], default="both")
    parser.add_argument("--pipeline", choices=["master", "direct"], default="master",
                        help="direct streams original sources into final H.264, without intermediate video files")
    parser.add_argument("--compositor-threads", type=int, default=2, help="Direct pipeline filter-graph threads")
    parser.add_argument("--source-threads", type=int, default=1, help="Direct pipeline threads per source decoder")
    parser.add_argument("--source-filter-threads", type=int, default=1, help="Direct pipeline threads per source filter")
    parser.add_argument("--test-label", help="Filename label using letters, digits, hyphens, underscores and dots")
    parser.add_argument("--source-map", type=Path, help="Direct benchmark JSON mapping original paths to verified source copies")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--magick", default="magick")
    parser.add_argument("--font", type=Path)
    parser.add_argument("--adobe-seconds", type=float, default=9717)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args(argv)
    if not 1 <= args.jobs <= 16:
        parser.error("--jobs must be between 1 and 16")
    if any(not 1 <= value <= 128 for value in
           (args.compositor_threads, args.source_threads, args.source_filter_threads)):
        parser.error("Thread counts must be between 1 and 128")
    if args.test_label and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", args.test_label) is None:
        parser.error("--test-label must be a filename-safe label of at most 100 characters")
    if args.source_map and args.pipeline != "direct":
        parser.error("--source-map is supported only by the direct pipeline")
    if args.date is None:
        if not sys.stdin.isatty():
            parser.error("Pass --date for a noninteractive job")
        args.date = input(f"Show date [YYYY-MM-DD, default {Date.today().isoformat()}]: ").strip() or Date.today().isoformat()
    try:
        show_date = Date.fromisoformat(args.date)
    except ValueError:
        parser.error("--date must be a valid date in YYYY-MM-DD form")
    args.media_root = args.media_root.expanduser().resolve()
    if args.intro is None:
        default = args.media_root / "Chabot News Intro November 12, 2026.mov"
        if not sys.stdin.isatty():
            parser.error("Pass --intro for a noninteractive job")
        args.intro = Path(input(f"Video to loop in Comp 1 [{default}]: ").strip().strip('"') or default)
    args.intro = args.intro.expanduser().resolve()
    if not args.intro.is_file():
        parser.error(f"Intro clip not found: {args.intro}")
    project = (args.project or args.media_root / "Chabot News Backgrounds/CC 2027/Footage.prproj").resolve()
    psd = (args.psd or args.media_root / "Chabot News Backgrounds/Text Crawl.psd").resolve()
    output = (args.output_dir or repo / "dist/background-benchmark" / f"{show_date.isoformat()}-{time.strftime('%Y%m%d-%H%M%S')}").resolve()
    # A new directory prevents accidentally overwriting either source or results.
    output.mkdir(parents=True, exist_ok=False)
    commands = []
    started = time.perf_counter()
    report = {"status": "preparing", "template": TEMPLATE, "pipeline": args.pipeline, "date": show_date.isoformat(),
              "test_label": args.test_label,
              "output_directory": str(output), "limitations": LIMITATIONS, "encodes": {},
              "adobe_reference_seconds": args.adobe_seconds, "commands": commands}
    try:
        for executable in (args.ffmpeg, args.ffprobe, args.magick):
            if shutil.which(executable) is None:
                raise ValueError(f"Required executable not found: {executable}")
        report["versions"] = {tool: subprocess.check_output([path, "-version"], text=True).splitlines()[0]
                              for tool, path in [("ffmpeg", args.ffmpeg), ("ffprobe", args.ffprobe), ("magick", args.magick)]}
        # Capture optional comparison metadata before the long render. A later
        # rename of a reference must not invalidate already-verified outputs.
        if args.reference:
            report["reference"] = {"path": str(args.reference.resolve()),
                                   "ffprobe": probe(args.reference, args.ffprobe)}
        frames = frame_count(args.duration)
        if frames < 1:
            raise ValueError("Duration rounds to zero frames")
        sequences = load_project(project, args.media_root)
        source_map = {}
        if args.source_map:
            supplied_map = json.loads(args.source_map.read_text())
            if not isinstance(supplied_map, dict):
                raise ValueError("Source map must be an object mapping original paths to source copies")
            for original, replacement in supplied_map.items():
                if not isinstance(original, str) or not isinstance(replacement, str):
                    raise ValueError("Source-map keys and values must be path strings")
                original_path = Path(original).expanduser().resolve(strict=True)
                replacement_path = Path(replacement).expanduser().resolve(strict=True)
                if not original_path.is_file() or not replacement_path.is_file():
                    raise ValueError("Source-map entries must be files")
                source_map[str(original_path)] = str(replacement_path)
        intro_probe = probe(args.intro, args.ffprobe)
        intro_stream = video_stream(intro_probe)
        intro_duration = intro_stream.get("duration")
        if intro_duration is None:
            intro_duration = intro_probe["format"]["duration"]
        intro_frames = round(float(intro_duration) * FPS)
        if intro_frames < 1:
            raise ValueError("Intro clip has no complete frames")
        panels, tasks = [], {}
        cache = output / "normalized"
        if args.pipeline == "master":
            cache.mkdir()
        for number in sorted(LAYOUT):
            geometry = panel_geometry(number)
            if number == 1:
                segments, remaining = [], frames
                while remaining:
                    count = min(remaining, intro_frames)
                    segments.append({"path": str(args.intro), "source_in_seconds": 0, "frames": count})
                    remaining -= count
            else:
                sequence = sequences[f"Comp {number}"]
                if sequence["frame_rate"] != {"numerator": 30000, "denominator": 1001}:
                    raise ValueError("Only 30000/1001 sequences are supported")
                segments = sequence_segments(sequence, frames)
            for segment in segments:
                if segment["path"] in source_map:
                    segment["original_path"] = segment["path"]
                    segment["path"] = source_map[segment["path"]]
            panel = {"comp": number, "geometry": geometry, "segments": segments}
            if args.pipeline == "master":
                files = []
                for segment in segments:
                    key = hashlib.sha256(json.dumps([segment, geometry["width"], geometry["height"]], sort_keys=True).encode()).hexdigest()[:24]
                    dest = cache / f"{key}.mkv"
                    tasks[key] = (segment, geometry, dest)
                    files.append(dest)
                listing = output / f"comp-{number}.ffconcat"
                concat_file(listing, files)
                panel["concat"] = str(listing)
            panels.append(panel)
        job = {"template": TEMPLATE, "date": show_date.isoformat(), "frames": frames,
               "frame_rate": RATE, "duration_seconds": float(frames / FPS),
               "intro": str(args.intro), "project": str(project), "psd_template": str(psd),
               "psd_sha256": sha256(psd), "project_sha256": sha256(project),
               "encoders": args.encoder, "pipeline": args.pipeline, "panels": panels,
               "unique_normalizations": len(tasks), "test_label": args.test_label,
               "source_map": source_map, "thread_counts": {"compositor": args.compositor_threads,
                   "source_decoder": args.source_threads, "source_filter": args.source_filter_threads}}
        write_json(output / "job.json", job)
        if args.plan_only:
            report["status"] = "planned"
            write_json(output / "report.json", report)
            print(output / "job.json")
            return 0
        print(f"Preparing {args.pipeline} pipeline for {frames} frames", flush=True)
        crawl = output / "crawl-flattened.png"
        report["crawl"] = generate_crawl(psd, show_date, crawl, magick=args.magick, font_path=args.font)
        bands = build_banners(crawl, output, args.magick, commands)
        if args.pipeline == "master":
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
                futures = [pool.submit(normalize_clip, *task, args.ffmpeg, args.ffprobe, commands)
                           for task in tasks.values()]
                for complete, future in enumerate(concurrent.futures.as_completed(futures), 1):
                    future.result()
                    if complete % 10 == 0 or complete == len(tasks):
                        print(f"Normalized {complete}/{len(tasks)} source segments", flush=True)
            normalized_at = time.perf_counter()
            master = output / "composition-lossless.mkv"
            print("Compositing shared lossless master", flush=True)
            compose_master(panels, bands, frames, master, args.ffmpeg, commands)
            master_metadata = probe(master, args.ffprobe, count=True)
            if int(video_stream(master_metadata)["nb_read_packets"]) != frames:
                raise RuntimeError("Lossless composition has an incorrect frame count")
            report.update({"normalization_seconds": normalized_at - started,
                           "composition_seconds": time.perf_counter() - normalized_at,
                           "master": str(master), "master_ffprobe": master_metadata})
        else:
            report.update({"normalization_seconds": 0, "composition_seconds": 0,
                           "intermediate_video_files": 0,
                           "timing_scope": "Each render_encode_seconds includes original-source decoding, deinterlacing, scaling, composition and final H.264 encoding; preparation is artwork and planning only."})
        prepared_at = time.perf_counter()
        report.update({"frames": frames, "duration_seconds": float(frames / FPS),
                       "preparation_seconds": prepared_at - started})
        encoders = (["h264_videotoolbox", "libx264"] if args.encoder == "both" else
                    ["h264_videotoolbox" if args.encoder == "hardware" else "libx264"])
        for encoder in encoders:
            direct_label = "direct " if args.pipeline == "direct" else ""
            dest = output / (f"{args.test_label}_{encoder}.mp4" if args.test_label else
                             f"Chabot News Background {show_date.isoformat()} {direct_label}{encoder}.mp4")
            print(f"Rendering/encoding {args.pipeline}: {encoder}", flush=True)
            encode_at = time.perf_counter()
            if args.pipeline == "direct":
                from background_direct import render_direct
                transport = render_direct(panels, bands, frames, dest, encoder, args.ffmpeg, commands,
                                          compositor_threads=args.compositor_threads,
                                          source_threads=args.source_threads,
                                          source_filter_threads=args.source_filter_threads)
            else:
                encode_master(master, dest, encoder, args.ffmpeg, commands)
            seconds = time.perf_counter() - encode_at
            metadata = validate_output(dest, frames, args.ffprobe)
            print(f"Checking full {encoder} decode", flush=True)
            validation_at = time.perf_counter()
            decode_check(dest, args.ffmpeg, commands)
            report["encodes"][encoder] = {"path": str(dest), "encode_seconds": seconds,
                "preparation_plus_encode_seconds": report["preparation_seconds"] + seconds,
                "adobe_speed_ratio": (args.adobe_seconds / (report["preparation_seconds"] + seconds)
                                      if frames == 17982 else None),
                "verification_seconds": time.perf_counter() - validation_at,
                "sha256": sha256(dest), "bytes": dest.stat().st_size, "ffprobe": metadata,
                "full_decode_passed": True}
            if args.pipeline == "direct":
                report["encodes"][encoder].update({"render_encode_seconds": seconds,
                                                   "source_transport": transport})
            write_json(output / "report.json", report)
        if sha256(psd) != job["psd_sha256"] or sha256(project) != job["project_sha256"]:
            raise RuntimeError("Original PSD or Premiere project changed during render")
        report["status"] = "complete"
        report["total_wall_seconds"] = time.perf_counter() - started
        write_json(output / "report.json", report)
        print(json.dumps({"status": report["status"], "report": str(output / "report.json"),
                          "preparation_seconds": report["preparation_seconds"],
                          "encodes": {key: {k: v for k, v in value.items() if k in ("path", "encode_seconds", "preparation_plus_encode_seconds", "adobe_speed_ratio", "bytes")}
                                      for key, value in report["encodes"].items()}}, indent=2))
        return 0
    except Exception as exc:
        report["status"], report["error"] = "failed", str(exc)
        report["total_wall_seconds"] = time.perf_counter() - started
        write_json(output / "report.json", report)
        print(f"Render failed: {exc}\nReport: {output / 'report.json'}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
