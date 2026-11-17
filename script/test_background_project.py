"""Self-contained checks for importing Premiere background edit decisions."""

import gzip
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from background_project import ProjectError, TICKS_PER_SECOND, load_project


FRAME_TICKS = 8_475_667_200  # One frame at 30000/1001 fps.
VIDEO_MEDIA_TYPE = "228cda18-3625-4d2d-951e-348879e4ed93"


def child(parent, tag, text=None, **attributes):
    node = ET.SubElement(parent, tag, attributes)
    if text is not None:
        node.text = str(text)
    return node


class BackgroundProjectTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.media_root = self.root / "CNN Downloads"
        self.media_root.mkdir()
        self.project_file = self.root / "test.prproj"
        self.document = ET.Element("PremiereData", Version="3")

        sequence = child(self.document, "Sequence", ObjectUID="sequence")
        child(sequence, "Name", "Comp 1")
        group_ref = child(child(sequence, "TrackGroups"), "TrackGroup")
        child(group_ref, "First", VIDEO_MEDIA_TYPE)
        child(group_ref, "Second", ObjectRef="group")
        group = child(self.document, "VideoTrackGroup", ObjectID="group")
        track_group = child(group, "TrackGroup")
        tracks = child(track_group, "Tracks")
        child(track_group, "FrameRate", FRAME_TICKS)
        child(group, "FrameRect", "0,0,1920,1080")
        child(child(group, "ComponentOwner"), "Components", ObjectRef="group-effects")
        child(child(self.document, "VideoComponentChain", ObjectID="group-effects"), "ComponentChain")

        self.track_items = {}
        for index, uid in enumerate(("background", "video")):
            child(tracks, "Track", Index=str(index), ObjectURef=uid)
            track = child(self.document, "VideoClipTrack", ObjectUID=uid)
            clip_track = child(track, "ClipTrack")
            child(child(clip_track, "Track"), "Index", index)
            self.track_items[uid] = child(child(clip_track, "ClipItems"), "TrackItems")
            child(clip_track, "TransitionItems")

        self.add_clip("background", "guide.jpg", 0, 4, 0, "background")
        # Deliberately place references in reverse order and use filenames whose
        # alphabetical order differs from their position in the edit.
        self.add_clip("second", "a-second.mpg", 2, 2, 3, "video")
        self.add_clip("first", "z-first.mpg", 0, 2, 1, "video")

    def node(self, object_id):
        return next(node for node in self.document if node.get("ObjectID") == object_id)

    def add_clip(self, identifier, filename, start, duration, source_in, track):
        (self.media_root / filename).write_bytes(b"Synthetic media: no decoding is required by the importer.")
        child(self.track_items[track], "TrackItem", ObjectRef=f"item-{identifier}")
        item = child(self.document, "VideoClipTrackItem", ObjectID=f"item-{identifier}")
        clip_item = child(item, "ClipTrackItem")
        child(child(clip_item, "ComponentOwner"), "Components", ObjectRef=f"effects-{identifier}")
        timing = child(clip_item, "TrackItem")
        child(timing, "Start", start * FRAME_TICKS)
        child(timing, "End", (start + duration) * FRAME_TICKS)
        child(clip_item, "SubClip", ObjectRef=f"subclip-{identifier}")

        subclip = child(self.document, "SubClip", ObjectID=f"subclip-{identifier}")
        child(subclip, "Name", filename)
        child(subclip, "Clip", ObjectRef=f"clip-{identifier}")
        clip = child(child(self.document, "VideoClip", ObjectID=f"clip-{identifier}"), "Clip")
        child(clip, "Source", ObjectRef=f"source-{identifier}")
        child(clip, "InPoint", source_in * FRAME_TICKS)
        child(clip, "OutPoint", (source_in + duration) * FRAME_TICKS)

        source = child(self.document, "VideoMediaSource", ObjectID=f"source-{identifier}")
        child(child(source, "MediaSource"), "Media", ObjectURef=f"media-{identifier}")
        media = child(self.document, "Media", ObjectUID=f"media-{identifier}")
        child(media, "FilePath", f"/a/different/machine/CNN Downloads/{filename}")
        child(media, "VideoStream", ObjectRef=f"stream-{identifier}")
        stream = child(self.document, "VideoStream", ObjectID=f"stream-{identifier}")
        child(stream, "FrameRate", FRAME_TICKS)
        child(stream, "FrameRect", "0,0,1920,1080")
        child(stream, "OriginalFieldType", "1")

        effects = child(self.document, "VideoComponentChain", ObjectID=f"effects-{identifier}")
        child(effects, "DefaultMotion", "true")
        child(effects, "DefaultOpacity", "true")
        child(effects, "ComponentChain")

    def load(self, compressed=False):
        data = ET.tostring(self.document)
        self.project_file.write_bytes(gzip.compress(data) if compressed else data)
        return load_project(self.project_file, self.media_root)["Comp 1"]

    def test_edit_order_source_trims_and_exact_ticks_survive_both_file_encodings(self):
        for compressed in (False, True):
            with self.subTest(compressed=compressed):
                sequence = self.load(compressed)
                first, second = sequence["segments"]
                self.assertEqual([segment["name"] for segment in sequence["segments"]],
                                 ["z-first.mpg", "a-second.mpg"])
                self.assertEqual(sequence["frame_rate"], {"numerator": 30000, "denominator": 1001})
                self.assertEqual(first["source_in_ticks"], FRAME_TICKS)
                self.assertEqual(first["source_out_ticks"], 3 * FRAME_TICKS)
                self.assertEqual(first["duration_frames"], 2)
                self.assertEqual(second["start_ticks"], 2 * FRAME_TICKS)
                self.assertEqual(second["source_in_seconds"], 3 * FRAME_TICKS / TICKS_PER_SECOND)
                self.assertEqual(sequence["duration_ticks"], 4 * FRAME_TICKS)
                self.assertEqual(Path(first["path"]), self.media_root / "z-first.mpg")
                self.assertEqual(len(sequence["background_segments"]), 1)
                self.assertEqual(sequence["unsupported"], [])
                self.assertEqual(sequence["gaps"], [])

    def test_subframe_edit_is_preserved_without_rounding_to_whole_frames(self):
        self.node("item-first").find("ClipTrackItem/TrackItem/End").text = str(2 * FRAME_TICKS + 7)
        self.node("clip-first").find("Clip/OutPoint").text = str(3 * FRAME_TICKS + 7)
        self.node("item-second").find("ClipTrackItem/TrackItem/Start").text = str(2 * FRAME_TICKS + 7)
        self.node("item-second").find("ClipTrackItem/TrackItem/End").text = str(4 * FRAME_TICKS + 7)
        sequence = self.load()
        self.assertEqual(sequence["segments"][0]["duration_ticks"], 2 * FRAME_TICKS + 7)
        self.assertIsNone(sequence["segments"][0]["duration_frames"])
        self.assertEqual(sequence["duration_ticks"], 4 * FRAME_TICKS + 7)
        self.assertEqual(sequence["gaps"], [])
        self.assertEqual(sequence["unsupported"], [])

    def test_source_frame_rate_difference_is_exposed(self):
        self.node("stream-first").find("FrameRate").text = str(TICKS_PER_SECOND // 25)
        first, second = self.load()["segments"]
        self.assertTrue(first["frame_rate_mismatch"])
        self.assertEqual(first["source_frame_rate"], {"numerator": 25, "denominator": 1})
        self.assertFalse(second["frame_rate_mismatch"])

    def test_initial_and_internal_gaps_are_preserved(self):
        for identifier, start, end in (("first", 1, 3), ("second", 4, 6)):
            item = self.node(f"item-{identifier}")
            item.find("ClipTrackItem/TrackItem/Start").text = str(start * FRAME_TICKS)
            item.find("ClipTrackItem/TrackItem/End").text = str(end * FRAME_TICKS)
        sequence = self.load()
        self.assertEqual([(gap["start_ticks"], gap["duration_ticks"]) for gap in sequence["gaps"]],
                         [(0, FRAME_TICKS), (3 * FRAME_TICKS, FRAME_TICKS)])
        self.assertEqual(sequence["unsupported"], [])

    def test_overlapping_clips_require_compositing(self):
        self.node("item-first").find("ClipTrackItem/TrackItem/End").text = str(3 * FRAME_TICKS)
        self.node("clip-first").find("Clip/OutPoint").text = str(4 * FRAME_TICKS)
        sequence = self.load()
        self.assertEqual(sequence["overlaps"], [{"start_ticks": 2 * FRAME_TICKS, "duration_ticks": FRAME_TICKS}])
        self.assertTrue(any("overlapping" in issue for issue in sequence["unsupported"]))

    def test_retiming_is_reported_instead_of_silently_changing_playback(self):
        self.node("clip-first").find("Clip/OutPoint").text = str(2 * FRAME_TICKS)
        self.assertTrue(any("retimed clip" in issue for issue in self.load()["unsupported"]))

    def test_sequence_and_clip_effects_are_reported(self):
        child(self.node("group-effects").find("ComponentChain"), "Components", ObjectRef="unknown-effect")
        self.node("effects-first").find("DefaultOpacity").text = "false"
        issues = self.load()["unsupported"]
        self.assertIn("Sequence has custom video effects", issues)
        self.assertTrue(any("z-first.mpg: custom effects or transforms" in issue for issue in issues))

    def test_transitions_and_muted_tracks_are_reported(self):
        track = next(node for node in self.document if node.get("ObjectUID") == "video")
        child(track.find("ClipTrack/Track"), "IsMuted", "true")
        child(track.find("ClipTrack/TransitionItems"), "TrackItem", ObjectRef="transition")
        issues = self.load()["unsupported"]
        self.assertIn("Track 1 has transitions", issues)
        self.assertIn("Track 1 is muted", issues)

    def test_missing_media_fails_with_the_rebased_path(self):
        (self.media_root / "z-first.mpg").unlink()
        with self.assertRaisesRegex(ProjectError, "Missing media:.*z-first.mpg"):
            self.load()

    def test_media_outside_the_asset_tree_is_rejected(self):
        media = next(node for node in self.document if node.get("ObjectUID") == "media-first")
        for source in ("/old/CNN Downloads/../escape.mpg", "/unrelated/z-first.mpg"):
            with self.subTest(source=source):
                media.find("FilePath").text = source
                with self.assertRaises(ProjectError):
                    self.load()

    def test_symlink_cannot_escape_the_asset_tree(self):
        outside = self.root / "outside.mpg"
        outside.write_bytes(b"outside asset root")
        local = self.media_root / "z-first.mpg"
        local.unlink()
        local.symlink_to(outside)
        with self.assertRaisesRegex(ProjectError, "outside the asset tree"):
            self.load()

    def test_unresolved_source_reference_fails_explicitly(self):
        self.node("clip-first").find("Clip/Source").set("ObjectRef", "missing-source")
        with self.assertRaisesRegex(ProjectError, "Unresolved VideoMediaSource reference"):
            self.load()


if __name__ == "__main__":
    unittest.main()
