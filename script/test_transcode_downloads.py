import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock

import transcode_downloads as td


def args(**kwargs):
    return argparse.Namespace(include_existing=False, settle_seconds=.01, keep_mpeg=True,
        ffmpeg=shutil.which('ffmpeg'), ffprobe=shutil.which('ffprobe'), **kwargs)


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_filters_and_nested_output_exclusion(self):
        for name in ('good.mpg', '#work_file#bad.mpg', '.hidden.mov', 'bad.part.mp4', 'audio.wav'):
            (self.root / name).touch()
        output = self.root / td.OUTPUT_FOLDER
        output.mkdir()
        (output / 'finished.mov').touch()
        (self.root / 'alias.mov').symlink_to(self.root / 'good.mpg')
        self.assertEqual([p.name for p in td.candidates(self.root)], ['good.mpg'])

    def test_signiant_and_browser_companions(self):
        source = self.root / 'story.mpg'
        source.touch()
        for name in ('#work_file#story.mpg', '#chkpt_file#story.mpg', 'story.mpg.crdownload',
                     '#WORK_FILE#STORY.MPG', '#ChkPt_FiLe#sToRy.MpG', 'STORY.MPG.CRDOWNLOAD'):
            companion = self.root / name
            companion.touch()
            self.assertTrue(td.companions(source))
            companion.unlink()
        self.assertFalse(td.companions(source))

    @mock.patch.object(td, 'is_closed', return_value=True)
    def test_later_file_settles_from_its_observation_after_slow_encode(self, closed):
        earlier = self.root / 'a-earlier.mpg'
        later = self.root / 'b-later.mpg'
        earlier.write_bytes(b'first video')
        later.write_bytes(b'later video')
        options = args()
        options.include_existing = True
        options.settle_seconds = 30
        watcher = td.Watcher(self.root, options)
        watcher.observed[earlier] = (td.fingerprint(earlier), 0)
        clock = [31]

        def slow_transcode(source, root, expected, options):
            if source == earlier:
                clock[0] += 180
            return 'complete'

        old_mtime = max(td.fingerprint(path)[3] for path in (earlier, later))
        with mock.patch.object(td.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(td.time, 'time_ns', return_value=old_mtime + 1_000_000_000_000), \
                mock.patch.object(td, 'transcode', side_effect=slow_transcode) as transcode:
            watcher.scan()
            self.assertEqual(transcode.call_count, 1)
            clock[0] += 2
            watcher.scan()
            self.assertEqual(transcode.call_count, 1)
            clock[0] += 28
            watcher.scan()
            self.assertEqual(transcode.call_count, 2)
            self.assertEqual(transcode.call_args.args[0], later)

    @mock.patch.object(td, 'is_closed', return_value=True)
    @mock.patch.object(td, 'transcode', return_value='complete')
    def test_new_settled_file_once_and_changed_file_again(self, transcode, closed):
        old = self.root / 'existing.mpg'
        old.write_bytes(b'old')
        watcher = td.Watcher(self.root, args())
        new = self.root / 'new.mpg'
        new.write_bytes(b'video')
        watcher.scan()
        transcode.assert_not_called()
        time.sleep(.02)
        watcher.scan()
        self.assertEqual(transcode.call_count, 1)
        watcher.scan()
        self.assertEqual(transcode.call_count, 1)
        new.write_bytes(b'changed')
        watcher.scan()
        time.sleep(.02)
        watcher.scan()
        self.assertEqual(transcode.call_count, 2)

    @mock.patch.object(td, 'is_closed', return_value=False)
    @mock.patch.object(td, 'transcode')
    def test_open_file_never_converted(self, transcode, closed):
        source = self.root / 'open.mpg'
        source.write_bytes(b'video')
        watcher = td.Watcher(self.root, args())
        watcher.scan()
        time.sleep(.02)
        watcher.scan()
        transcode.assert_not_called()

    def test_lsof_error_fails_closed(self):
        with mock.patch.object(td.subprocess, 'run', return_value=argparse.Namespace(returncode=1, stdout='', stderr='not permitted')):
            with self.assertRaises(RuntimeError):
                td.is_closed(self.root / 'file.mpg')

    def test_command_preserves_audio_and_interlace(self):
        metadata = {'streams': [{'index': 0, 'codec_type': 'video', 'field_order': 'tt'}]}
        command = td.command_for('in.mpg', 'out.mov', metadata, 'ffmpeg')
        self.assertIn('0:a?', command)
        self.assertIn('+ildct', command)
        self.assertNotIn('-top', command)
        self.assertEqual(command[command.index('-profile:v') + 1], '1')
        self.assertNotIn('-r', command)


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg tools required')
class IntegrationTests(unittest.TestCase):
    def test_multitrack_audio_with_audio_first_input_preserves_samples_and_sync(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'multitrack.mpg'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                'testsrc2=size=160x120:rate=30000/1001', '-f', 'lavfi', '-i',
                'sine=frequency=440:sample_rate=48000', '-itsoffset', '0.017', '-f', 'lavfi', '-i',
                'sine=frequency=880:sample_rate=44100', '-map', '1:a', '-map', '0:v', '-map', '2:a',
                '-t', '0.8', '-c:v', 'mpeg2video', '-c:a', 'mp2', '-ac:a:0', '1', '-ac:a:1', '2',
                '-ar:a:0', '48000', '-ar:a:1', '44100', str(source)], check=True)
            before = td.probe(source, args().ffprobe, count=True)
            self.assertEqual(before['streams'][0]['codec_type'], 'audio')
            with mock.patch.object(td, 'is_closed', return_value=True):
                output = Path(td.transcode(source, root, td.fingerprint(source), args()))
            after = td.probe(output, args().ffprobe, count=True)
            tracks = td.verify_audio(before, after)
            self.assertEqual([track['sample_rate'] for track in tracks], [48000, 44100])
            self.assertEqual([track['channels'] for track in tracks], [1, 2])
            self.assertTrue(all(track['samples'] > 0 for track in tracks))
            saved = json.loads(output.with_suffix('.json').read_text())
            self.assertEqual(saved['verification_version'], td.VERIFICATION_VERSION)
            self.assertEqual(saved['audio_tracks'], tracks)

    def test_altered_audio_never_publishes_or_trashes_original(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'clip.mpg'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                'testsrc2=size=160x120:rate=30000/1001', '-f', 'lavfi', '-i',
                'sine=frequency=440:sample_rate=48000', '-t', '0.5', '-c:v', 'mpeg2video',
                '-c:a', 'mp2', str(source)], check=True)
            original = source.read_bytes()
            options = args()
            options.keep_mpeg = False
            encoder_command = td.command_for
            cases = [(['-af', 'atrim=duration=0.1'], 'samples changed'),
                     (['-af', 'asetpts=PTS+0.02/TB'], 'synchronization changed'),
                     (['-ar', '44100'], 'sample_rate changed'),
                     (['-ac', '2'], 'channels changed'),
                     (['-c:a', 'pcm_s16le'], '24-bit PCM')]
            for alterations, message in cases:
                with self.subTest(alterations=alterations):
                    def altered_command(*arguments):
                        command = encoder_command(*arguments)
                        index = command.index('-movie_timescale')
                        command[index:index] = alterations
                        return command

                    with mock.patch.object(td, 'is_closed', return_value=True), \
                            mock.patch.object(td, 'command_for', side_effect=altered_command), \
                            mock.patch.object(td, 'discard_verified_mpeg') as trash:
                        with self.assertRaisesRegex(ValueError, message):
                            td.transcode(source, root, td.fingerprint(source), options)
                        trash.assert_not_called()
                    self.assertEqual(source.read_bytes(), original)
                    self.assertFalse(list(root.rglob('*.mov')))
                    self.assertFalse(list(root.rglob('*.json')))

    def test_missing_audio_observations_retain_original(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'clip.mpg'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                'testsrc2=size=160x120:rate=25', '-f', 'lavfi', '-i',
                'sine=frequency=440:sample_rate=48000', '-t', '0.2', '-c:v', 'mpeg2video',
                '-c:a', 'mp2', str(source)], check=True)
            options = args()
            options.keep_mpeg = False
            probe = td.probe

            def incomplete_probe(path, ffprobe, count=False):
                result = probe(path, ffprobe, count)
                if path.suffix == '.mov' and count:
                    next(frame for frame in result['frames'] if frame['media_type'] == 'audio').pop('nb_samples')
                return result

            with mock.patch.object(td, 'is_closed', return_value=True), \
                    mock.patch.object(td, 'probe', side_effect=incomplete_probe), \
                    mock.patch.object(td, 'discard_verified_mpeg') as trash:
                with self.assertRaisesRegex(ValueError, 'audio sample counts'):
                    td.transcode(source, root, td.fingerprint(source), options)
                trash.assert_not_called()
            self.assertTrue(source.exists())
            self.assertFalse(list(root.rglob('*.mov')))

    def test_real_conversion_receipt_restart_and_source_retention(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'clip.mpg'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x120:rate=30000/1001',
                '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '0.5',
                '-c:v', 'mpeg2video', '-flags', '+ildct+ilme', '-vf', 'setfield=tff',
                '-field_order', 'tt', '-c:a', 'mp2', str(source)], check=True)
            original = source.read_bytes()
            stamp = td.fingerprint(source)
            with mock.patch.object(td, 'is_closed', return_value=True):
                output = Path(td.transcode(source, root, stamp, args()))
                self.assertTrue(output.exists())
                self.assertEqual(td.transcode(source, root, stamp, args()), 'already completed')
                self.assertEqual(source.read_bytes(), original)
                self.assertFalse(list(output.parent.glob('*.partial.mov')))
                metadata = td.probe(output, args().ffprobe, count=True)
                result = td.video(metadata)
                self.assertEqual(result['profile'], 'LT')
                self.assertTrue(all(fields == (1, 1) for fields in td.video_fields(metadata)))
                source.write_bytes(original + b'changed')
                with self.assertRaises(FileExistsError):
                    td.transcode(source, root, td.fingerprint(source), args())

    def test_existing_prores_is_not_transcoded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'already.mov'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                'testsrc2=size=160x120:rate=25', '-t', '0.2', '-c:v', 'prores_ks',
                '-profile:v', '1', str(source)], check=True)
            with mock.patch.object(td, 'is_closed', return_value=True), \
                    mock.patch.object(td, 'command_for', side_effect=AssertionError('must not encode')):
                result = td.transcode(source, root, td.fingerprint(source), args())
            self.assertIn('already ProRes', result)
            self.assertTrue(source.exists())

    def test_bottom_field_first_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'bottom-first.mpg'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                'testsrc2=size=160x120:rate=25', '-t', '0.2', '-c:v', 'mpeg2video',
                '-flags', '+ildct+ilme', '-vf', 'setfield=bff', '-field_order', 'bb', str(source)], check=True)
            with mock.patch.object(td, 'is_closed', return_value=True):
                output = Path(td.transcode(source, root, td.fingerprint(source), args()))
            fields = td.video_fields(td.probe(output, args().ffprobe, count=True))
            self.assertTrue(fields)
            self.assertTrue(all(field == (1, 0) for field in fields))

    def test_changed_published_output_is_never_trusted_on_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'clip.mpg'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                'testsrc2=size=160x120:rate=25', '-t', '0.2', '-c:v', 'mpeg2video', str(source)], check=True)
            original = source.read_bytes()
            stamp = td.fingerprint(source)
            options = args()
            options.keep_mpeg = False
            discard = td.discard_verified_mpeg

            def corrupt_before_trash(source, expected, output, receipt, options):
                output.write_bytes(b'corrupted after verification')
                return discard(source, expected, output, receipt, options)

            with mock.patch.object(td, 'is_closed', return_value=True), \
                    mock.patch.object(td, 'discard_verified_mpeg', side_effect=corrupt_before_trash):
                with self.assertRaisesRegex(ValueError, 'Output changed'):
                    td.transcode(source, root, stamp, options)

            output = root / td.OUTPUT_FOLDER / (source.name + '.ProResLT.mov')
            receipt = output.with_suffix('.json')
            recorded = json.loads(receipt.read_text())
            self.assertNotEqual(recorded['output_fingerprint'], td.fingerprint(output))
            with mock.patch.object(td, 'discard_verified_mpeg') as trash:
                with self.assertRaises(FileExistsError):
                    td.transcode(source, root, stamp, options)
                trash.assert_not_called()
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(json.loads(receipt.read_text()), recorded)

    def test_trash_only_after_success_and_unchanged_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, output, receipt = root / 'source.mpg', root / 'output.mov', root / 'receipt.json'
            source.write_bytes(b'original')
            output.write_bytes(b'verified output')
            stamp = td.fingerprint(source)
            td.atomic_json(receipt, {'source_codec': 'mpeg2video', 'verification_version': td.VERIFICATION_VERSION,
                                     'output_fingerprint': td.fingerprint(output)})
            options = args()
            options.keep_mpeg = False
            with mock.patch.object(td, 'is_closed', return_value=True), \
                    mock.patch.object(td.subprocess, 'run', return_value=argparse.Namespace(stdout='fixture Trash path')) as run:
                td.discard_verified_mpeg(source, stamp, output, receipt, options)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][2], str(source))
                source.write_bytes(b'changed source')
                with self.assertRaises(RuntimeError):
                    td.discard_verified_mpeg(source, stamp, output, receipt, options)
                self.assertEqual(run.call_count, 1)
                output.write_bytes(b'changed output')
                with self.assertRaises(ValueError):
                    td.discard_verified_mpeg(source, td.fingerprint(source), output, receipt, options)
                self.assertEqual(run.call_count, 1)

    def test_legacy_receipt_never_authorizes_trash(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, output, receipt = root / 'source.mpg', root / 'output.mov', root / 'receipt.json'
            source.write_bytes(b'original')
            output.write_bytes(b'output verified by older watcher')
            stamp = td.fingerprint(source)
            td.atomic_json(receipt, {'source_codec': 'mpeg2video', 'source_fingerprint': stamp,
                                     'output_fingerprint': td.fingerprint(output)})
            options = args()
            options.keep_mpeg = False
            with mock.patch.object(td.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'current media verification'):
                    td.discard_verified_mpeg(source, stamp, output, receipt, options)
                run.assert_not_called()
            self.assertTrue(source.exists())

    def test_encoder_failure_retains_source_without_trash(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'clip.mpg'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                'testsrc2=size=160x120:rate=25', '-t', '0.2', '-c:v', 'mpeg2video', str(source)], check=True)
            options = args()
            options.keep_mpeg = False
            with mock.patch.object(td, 'is_closed', return_value=True), \
                    mock.patch.object(td, 'command_for', return_value=['/usr/bin/false']), \
                    mock.patch.object(td, 'discard_verified_mpeg') as trash:
                with self.assertRaises(subprocess.CalledProcessError):
                    td.transcode(source, root, td.fingerprint(source), options)
                trash.assert_not_called()
            self.assertTrue(source.exists())
            self.assertFalse(list(root.rglob('*.mov')))

    def test_corrupt_source_no_published_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'broken.mp4'
            source.write_bytes(b'not video')
            with mock.patch.object(td, 'is_closed', return_value=True):
                with self.assertRaises(subprocess.CalledProcessError):
                    td.transcode(source, root, td.fingerprint(source), args())
            self.assertFalse(list(root.rglob('*.mov')))
            self.assertTrue(source.exists())


