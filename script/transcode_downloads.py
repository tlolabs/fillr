#!/usr/bin/env python3
"""Watch completed downloads and create non-destructive ProRes 422 LT copies."""
from __future__ import annotations

import argparse
import fcntl
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

VIDEO_EXTENSIONS = {'.mpg', '.mpeg', '.m2v', '.mov', '.mp4', '.mxf', '.ts', '.m2ts', '.avi', '.mkv', '.m4v'}
OUTPUT_FOLDER = 'ProRes LT'
TEMP_MARKERS = ('#work_file#', '#chkpt_file#', '.crdownload', '.download', '.partial', '.part', '.tmp')
VERIFICATION_VERSION = 3


def fingerprint(path):
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise ValueError(f'Not a regular file: {path}')
    return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns]


def candidates(root):
    for directory, folders, files in os.walk(root, followlinks=False):
        folders[:] = [name for name in folders if not name.startswith('.') and name != OUTPUT_FOLDER
                      and not any(marker in name.lower() for marker in TEMP_MARKERS)
                      and not (Path(directory) / name).is_symlink()]
        for name in sorted(files):
            path = Path(directory) / name
            if (not name.startswith('.') and path.suffix.lower() in VIDEO_EXTENSIONS
                    and not any(marker in name.lower() for marker in TEMP_MARKERS)
                    and not path.is_symlink()):
                yield path


def companions(path):
    # Signiant prefixes its work/checkpoint files. Browsers usually append suffixes.
    return any(other != path and path.name.casefold() in other.name.casefold()
               and any(marker in other.name.lower() for marker in TEMP_MARKERS)
               for other in path.parent.iterdir())


def _directory_stamp(path):
    info = path.stat()
    return info.st_dev, info.st_ino, info.st_mtime_ns, info.st_ctime_ns


def cached_companions(path, cache):
    """Reuse marker names during one readiness pass, checking membership changes.

    Conversion and Trash authorization continue to use uncached companions().
    """
    directory = path.parent
    before = _directory_stamp(directory)
    saved = cache.get(directory)
    if saved is None or saved[0] != before:
        with os.scandir(directory) as entries:
            names = tuple(entry.name.casefold() for entry in entries
                          if any(marker in entry.name.lower() for marker in TEMP_MARKERS))
        if _directory_stamp(directory) != before:
            cache.pop(directory, None)
            raise RuntimeError('Directory changed while checking work companions; will retry')
        saved = cache[directory] = (before, names)
    name = path.name.casefold()
    return any(name in other for other in saved[1])


def is_closed(path):
    result = subprocess.run(['lsof', '-nP', '-Fpf', '--', str(path)],
                            capture_output=True, text=True, timeout=10)
    if result.returncode == 0:
        return False
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return True
    raise RuntimeError(f'Cannot establish closed-file state: {result.stderr.strip()}')


def probe(path, ffprobe, count=False):
    command = [ffprobe, '-v', 'error', '-fflags', '+genpts']
    if count:
        command += ['-count_frames', '-show_frames', '-show_entries',
                    'frame=media_type,stream_index,interlaced_frame,top_field_first,nb_samples,best_effort_timestamp_time,duration_time:stream:format']
    command += ['-show_streams', '-show_format', '-of', 'json', str(path)]
    result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=3600)
    if result.stderr.strip():
        raise ValueError(f'Media probe reported errors: {result.stderr[-1000:]}')
    return json.loads(result.stdout)


def video(metadata):
    return next(stream for stream in metadata['streams'] if stream['codec_type'] == 'video'
                and not stream.get('disposition', {}).get('attached_pic'))


def video_fields(metadata):
    stream = video(metadata)
    fields = []
    for frame in metadata.get('frames', []):
        if frame.get('media_type') != 'video' or frame.get('stream_index') != stream['index']:
            continue
        interlaced = frame.get('interlaced_frame')
        top_first = frame.get('top_field_first')
        if interlaced not in (0, 1) or (interlaced and top_first not in (0, 1)):
            raise ValueError('Cannot establish decoded video field order')
        fields.append((interlaced, top_first if interlaced else 0))
    if len(fields) != int(stream.get('nb_read_frames', '0')):
        raise ValueError('Decoded video field observations are incomplete')
    return fields


