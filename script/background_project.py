#!/usr/bin/env python3
"""Read the cut-only Premiere sequences used by the Chabot background project.

This module has no Adobe, FFmpeg, or GUI dependency. It preserves Premiere ticks
alongside convenient seconds so a future FILLR caller can choose its own render
strategy. Unsupported edits are reported, never treated as matching renders.
"""

from __future__ import annotations

import argparse
import gzip
import json
from fractions import Fraction
from pathlib import Path, PurePosixPath
import xml.etree.ElementTree as ET


TICKS_PER_SECOND = 254_016_000_000
STILL_EXTENSIONS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".psd"}


class ProjectError(ValueError):
    """The saved project cannot be interpreted safely by this importer."""


def _integer(element: ET.Element, path: str, default: int = 0) -> int:
    try:
        return int(element.findtext(path, str(default)))
    except (TypeError, ValueError) as exc:
        raise ProjectError(f"Invalid integer at {element.tag}/{path}") from exc


def _rate(frame_ticks: int) -> dict[str, int]:
    if frame_ticks <= 0:
        raise ProjectError("Missing or invalid video frame duration")
    rate = Fraction(TICKS_PER_SECOND, frame_ticks)
    return {"numerator": rate.numerator, "denominator": rate.denominator}


def _has_custom_components(components: ET.Element) -> bool:
    chain = components.find("ComponentChain")
    return chain is None or any(child.tag != "Node" for child in chain)


def _local_media(source: str, media_root: Path) -> Path:
    # Rebase the asset tree, never use an old machine's absolute source path.
    parts = PurePosixPath(source.replace("\\", "/")).parts
    try:
        relative_parts = parts[parts.index("CNN Downloads") + 1 :]
    except ValueError as exc:
        raise ProjectError(f"Media is outside the CNN Downloads asset tree: {source}") from exc
    if not relative_parts or any(part in {"..", "."} for part in relative_parts):
        raise ProjectError(f"Invalid relative media path: {source}")
    local = media_root.joinpath(*relative_parts).resolve()
    if not local.is_relative_to(media_root):
        raise ProjectError(f"Media resolves outside the asset tree: {source}")
    if not local.is_file():
        raise ProjectError(f"Missing media: {local}")
    return local