def metadata(output=False):
    tick = Fraction(1, 90000)
    start = Fraction(0) if output else Fraction(27, 50)
    stream = {'index': 0, 'codec_type': 'video', 'codec_name': 'mpeg2video',
              'width': 160, 'height': 120, 'nb_read_frames': '3',
              'time_base': '1/90000', 'r_frame_rate': '30000/1001'}
    if output:
        stream.update(codec_name='prores', profile='LT', codec_tag_string='apcs',
                      pix_fmt='yuv422p10le')
    frames = [{'media_type': 'video', 'stream_index': 0, 'interlaced_frame': 0,
               'best_effort_timestamp_time': f'{float(start + index * 3003 * tick):.6f}',
               'duration_time': f'{float(3003 * tick):.6f}'} for index in range(3)]
    return {'streams': [stream], 'frames': frames}


class MockedConversionTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='fillr-no-media-regression-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.source = self.root / 'source-placeholder.mpg'
        self.original = b'PLACEHOLDER BYTES: NOT MEDIA'
        self.source.write_bytes(self.original)
        self.options = argparse.Namespace(ffmpeg='mock-ffmpeg', ffprobe='mock-ffprobe', keep_mpeg=False)

    def invoke(self, before=None, after=None, fail_encoder=False):
        def run(command, **kwargs):
            if fail_encoder:
                kwargs['stderr'].write('mock encoder failed\n')
                raise subprocess.CalledProcessError(1, command)
            if str(command[-1]).endswith('.partial.mov'):
                Path(command[-1]).write_bytes(b'PLACEHOLDER OUTPUT: NOT MEDIA')
            return subprocess.CompletedProcess(command, 0)
        before = before or metadata()
        after = after or metadata(output=True)
        with mock.patch.object(td, 'probe', side_effect=[before, before, after]), \
             mock.patch.object(td, 'is_closed', return_value=True), \
             mock.patch.object(td.subprocess, 'run', side_effect=run), \
             mock.patch.object(td, 'discard_verified_mpeg') as trash:
            try:
                result = td.transcode(self.source, self.root, td.fingerprint(self.source), self.options)
            finally:
                self.trash_called = trash.called
        return Path(result)

    def assert_unpublished(self):
        self.assertFalse(list((self.root / td.OUTPUT_FOLDER).glob('*.mov')))
        self.assertFalse(self.trash_called)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_constant_timestamp_offset_and_microsecond_rounding_are_allowed(self):
        result = self.invoke()
        self.assertTrue(result.is_file())
        self.assertTrue(self.trash_called)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_silent_video_with_changed_duration_is_not_published(self):
        after = metadata(output=True)
        for frame in after['frames']:
            frame['best_effort_timestamp_time'] = str(2 * Fraction(frame['best_effort_timestamp_time']))
            frame['duration_time'] = str(2 * Fraction(frame['duration_time']))
        with self.assertRaisesRegex(ValueError, '(?i)(video|timing|timestamp|duration)'):
            self.invoke(after=after)
        self.assert_unpublished()

    def test_internal_video_timestamp_drift_is_not_hidden_by_matching_endpoints(self):
        after = metadata(output=True)
        after['frames'][1]['best_effort_timestamp_time'] = str(
            Fraction(after['frames'][1]['best_effort_timestamp_time']) + Fraction(1, 100))
        with self.assertRaisesRegex(ValueError, '(?i)(video|timing|timestamp|duration)'):
            self.invoke(after=after)
        self.assert_unpublished()

    def test_missing_decoded_timestamp_is_not_published(self):
        before = metadata()
        del before['frames'][1]['best_effort_timestamp_time']
        with self.assertRaisesRegex(ValueError, '(?i)(video|timing|timestamp|duration)'):
            self.invoke(before=before)
        self.assert_unpublished()

    def test_existing_symlink_or_hardlink_log_cannot_truncate_source(self):
        for hardlink in (False, True):
            with self.subTest(hardlink=hardlink):
                self.source.write_bytes(self.original)
                log = self.root / td.OUTPUT_FOLDER / (self.source.name + '.ProResLT.mov.log')
                log.parent.mkdir(exist_ok=True)
                if hardlink:
                    os.link(self.source, log)
                else:
                    log.symlink_to(self.source)
                try:
                    with self.assertRaises((OSError, ValueError, subprocess.CalledProcessError)):
                        self.invoke(fail_encoder=True)
                    self.assertEqual(self.source.read_bytes(), self.original)
                    self.assertFalse(log.is_symlink())
                    self.assertNotEqual(log.stat().st_ino, self.source.stat().st_ino)
                    self.assertEqual(log.read_text(), 'mock encoder failed\n')
                    self.assertFalse(list(log.parent.glob('.*.tmp')))
                    self.assert_unpublished()
                finally:
                    log.unlink(missing_ok=True)

    def test_log_publication_failure_removes_private_log(self):
        log = self.root / td.OUTPUT_FOLDER / (self.source.name + '.ProResLT.mov.log')
        log.mkdir(parents=True)
        with self.assertRaises(OSError):
            self.invoke(fail_encoder=True)
        self.assertTrue(log.is_dir())
        self.assertFalse(list(log.parent.glob('.*.tmp')))
        self.assert_unpublished()