def decoded_frames(metadata, stream):
    frames = [frame for frame in metadata.get('frames', [])
              if frame.get('media_type') == stream['codec_type'] and frame.get('stream_index') == stream['index']]
    if not frames or len(frames) != int(stream.get('nb_read_frames', '0')):
        raise ValueError('Decoded media observations are incomplete')
    return frames


def media_time(value):
    try:
        return Fraction(str(value))
    except (ValueError, ZeroDivisionError):
        raise ValueError('Cannot establish decoded media timestamps') from None


def clock_tick(stream):
    tick = media_time(stream.get('time_base'))
    if tick <= 0:
        raise ValueError('Cannot establish media clock precision')
    return tick


def video_span(metadata):
    frames = decoded_frames(metadata, video(metadata))
    start = media_time(frames[0].get('best_effort_timestamp_time'))
    duration = media_time(frames[-1].get('duration_time'))
    if duration <= 0:
        raise ValueError('Cannot establish decoded video duration')
    return start, media_time(frames[-1].get('best_effort_timestamp_time')) + duration


def verify_video_timing(source, result):
    original, output = video(source), video(result)
    before, after = decoded_frames(source, original), decoded_frames(result, output)
    if len(before) != len(after):
        raise ValueError('Decoded video frame counts differ')
    # -start_at_zero may shift the whole timeline. Preserve every relative PTS
    # and frame duration, allowing both stream clocks and ffprobe's rounding.
    tolerance = clock_tick(original) + clock_tick(output) + Fraction(4, 1_000_000)
    source_start = media_time(before[0].get('best_effort_timestamp_time'))
    output_start = media_time(after[0].get('best_effort_timestamp_time'))
    for source_frame, output_frame in zip(before, after):
        source_time = media_time(source_frame.get('best_effort_timestamp_time')) - source_start
        output_time = media_time(output_frame.get('best_effort_timestamp_time')) - output_start
        source_duration = media_time(source_frame.get('duration_time'))
        output_duration = media_time(output_frame.get('duration_time'))
        if source_duration <= 0 or output_duration <= 0:
            raise ValueError('Cannot establish decoded video duration')
        if abs(output_time - source_time) > tolerance:
            raise ValueError('Decoded video timestamp changed')
        if abs(output_duration - source_duration) > tolerance:
            raise ValueError('Decoded video frame duration changed')


def audio_observation(metadata, stream):
    rate = int(stream.get('sample_rate', '0'))
    channels = int(stream.get('channels', 0))
    layout = stream.get('channel_layout')
    if rate <= 0 or channels <= 0 or not layout or layout == 'unknown':
        raise ValueError('Cannot establish audio sample rate or channel layout')
    frames = decoded_frames(metadata, stream)
    start = media_time(frames[0].get('best_effort_timestamp_time'))
    samples = 0
    # FFprobe prints timestamps to microseconds. Allow only that rounding and
    # this stream's timestamp clock; gaps or missing decoded samples fail closed.
    tolerance = 2 * clock_tick(stream) + Fraction(2, 1_000_000)
    for frame in frames:
        count = int(frame.get('nb_samples', 0))
        if count <= 0:
            raise ValueError('Cannot establish decoded audio sample counts')
        timestamp = media_time(frame.get('best_effort_timestamp_time'))
        if abs(timestamp - start - Fraction(samples, rate)) > tolerance:
            raise ValueError('Decoded audio timeline contains a gap or overlap')
        samples += count
    end = timestamp + Fraction(count, rate)
    return {'sample_rate': rate, 'channels': channels, 'channel_layout': layout,
            'samples': samples, 'start': start, 'end': end}


