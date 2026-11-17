"""Stream original clips through the composition directly into an MP4 encoder.

Panel streams are bounded anonymous rawvideo pipes. No normalized video files or
lossless composition are written. This transport currently requires POSIX.
"""

from __future__ import annotations

import concurrent.futures
import os
from pathlib import Path
import resource
import subprocess
import threading
import time

from background_video import (COLOR_PARAMS, RATE, composition_filters,
                              encoding_options, normalization_filters)


def _close(fd):
    try:
        os.close(fd)
    except OSError:
        pass


def _stop_process(process):
    if process.poll() is None:
        try:
            process.terminate()
        except ProcessLookupError:
            pass


def _reap_process(process, timeout=3):
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=timeout)


def _log_tail(path):
    return Path(path).read_text(errors="replace")[-3000:]


def render_direct(panels, bands, frames, dest, encoder, ffmpeg, commands,
                  compositor_threads=2, source_threads=1, source_filter_threads=1):
    """Render the planned panels from originals, returning transport statistics.

    Every panel gets a concurrent feeder, even on machines with few CPUs. Input
    initialization is sequential in FFmpeg, so limiting workers can deadlock on
    full early pipes before later inputs have a producer. Each feeder serializes
    that panel's cuts and checks their exact raw byte counts.
    """
    if os.name != "posix":
        raise RuntimeError("Direct rawvideo-pipe rendering currently requires POSIX")
    if not panels or frames < 1:
        raise RuntimeError("Direct rendering requires panels and a positive frame count")
    if any(not isinstance(value, int) or not 1 <= value <= 128
           for value in (compositor_threads, source_threads, source_filter_threads)):
        raise ValueError("Direct renderer thread counts must be between 1 and 128")
    dest = Path(dest)
    if dest.exists():
        raise FileExistsError(f"Direct output already exists: {dest}")
    for panel in panels:
        if sum(segment["frames"] for segment in panel["segments"]) != frames:
            raise RuntimeError(f"Comp {panel['comp']} does not cover the requested frame count")
        if any(segment["frames"] < 1 for segment in panel["segments"]):
            raise RuntimeError("Direct source segments must contain at least one frame")

    started = time.perf_counter()
    usage_before = [resource.getrusage(kind) for kind in (resource.RUSAGE_SELF, resource.RUSAGE_CHILDREN)]
    source_logs = dest.parent / f"{dest.stem}.sources"
    source_logs.mkdir(exist_ok=False)
    consumer_log = dest.with_suffix(".log")
    progress_path = dest.with_suffix(".progress.txt")
    graph_path = dest.with_suffix(".filtergraph.txt")
    graph = composition_filters(panels, bands).rstrip().rstrip(";")
    graph += f";\n[out]format=yuv420p,{COLOR_PARAMS}[encoded]"
    graph_path.write_text(graph + "\n")

    pipes = [os.pipe() for _ in panels]
    read_fds = [pair[0] for pair in pipes]
    pending_writers = {pair[1] for pair in pipes}
    active_sources = set()
    source_errors = []
    lock = threading.Lock()
    stop = threading.Event()
    consumer = None
    executor = None
    futures = []

    def feed_panel(panel, writer_fd):
        with lock:
            pending_writers.discard(writer_fd)
        sink = None
        result = {"comp": panel["comp"], "frames": 0, "bytes": 0, "segments": []}
        geometry = panel["geometry"]
        frame_bytes = geometry["width"] * geometry["height"] * 3
        try:
            sink = os.fdopen(writer_fd, "wb", buffering=0)
            for index, segment in enumerate(panel["segments"]):
                if stop.is_set():
                    raise RuntimeError("Direct source feeding cancelled")
                log = source_logs / f"comp-{panel['comp']}-cut-{index:03d}.log"
                command = [ffmpeg, "-hide_banner", "-loglevel", "warning", "-xerror",
                           "-nostdin", "-threads", str(source_threads), "-ss", str(segment["source_in_seconds"]),
                           "-i", segment["path"], "-map", "0:v:0", "-an", "-sn", "-dn",
                           "-vf", normalization_filters(geometry), "-filter_threads", str(source_filter_threads),
                           "-frames:v", str(segment["frames"]), "-c:v", "rawvideo",
                           "-threads", "1", "-pix_fmt", "yuv444p", "-f", "rawvideo", "pipe:1"]
                expected_bytes = frame_bytes * segment["frames"]
                actual_bytes = 0
                process = None
                try:
                    with log.open("wb") as log_stream:
                        commands.append(command)
                        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                                   stdout=subprocess.PIPE, stderr=log_stream)
                        with lock:
                            active_sources.add(process)
                        if stop.is_set():
                            _stop_process(process)
                        assert process.stdout is not None
                        while not stop.is_set():
                            block = process.stdout.read(256 * 1024)
                            if not block:
                                break
                            actual_bytes += len(block)
                            if actual_bytes > expected_bytes:
                                raise RuntimeError(f"Direct source emitted excess video: {segment['path']}")
                            view = memoryview(block)
                            while view:
                                if stop.is_set():
                                    raise RuntimeError("Direct source feeding cancelled")
                                written = sink.write(view)
                                if not written:
                                    raise RuntimeError("Direct rawvideo pipe stopped accepting bytes")
                                view = view[written:]
                        if stop.is_set():
                            raise RuntimeError("Direct source feeding cancelled")
                        try:
                            returncode = process.wait(timeout=5)
                        except subprocess.TimeoutExpired as exc:
                            raise RuntimeError(f"Direct source did not finish: {log}") from exc
                    if returncode:
                        raise RuntimeError(f"Direct source failed ({returncode}); see {log}\n{_log_tail(log)}")
                    if actual_bytes != expected_bytes:
                        raise RuntimeError(
                            f"Incomplete direct source {segment['path']}: expected {expected_bytes} "
                            f"bytes ({segment['frames']} frames), got {actual_bytes}; see {log}")
                    result["frames"] += segment["frames"]
                    result["bytes"] += actual_bytes
                    result["segments"].append({"path": segment["path"],
                                                "source_in_seconds": segment["source_in_seconds"],
                                                "frames": segment["frames"], "bytes": actual_bytes,
                                                "log": str(log)})
                finally:
                    if process is not None:
                        _stop_process(process)
                        _reap_process(process)
                        if process.stdout is not None:
                            process.stdout.close()
                        with lock:
                            active_sources.discard(process)
            return result
        except Exception as exc:
            error = (RuntimeError(f"Direct consumer closed Comp {panel['comp']} pipe; see {consumer_log}")
                     if isinstance(exc, BrokenPipeError) else exc)
            # Publish the causal source failure before closing the pipe. Its
            # EOF can otherwise make later panels fail with secondary EPIPEs.
            with lock:
                if not source_errors:
                    source_errors.append(error)
            if error is exc:
                raise
            raise error from exc
        finally:
            if sink is not None:
                sink.close()
            else:
                _close(writer_fd)

    try:
        command = [ffmpeg, "-hide_banner", "-loglevel", "warning", "-xerror", "-nostdin",
                   "-n", "-filter_complex_threads", str(compositor_threads)]
        for panel, reader in zip(panels, read_fds):
            geometry = panel["geometry"]
            command += ["-thread_queue_size", "2", "-threads", "1", "-f", "rawvideo",
                        "-pixel_format", "yuv444p", "-video_size",
                        f"{geometry['width']}x{geometry['height']}", "-framerate", RATE,
                        "-probesize", "32", "-analyzeduration", "0", "-color_range", "tv",
                        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                        "-i", f"pipe:{reader}"]
        for band in bands:
            command += ["-framerate", RATE, "-i", band["path"]]
        command += ["-filter_complex", graph, "-map", "[encoded]", "-an", "-sn", "-dn",
                    "-frames:v", str(frames), *encoding_options(encoder),
                    "-progress", str(progress_path), "-nostats", str(dest)]
        with consumer_log.open("wb") as log_stream:
            commands.append(command)
            consumer = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log_stream,
                                        stderr=subprocess.STDOUT, pass_fds=tuple(read_fds))
            for reader in read_fds:
                _close(reader)
            read_fds = []
            executor = concurrent.futures.ThreadPoolExecutor(max_workers=len(panels))
            futures = [executor.submit(feed_panel, panel, writer)
                       for panel, (_, writer) in zip(panels, pipes)]
            while True:
                returncode = consumer.poll()
                if returncode is not None and returncode:
                    raise RuntimeError(f"Direct consumer failed ({returncode}); see {consumer_log}\n"
                                       f"{_log_tail(consumer_log)}")
                with lock:
                    source_error = source_errors[0] if source_errors else None
                if source_error is not None:
                    raise source_error
                if returncode is not None:
                    break
                time.sleep(.05)
            results = []
            deadline = time.monotonic() + 10
            for future in futures:
                try:
                    results.append(future.result(timeout=max(.01, deadline - time.monotonic())))
                except concurrent.futures.TimeoutError as exc:
                    raise RuntimeError("Direct feeder did not finish after consumer completion") from exc
        elapsed = time.perf_counter() - started
        usage_after = [resource.getrusage(kind) for kind in (resource.RUSAGE_SELF, resource.RUSAGE_CHILDREN)]
        user_seconds = sum(after.ru_utime - before.ru_utime for before, after in zip(usage_before, usage_after))
        system_seconds = sum(after.ru_stime - before.ru_stime for before, after in zip(usage_before, usage_after))
        effective_cores = (user_seconds + system_seconds) / elapsed
        return {"pipeline": "direct", "transport": "anonymous rawvideo pipes",
                "intermediate_video_files": 0, "elapsed_seconds": elapsed,
                "thread_counts": {"compositor": compositor_threads, "source_decoder": source_threads,
                                  "source_filter": source_filter_threads},
                "cpu_usage": {"user_seconds": user_seconds, "system_seconds": system_seconds,
                              "effective_cores": effective_cores, "logical_cpus": os.cpu_count(),
                              "percent_of_machine": 100 * effective_cores / (os.cpu_count() or 1),
                              "scope": "Renderer and waited child processes, excluding post-render verification"},
                "rawvideo_pixel_format": "yuv444p", "rawvideo_bytes": sum(r["bytes"] for r in results),
                "panels": results, "consumer_log": str(consumer_log),
                "progress_path": str(progress_path), "filtergraph_path": str(graph_path)}
    finally:
        stop.set()
        if consumer is not None:
            _stop_process(consumer)
        with lock:
            sources = list(active_sources)
        for process in sources:
            _stop_process(process)
        if consumer is not None:
            _reap_process(consumer)
        for process in sources:
            _reap_process(process)
        for reader in read_fds:
            _close(reader)
        if executor is not None:
            executor.shutdown(wait=True, cancel_futures=True)
        with lock:
            unopened = list(pending_writers)
            pending_writers.clear()
        for writer in unopened:
            _close(writer)