class TimingAndReceiptTests(unittest.TestCase):
    setUp = MockedConversionTests.setUp
    invoke = MockedConversionTests.invoke
    assert_unpublished = MockedConversionTests.assert_unpublished

    def test_one_clock_tick_and_microsecond_rounding_are_allowed(self):
        after = metadata(output=True)
        after['frames'][1]['best_effort_timestamp_time'] = str(
            Fraction(after['frames'][1]['best_effort_timestamp_time']) + Fraction(1, 90000))
        self.assertTrue(self.invoke(after=after).is_file())

    def test_nonpositive_frame_duration_is_not_published(self):
        for duration in ('0', '-0.033367'):
            with self.subTest(duration=duration):
                after = metadata(output=True)
                after['frames'][1]['duration_time'] = duration
                with self.assertRaisesRegex(ValueError, '(?i)(video|duration)'):
                    self.invoke(after=after)
                self.assert_unpublished()

    def test_version_two_receipt_retains_source_until_current_verification(self):
        output, receipt = self.root / 'existing-placeholder.mov', self.root / 'existing-receipt.json'
        output.write_bytes(b'OLD PLACEHOLDER OUTPUT: NOT MEDIA')
        stamp = td.fingerprint(self.source)
        td.atomic_json(receipt, {'source_codec': 'mpeg2video', 'verification_version': 2,
                                'source_fingerprint': stamp,
                                'output_fingerprint': td.fingerprint(output)})
        with mock.patch.object(td.subprocess, 'run', side_effect=AssertionError('Unexpected Trash')):
            with self.assertRaisesRegex(ValueError, 'current media verification'):
                td.discard_verified_mpeg(self.source, stamp, output, receipt, self.options)
            self.options.keep_mpeg = True
            td.discard_verified_mpeg(self.source, stamp, output, receipt, self.options)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(json.loads(receipt.read_text())['verification_version'], 2)