def verify_audio(source, result):
    source_tracks = [stream for stream in source['streams'] if stream['codec_type'] == 'audio']
    output_tracks = [stream for stream in result['streams'] if stream['codec_type'] == 'audio']
    if len(source_tracks) != len(output_tracks):
        raise ValueError('Audio stream count changed')
    if not source_tracks:
        return []
    source_video, output_video = video(source), video(result)
    source_video_start, source_video_end = video_span(source)
    output_video_start, output_video_end = video_span(result)
    summaries = []
    for original, output in zip(source_tracks, output_tracks):
        if output.get('codec_name') != 'pcm_s24le' or int(output.get('bits_per_sample', 0)) != 24:
            raise ValueError('Output audio is not 24-bit PCM')
        before, after = audio_observation(source, original), audio_observation(result, output)
        for key in ('sample_rate', 'channels', 'channel_layout', 'samples'):
            if before[key] != after[key]:
                raise ValueError(f'Audio {key} changed')
        # The encoder keeps the input video clock and uses a microsecond MOV
        # movie timescale. Do not hide timing errors inside a video-frame-wide
        # tolerance; account for all four track clocks and PCM sample rounding.
        tolerance = (clock_tick(original) + clock_tick(output)
                     + clock_tick(source_video) + clock_tick(output_video)
                     + Fraction(2, before['sample_rate']) + Fraction(6, 1_000_000))
        if abs((after['end'] - after['start']) - (before['end'] - before['start'])) > tolerance:
            raise ValueError('Decoded audio duration changed')
        if (abs((after['start'] - output_video_start) - (before['start'] - source_video_start)) > tolerance
                or abs((after['end'] - output_video_end) - (before['end'] - source_video_end)) > tolerance):
            raise ValueError('Audio/video synchronization changed')
        summaries.append({key: after[key] for key in ('sample_rate', 'channels', 'channel_layout', 'samples')})
    return summaries


def command_for(source, target, metadata, ffmpeg):
    stream = video(metadata)
    command = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-xerror', '-nostdin', '-n',
               '-copyts', '-start_at_zero', '-fflags', '+genpts', '-i', str(source),
               '-map', f"0:{stream['index']}", '-map', '0:a?',
               '-map_metadata', '0', '-c:v', 'prores_ks', '-profile:v', '1',
               '-pix_fmt', 'yuv422p10le', '-threads', '4', '-enc_time_base:v', 'demux', '-fps_mode', 'passthrough',
               '-c:a', 'pcm_s24le']
    fields = stream.get('field_order')
    if fields in ('tt', 'tb', 'bb', 'bt'):
        # Decoded frames already carry their own interlace/parity flags. Keep
        # them instead of forcing -top, removed from newer FFmpeg versions.
        command += ['-flags:v', '+ildct', '-field_order', fields]
    for key, option in [('color_range', '-color_range'), ('color_space', '-colorspace'),
                        ('color_transfer', '-color_trc'), ('color_primaries', '-color_primaries')]:
        value = stream.get(key)
        if value and value not in ('unknown', 'unspecified', 'reserved'):
            command += [option, value]
    return command + ['-movie_timescale', '1000000', '-f', 'mov', str(target)]


def atomic_json(path, data):
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        temporary.write_text(json.dumps(data, indent=2) + '\n')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def discard_verified_mpeg(source, expected, output, receipt, args):
    if getattr(args, 'keep_mpeg', False):
        return
    saved = json.loads(receipt.read_text())
    if saved.get('source_codec') != 'mpeg2video' or source.suffix.lower() not in {'.mpg', '.mpeg', '.m2v'}:
        return
    if saved.get('verification_version') != VERIFICATION_VERSION:
        raise ValueError('Receipt lacks current media verification; original retained')
    if saved.get('output_fingerprint') != fingerprint(output):
        raise ValueError('Output changed; original retained')
    if fingerprint(source) != expected or companions(source) or not is_closed(source):
        raise RuntimeError('Source changed or reopened; original retained')
    helper = Path(__file__).with_name('trash_verified_source.swift')
    result = subprocess.run(['/usr/bin/swift', str(helper), str(source), *map(str, expected)],
                            capture_output=True, text=True, check=True, timeout=120)
    saved['trashed_source'] = result.stdout.strip()
    atomic_json(receipt, saved)
    print(f'Original moved to Trash: {source}', flush=True)