def load_project(prproj_path: str | Path, media_root: str | Path) -> dict[str, dict]:
    """Return ``Comp N -> sequence metadata`` with ordered clip segments.

    Each sequence contains ``segments``, ``frame_rate``, ``gaps``, ``overlaps``,
    and ``unsupported``. Segments expose ``path``, ``start_seconds``,
    ``duration_seconds``, and ``source_in_seconds``, plus exact tick values.
    ``background_segments`` retains the lower still-image track. A caller must
    reject nonempty ``unsupported`` before claiming faithful reproduction.
    Original sequence durations are retained; the renderer applies its desired
    output duration rather than this reader silently truncating source edits.
    """
    media_root = Path(media_root).expanduser().resolve()
    raw = Path(prproj_path).expanduser().read_bytes()
    if raw.startswith(b"\x1f\x8b"):
        raw = gzip.decompress(raw)
    try:
        document = ET.fromstring(raw)
    except ET.ParseError as exc:
        raise ProjectError(f"Invalid Premiere XML: {exc}") from exc
    if document.tag != "PremiereData":
        raise ProjectError("Expected a PremiereData project")
    by_id = {node.attrib["ObjectID"]: node for node in document if "ObjectID" in node.attrib}
    by_uid = {node.attrib["ObjectUID"]: node for node in document if "ObjectUID" in node.attrib}

    def resolve(node: ET.Element | None, expected: str | None = None) -> ET.Element:
        if node is None:
            raise ProjectError("A required project reference is missing")
        target = (by_id.get(node.get("ObjectRef")) if "ObjectRef" in node.attrib
                  else by_uid.get(node.get("ObjectURef")))
        if target is None or (expected is not None and target.tag != expected):
            raise ProjectError(f"Unresolved {expected or 'object'} reference: {node.attrib}")
        return target

    result = {}
    for sequence in document.findall("Sequence"):
        name = sequence.findtext("Name", "")
        if not name.startswith("Comp "):
            continue
        if name in result:
            raise ProjectError(f"Duplicate sequence name: {name}")
        video_groups = [
            resolve(entry.find("Second"))
            for entry in sequence.findall("TrackGroups/TrackGroup")
            if entry.findtext("First") == "228cda18-3625-4d2d-951e-348879e4ed93"
        ]
        if len(video_groups) != 1 or video_groups[0].tag != "VideoTrackGroup":
            raise ProjectError(f"{name}: expected one video track group")
        group = video_groups[0]
        frame_ticks = _integer(group, "TrackGroup/FrameRate")
        sequence_rate = _rate(frame_ticks)
        unsupported = []
        tracks = []
        group_components = resolve(group.find("ComponentOwner/Components"), "VideoComponentChain")
        if _has_custom_components(group_components):
            unsupported.append("Sequence has custom video effects")

        for track_ref in group.findall("TrackGroup/Tracks/Track"):
            track = resolve(track_ref, "VideoClipTrack")
            clip_track = track.find("ClipTrack")
            if clip_track is None:
                raise ProjectError(f"{name}: missing ClipTrack")
            track_index = _integer(clip_track, "Track/Index")
            transitions = clip_track.find("TransitionItems")
            if transitions is not None and any(
                "ObjectRef" in node.attrib or "ObjectURef" in node.attrib
                for node in transitions.iter()
            ):
                unsupported.append(f"Track {track_index} has transitions")
            if clip_track.findtext("Track/IsMuted", "false") == "true":
                unsupported.append(f"Track {track_index} is muted")
            segments = []
            for item_ref in clip_track.findall("ClipItems/TrackItems/TrackItem"):
                item = resolve(item_ref, "VideoClipTrackItem")
                subclip = resolve(item.find("ClipTrackItem/SubClip"), "SubClip")
                clip = resolve(subclip.find("Clip"), "VideoClip")
                source = resolve(clip.find("Clip/Source"), "VideoMediaSource")
                media = resolve(source.find("MediaSource/Media"), "Media")
                source_path = media.findtext("FilePath")
                if not source_path:
                    raise ProjectError(f"{name}: clip has no file path")
                local = _local_media(source_path, media_root)
                start = _integer(item, "ClipTrackItem/TrackItem/Start")
                end = _integer(item, "ClipTrackItem/TrackItem/End")
                source_in = _integer(clip, "Clip/InPoint")
                source_out = _integer(clip, "Clip/OutPoint")
                if end <= start or source_in < 0 or source_out <= source_in:
                    raise ProjectError(f"{name}: invalid timing for {local.name}")
                if source_out - source_in != end - start:
                    unsupported.append(f"Track {track_index}, {local.name}: retimed clip")
                components = resolve(item.find("ClipTrackItem/ComponentOwner/Components"), "VideoComponentChain")
                if (components.findtext("DefaultMotion") != "true"
                        or components.findtext("DefaultOpacity") != "true"
                        or _has_custom_components(components)):
                    unsupported.append(f"Track {track_index}, {local.name}: custom effects or transforms")
                stream = resolve(media.find("VideoStream"), "VideoStream")
                stream_frame_ticks = _integer(stream, "FrameRate", frame_ticks)
                frames = Fraction(end - start, frame_ticks)
                segments.append({
                    "path": str(local), "name": subclip.findtext("Name", local.name),
                    "start_seconds": start / TICKS_PER_SECOND,
                    "duration_seconds": (end - start) / TICKS_PER_SECOND,
                    "source_in_seconds": source_in / TICKS_PER_SECOND,
                    "start_ticks": start, "end_ticks": end,
                    "duration_ticks": end - start, "source_in_ticks": source_in,
                    "source_out_ticks": source_out,
                    "duration_frames": frames.numerator if frames.denominator == 1 else None,
                    "source_frame_rate": _rate(stream_frame_ticks),
                    "frame_rate_mismatch": stream_frame_ticks != frame_ticks,
                    "source_frame_rect": stream.findtext("FrameRect"),
                    "source_field_type": stream.findtext("OriginalFieldType"),
                })
            segments.sort(key=lambda segment: segment["start_ticks"])
            tracks.append({"index": track_index, "segments": segments})
        tracks.sort(key=lambda track: track["index"])
        nonempty = [track for track in tracks if track["segments"]]
        if not nonempty:
            raise ProjectError(f"{name}: no video clips")
        selected = nonempty[-1]
        backgrounds = [segment for track in nonempty[:-1] for segment in track["segments"]]
        if len(nonempty) > 2 or any(Path(segment["path"]).suffix.lower() not in STILL_EXTENSIONS for segment in backgrounds):
            unsupported.append("Multiple active video tracks require compositing")
        gaps, overlaps = [], []
        previous_end = 0
        for segment in selected["segments"]:
            start, end = segment["start_ticks"], segment["end_ticks"]
            if start > previous_end:
                gaps.append({"start_ticks": previous_end, "duration_ticks": start - previous_end,
                             "start_seconds": previous_end / TICKS_PER_SECOND,
                             "duration_seconds": (start - previous_end) / TICKS_PER_SECOND})
            elif start < previous_end:
                overlaps.append({"start_ticks": start, "duration_ticks": previous_end - start})
            previous_end = max(previous_end, end)
        if overlaps:
            unsupported.append("Selected video track has overlapping clips")
        result[name] = {
            "segments": selected["segments"], "background_segments": backgrounds,
            "video_track_index": selected["index"], "frame_rate": sequence_rate,
            "frame_duration_ticks": frame_ticks, "ticks_per_second": TICKS_PER_SECOND,
            "duration_ticks": previous_end, "duration_seconds": previous_end / TICKS_PER_SECOND,
            "frame_rect": group.findtext("FrameRect"),
            "gaps": gaps, "overlaps": overlaps, "unsupported": sorted(set(unsupported)),
        }
    if not result:
        raise ProjectError("No Comp N sequences were found")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--media-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        project = load_project(args.project, args.media_root)
    except (OSError, ProjectError, gzip.BadGzipFile) as exc:
        parser.exit(2, f"{exc}\n")
    print(json.dumps(project, indent=2))
    return int(any(sequence["unsupported"] for sequence in project.values()))


if __name__ == "__main__":
    raise SystemExit(main())