class ObservationScanTests(unittest.TestCase):
    def test_first_or_changed_observation_skips_unneeded_companion_scan(self):
        with tempfile.TemporaryDirectory(prefix='fillr-observation-test-') as temp:
            root = Path(temp)
            path = root / 'empty-placeholder.mpg'
            path.touch()
            stamp = td.fingerprint(path)
            for changed in (False, True):
                with self.subTest(changed=changed):
                    watcher = td.Watcher(root, argparse.Namespace(include_existing=True, settle_seconds=30))
                    if changed:
                        old_stamp = stamp.copy()
                        old_stamp[-1] -= 1
                        watcher.observed[path] = (old_stamp, 0)
                    with mock.patch.object(td, 'cached_companions', side_effect=AssertionError('Unneeded directory scan')), \
                         mock.patch.object(td, 'is_closed', side_effect=AssertionError('Unexpected closure check')), \
                         mock.patch.object(td, 'transcode', side_effect=AssertionError('Unexpected transcode')):
                        watcher.scan()
                    self.assertEqual(watcher.observed[path][0], stamp)
                    self.assertFalse(watcher.done)

    def test_unchanged_observation_still_checks_companions_and_resets_settling(self):
        with tempfile.TemporaryDirectory(prefix='fillr-observation-test-') as temp:
            root = Path(temp)
            path = root / 'empty-placeholder.mpg'
            path.touch()
            stamp = td.fingerprint(path)
            watcher = td.Watcher(root, argparse.Namespace(include_existing=True, settle_seconds=30))
            watcher.observed[path] = (stamp, 0)
            (root / ('#work_file#' + path.name)).touch()
            with mock.patch.object(td, 'cached_companions', wraps=td.cached_companions) as companion, \
                 mock.patch.object(td, 'is_closed', side_effect=AssertionError('Unexpected closure check')), \
                 mock.patch.object(td, 'transcode', side_effect=AssertionError('Unexpected transcode')):
                watcher.scan()
            self.assertEqual(companion.call_count, 1)
            self.assertEqual(companion.call_args.args[0], path)
            self.assertGreater(watcher.observed[path][1], 0)
            self.assertFalse(watcher.done)