def transcode(source, root, expected, args):
    relative = source.relative_to(root)
    directory = root / OUTPUT_FOLDER / relative.parent
    # Keep the source extension in the filename to avoid foo.mpg/foo.mp4 collisions.
    output = directory / (source.name + '.ProResLT.mov')
    receipt = output.with_suffix('.json')
    if directory.is_symlink() or any(p.is_symlink() for p in directory.parents if root in p.parents):
        raise ValueError('Symlinked output directory is not supported')
    directory.mkdir(parents=True, exist_ok=True)
    if output.exists() or output.is_symlink():
        if receipt.is_file() and not receipt.is_symlink():
            saved = json.loads(receipt.read_text())
            if saved.get('source_fingerprint') == expected and saved.get('output_fingerprint') == fingerprint(output):
                discard_verified_mpeg(source, expected, output, receipt, args)
                return 'already completed'
        raise FileExistsError(f'Output already exists or source changed; leaving it untouched: {output}')
    if fingerprint(source) != expected or companions(source) or not is_closed(source):
        raise RuntimeError('Source changed or reopened before conversion; will retry')
    metadata = probe(source, args.ffprobe)
    source_video = video(metadata)
    if source_video.get('codec_name') == 'prores':
        return 'already ProRes; retained without conversion'
    metadata = probe(source, args.ffprobe, count=True)
    source_video = video(metadata)
    frames = int(source_video.get('nb_read_frames', '0'))
    if frames <= 0:
        raise ValueError('Source has no decodable video frames')
    source_fields = video_fields(metadata)
    if fingerprint(source) != expected or companions(source) or not is_closed(source):
        raise RuntimeError('Source changed during probe; will retry')
    temporary = directory / ('.' + output.name + '.' + uuid.uuid4().hex + '.partial.mov')
    logfile = directory / (output.name + '.log')
    try:
        log_temporary = None
        try:
            # A predictable existing log may be a link to the source. Write a
            # new private file and replace only the final directory entry.
            with tempfile.NamedTemporaryFile(mode='w', prefix='.' + logfile.name + '.',
                                             suffix='.tmp', dir=directory, delete=False) as log:
                log_temporary = Path(log.name)
                subprocess.run(command_for(source, temporary, metadata, args.ffmpeg), stdout=log,
                               stderr=log, stdin=subprocess.DEVNULL, check=True)
                # Verify the entire result, not merely the MOV header.
                subprocess.run([args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-xerror', '-nostdin',
                                '-i', str(temporary), '-map', '0:v:0', '-map', '0:a?', '-f', 'null', '-'],
                               stdout=log, stderr=log, stdin=subprocess.DEVNULL, check=True)
        finally:
            if log_temporary is not None:
                try:
                    os.replace(log_temporary, logfile)
                except OSError:
                    try:
                        log_temporary.unlink(missing_ok=True)
                    except OSError:
                        print(f'Could not remove provisional conversion log: {log_temporary}',
                              file=sys.stderr, flush=True)
                    raise
        result = probe(temporary, args.ffprobe, count=True)
        out = video(result)
        for key, value in [('codec_name', 'prores'), ('profile', 'LT'), ('codec_tag_string', 'apcs'),
                           ('pix_fmt', 'yuv422p10le'), ('width', source_video['width']),
                           ('height', source_video['height'])]:
            if out.get(key) != value:
                raise ValueError(f'Output {key} mismatch: {out.get(key)!r} != {value!r}')
        # MPEG and MOV can report different stream field_order enums for the
        # same decoded parity; compare every actual frame instead.
        if video_fields(result) != source_fields:
            raise ValueError('Interlaced field order changed')
        if int(out.get('nb_read_frames', '0')) != frames:
            raise ValueError('Decoded source and output frame counts differ')
        verify_video_timing(metadata, result)
        audio_tracks = verify_audio(metadata, result)
        if fingerprint(source) != expected or companions(source) or not is_closed(source):
            raise RuntimeError('Source changed or reopened during conversion; discarding provisional output')
        # Atomic no-clobber publication, even if another program creates the destination.
        os.link(temporary, output)
        # Drop our extra hard link before recording the final ctime. Cleanup must
        # never update this receipt: an output changed after verification must
        # stay untrusted on every later attempt, even when Trash was refused.
        temporary.unlink()
        atomic_json(receipt, {'source': str(source), 'source_fingerprint': expected,
                             'output_fingerprint': fingerprint(output), 'profile': 'ProRes 422 LT',
                             'verification_version': VERIFICATION_VERSION, 'audio_tracks': audio_tracks,
                             'frames': frames, 'source_codec': source_video.get('codec_name'), 'verified_at': time.strftime('%Y-%m-%dT%H:%M:%S%z')})
        discard_verified_mpeg(source, expected, output, receipt, args)
        return str(output)
    finally:
        temporary.unlink(missing_ok=True)


class Watcher:
    def __init__(self, root, args):
        self.root, self.args = root, args
        self.observed = {}
        self.done = {}
        self.retry_after = {}
        self.baseline = {}
        if not args.include_existing:
            companion_cache = {}
            for path in candidates(root):
                try:
                    if not cached_companions(path, companion_cache) and is_closed(path):
                        self.baseline[path] = fingerprint(path)
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                    pass

    def scan(self):
        seen = set()
        companion_cache = {}
        for path in candidates(self.root):
            seen.add(path)
            try:
                stamp = fingerprint(path)
                if self.baseline.get(path) == stamp or self.done.get(path) == stamp:
                    continue
                previous = self.observed.get(path)
                if previous is None or previous[0] != stamp:
                    self.observed[path] = (stamp, time.monotonic())
                    continue
                has_companion = cached_companions(path, companion_cache)
                # Earlier candidates can spend minutes encoding. Observe this
                # file at its actual check time, after the companion scan too.
                now = time.monotonic()
                if has_companion:
                    self.observed[path] = (stamp, now)
                    continue
                if (stamp[2] == 0 or now - previous[1] < self.args.settle_seconds
                        or time.time_ns() - stamp[3] < self.args.settle_seconds * 1e9
                        or self.retry_after.get(path, 0) > now or not is_closed(path)):
                    continue
                print(f'Transcoding: {path}', flush=True)
                result = transcode(path, self.root, stamp, self.args)
                self.done[path] = stamp
                print(f'Completed: {result}', flush=True)
            except (OSError, ValueError, RuntimeError, StopIteration, subprocess.SubprocessError) as exc:
                self.retry_after[path] = time.monotonic() + 60
                print(f'Pending/retry in 60s: {path}: {exc}', file=sys.stderr, flush=True)
        for mapping in (self.observed, self.done, self.baseline, self.retry_after):
            for path in set(mapping) - seen:
                del mapping[path]


def tool(name):
    return shutil.which(name) or next((str(p) for p in (Path('/opt/homebrew/bin') / name,
        Path('/usr/local/bin') / name) if os.access(p, os.X_OK)), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folders', nargs='*', type=Path, help='Default: project CNN Downloads, Desktop/CNN Downloads and ~/Downloads')
    parser.add_argument('--keep-mpeg', action='store_true', help='Keep MPEG originals instead of moving verified conversions to Trash')
    parser.add_argument('--include-existing', action='store_true', help='Also transcode footage already present at startup')
    parser.add_argument('--settle-seconds', type=float, default=30)
    parser.add_argument('--poll-interval', type=float, default=2)
    parser.add_argument('--ffmpeg', default=tool('ffmpeg'))
    parser.add_argument('--ffprobe', default=tool('ffprobe'))
    args = parser.parse_args()
    for key in ('settle_seconds', 'poll_interval'):
        if not math.isfinite(getattr(args, key)) or getattr(args, key) <= 0:
            parser.error(f'{key} must be finite and positive')
    if not args.ffmpeg or not args.ffprobe or not shutil.which('lsof'):
        parser.error('ffmpeg, ffprobe and lsof are required; no software is installed automatically')
    folders = args.folders or [p for p in [Path(__file__).resolve().parent.parent / 'CNN Downloads',
        Path.home() / 'Desktop' / 'CNN Downloads', Path.home() / 'Downloads'] if p.is_dir()]
    if not folders:
        parser.error('No default download folders exist; pass a folder explicitly')
    roots = []
    for folder in folders:
        root = folder.expanduser().resolve()
        if not root.is_dir():
            parser.error(f'Watch folder does not exist: {root}')
        if not any(root == other or other in root.parents for other in roots):
            roots = [other for other in roots if root not in other.parents] + [root]
    locks = []
    try:
        for root in sorted(roots):
            lock_path = root / '.fillr-prores-lt.lock'
            fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            lock = os.fdopen(fd, 'w')
            locks.append(lock)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                parser.error(f'Another transcoder already watches {root}')
        watchers = [Watcher(root, args) for root in roots]
        print('Watching: ' + ', '.join(map(str, roots)), flush=True)
        print('New/changed footage only.' if not args.include_existing else 'Including existing footage.', flush=True)
        print('Copies go into ProRes LT subfolders. Verified MPEG originals move to Trash (unless --keep-mpeg). Control-C stops.', flush=True)
        while True:
            for watcher in watchers:
                watcher.scan()
            time.sleep(args.poll_interval)
    except KeyboardInterrupt:
        print('\nStopped; unfinished originals retained. Retry unfinished conversions with --include-existing.')
    finally:
        for lock in locks:
            lock.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