class CompanionCacheTests(unittest.TestCase):
    def test_startup_reuses_enumeration_but_checks_each_eligible_file_is_closed(self):
        with tempfile.TemporaryDirectory(prefix='fillr-companion-cache-') as temp:
            root = Path(temp)
            paths = [root / f'empty-{index}.mpg' for index in range(3)]
            for path in paths:
                path.touch()
            with mock.patch.object(td.os, 'scandir', wraps=td.os.scandir) as scan, \
                 mock.patch.object(td, 'is_closed', return_value=True) as closed:
                watcher = td.Watcher(root, argparse.Namespace(include_existing=False))
            self.assertEqual(scan.call_count, 2)  # os.walk plus one marker listing.
            self.assertEqual(closed.call_count, len(paths))
            self.assertEqual(set(watcher.baseline), set(paths))

    def test_startup_refreshes_markers_after_earlier_closure_check(self):
        with tempfile.TemporaryDirectory(prefix='fillr-companion-cache-') as temp:
            root = Path(temp)
            earlier, later = root / 'a-earlier.mpg', root / 'b-later.mpg'
            earlier.touch()
            later.touch()

            def closed(path):
                if path == earlier:
                    (root / ('#work_file#' + later.name)).touch()
                return True

            with mock.patch.object(td, 'is_closed', side_effect=closed) as closure_check:
                watcher = td.Watcher(root, argparse.Namespace(include_existing=False))
            self.assertEqual(set(watcher.baseline), {earlier})
            closure_check.assert_called_once_with(earlier)

    def test_unchanged_directory_is_enumerated_once_and_new_membership_invalidates(self):
        with tempfile.TemporaryDirectory(prefix='fillr-companion-cache-') as temp:
            root = Path(temp)
            paths = [root / f'empty-{index}.mpg' for index in range(3)]
            for path in paths:
                path.touch()
            cache = {}
            with mock.patch.object(td.os, 'scandir', wraps=td.os.scandir) as scan:
                self.assertEqual([td.cached_companions(path, cache) for path in paths], [False] * 3)
                self.assertEqual(scan.call_count, 1)
                marker = root / ('#WORK_FILE#' + paths[-1].name.upper())
                marker.touch()
                self.assertTrue(td.cached_companions(paths[-1], cache))
                self.assertEqual(scan.call_count, 2)
                marker.unlink()
                self.assertFalse(td.cached_companions(paths[-1], cache))
                self.assertEqual(scan.call_count, 3)

    def test_marker_arriving_during_slow_encode_resets_later_file_observation(self):
        with tempfile.TemporaryDirectory(prefix='fillr-companion-cache-') as temp:
            root = Path(temp)
            earlier, later = root / 'a-earlier.mpg', root / 'b-later.mpg'
            for path in (earlier, later):
                path.write_bytes(b'NOT MEDIA')
                os.utime(path, (0, 0))
            watcher = td.Watcher(root, argparse.Namespace(include_existing=True, settle_seconds=30))
            watcher.observed = {path: (td.fingerprint(path), 0) for path in (earlier, later)}
            clock = [31]
            marker = root / ('#work_file#' + later.name)

            def slow_encode(source, *unused):
                if source == earlier:
                    marker.touch()
                    clock[0] += 180
                return 'mock complete'

            with mock.patch.object(td.time, 'monotonic', side_effect=lambda: clock[0]), \
                 mock.patch.object(td, 'is_closed', return_value=True), \
                 mock.patch.object(td, 'transcode', side_effect=slow_encode) as convert:
                watcher.scan()
                self.assertEqual(convert.call_count, 1)
                self.assertEqual(watcher.observed[later][1], 211)
                marker.unlink()
                clock[0] += 20
                watcher.scan()
                self.assertEqual(convert.call_count, 1)
                clock[0] += 10
                watcher.scan()
                self.assertEqual(convert.call_count, 2)
                self.assertEqual(convert.call_args.args[0], later)

    def test_directory_read_or_stat_failure_and_membership_race_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix='fillr-companion-cache-') as temp:
            path = Path(temp) / 'empty-placeholder.mpg'
            path.touch()
            with mock.patch.object(td.os, 'scandir', side_effect=PermissionError('fixture')):
                with self.assertRaises(PermissionError):
                    td.cached_companions(path, {})
            with mock.patch.object(td, '_directory_stamp', side_effect=PermissionError('fixture')):
                with self.assertRaises(PermissionError):
                    td.cached_companions(path, {})
            before = td._directory_stamp(path.parent)
            changed = (*before[:-1], before[-1] + 1)
            cache = {}
            with mock.patch.object(td, '_directory_stamp', side_effect=[before, changed]):
                with self.assertRaisesRegex(RuntimeError, 'Directory changed'):
                    td.cached_companions(path, cache)
            self.assertFalse(cache)


class FreshConversionGuardTests(unittest.TestCase):
    setUp = MockedConversionTests.setUp
    invoke = MockedConversionTests.invoke

    def test_conversion_rechecks_uncached_companions(self):
        with mock.patch.object(td, 'cached_companions', side_effect=AssertionError('Cached safety guard')), \
             mock.patch.object(td, 'companions', return_value=False) as companions:
            self.assertTrue(self.invoke().is_file())
        self.assertEqual(companions.call_count, 3)

    def test_trash_rechecks_uncached_companions(self):
        output, receipt = self.root / 'output-placeholder.mov', self.root / 'receipt.json'
        output.touch()
        stamp = td.fingerprint(self.source)
        td.atomic_json(receipt, {'source_codec': 'mpeg2video', 'verification_version': td.VERIFICATION_VERSION,
                                'output_fingerprint': td.fingerprint(output)})
        with mock.patch.object(td, 'cached_companions', side_effect=AssertionError('Cached safety guard')), \
             mock.patch.object(td, 'companions', return_value=True) as companions, \
             mock.patch.object(td.subprocess, 'run', side_effect=AssertionError('Unexpected Trash')):
            with self.assertRaisesRegex(RuntimeError, 'Source changed or reopened'):
                td.discard_verified_mpeg(self.source, stamp, output, receipt, self.options)
        companions.assert_called_once_with(self.source)
        self.assertEqual(self.source.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
