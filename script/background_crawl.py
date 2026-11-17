"""Render the Chabot crawl from cached PSD layers without launching Adobe.

Unchanged dates use the PSD's flattened preview verbatim. Changed dates use
ImageMagick's FreeType rasterizer, so their antialiasing can differ from Photoshop.
The editable source PSD is always left untouched.
"""

from __future__ import annotations

import datetime
import hashlib
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile


_MONTHS = (
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December",
)


class _Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def take(self, size: int) -> bytes:
        if size < 0 or self.pos + size > len(self.data):
            raise ValueError("Truncated or invalid PSD layer data")
        result = self.data[self.pos:self.pos + size]
        self.pos += size
        return result

    def unpack(self, fmt: str):
        return struct.unpack(">" + fmt, self.take(struct.calcsize(">" + fmt)))

    def section(self) -> bytes:
        return self.take(self.unpack("I")[0])


def _ps_string(data: bytes, start: int) -> bytes:
    """Decode an EngineData PostScript string beginning after its opening '(' ."""
    out = bytearray()
    depth = 1
    pos = start
    while pos < len(data):
        char = data[pos]
        pos += 1
        if char == ord("\\"):
            if pos == len(data):
                break
            char = data[pos]
            pos += 1
            if char in b"01234567":
                digits = bytes([char])
                while len(digits) < 3 and pos < len(data) and data[pos] in b"01234567":
                    digits += data[pos:pos + 1]
                    pos += 1
                char = int(digits, 8)
            elif char in (10, 13):
                if char == 13 and pos < len(data) and data[pos] == 10:
                    pos += 1
                continue
            else:
                char = {110: 10, 114: 13, 116: 9, 98: 8, 102: 12}.get(char, char)
        elif char == ord("("):
            depth += 1
        elif char == ord(")"):
            depth -= 1
            if depth == 0:
                return bytes(out)
        out.append(char)
    raise ValueError("Unterminated PSD text string")


def _text_value(data: bytes, token: bytes) -> str:
    match = re.search(re.escape(token) + rb"\s*\(", data)
    if match is None:
        raise ValueError(f"PSD text property {token!r} is missing")
    raw = _ps_string(data, match.end())
    if not raw.startswith((b"\xfe\xff", b"\xff\xfe")):
        raise ValueError("PSD text does not have a Unicode byte-order marker")
    return raw.decode("utf-16").rstrip("\x00\r")


def _number(data: bytes, token: bytes) -> float:
    match = re.search(re.escape(token) + rb"\s+(-?[0-9.]+)", data)
    if match is None:
        raise ValueError(f"PSD text property {token!r} is missing")
    value = float(match.group(1))
    if not math.isfinite(value):
        raise ValueError("Nonfinite PSD text property")
    return value


def inspect_crawl(psd_path) -> dict:
    """Read the layer table and editable date properties; never rewrite the PSD."""
    reader = _Reader(Path(psd_path).read_bytes())
    if reader.take(4) != b"8BPS" or reader.unpack("H")[0] != 1:
        raise ValueError("A version-1 PSD template is required")
    reader.take(6)
    channels, height, width, depth, color = reader.unpack("HIIHH")
    if depth != 8 or color != 3 or channels not in (3, 4):
        raise ValueError("An 8-bit RGB PSD template is required")
    reader.section()  # Color-mode data.
    reader.section()  # Image resources.
    layer_mask = _Reader(reader.section())
    layer_data = _Reader(layer_mask.section())
    count = abs(layer_data.unpack("h")[0])
    layers = []
    for index in range(count):
        top, left, bottom, right, channel_count = layer_data.unpack("iiiiH")
        layer_data.take(channel_count * 6)
        if layer_data.take(4) != b"8BIM":
            raise ValueError("Invalid PSD layer blend signature")
        blend = layer_data.take(4)
        opacity, clipping, flags, _ = layer_data.unpack("BBBB")
        extra = _Reader(layer_data.section())
        mask = extra.section()
        extra.section()  # Blending ranges.
        name_length = extra.unpack("B")[0]
        name = extra.take(name_length).decode("mac_roman")
        extra.take(-(name_length + 1) % 4)
        blocks = {}
        while extra.pos + 12 <= len(extra.data):
            signature = extra.take(4)
            key = extra.take(4)
            if signature != b"8BIM":
                raise ValueError("Unsupported PSD additional-layer signature")
            value = extra.section()
            blocks[key] = value
            extra.take(len(value) % 2)
        if b"luni" in blocks:
            name_reader = _Reader(blocks[b"luni"])
            name = name_reader.take(name_reader.unpack("I")[0] * 2).decode("utf-16-be").rstrip("\x00")
        layer = {
            "name": name, "frame": index + 1, "left": left, "top": top,
            "width": right - left, "height": bottom - top,
        }
        if flags & 2 or opacity != 255 or blend != b"norm" or clipping or mask:
            raise ValueError(f"Unsupported visibility, opacity, blend, clipping, or mask on {name!r}")
        if any(key in blocks for key in (b"lfx2", b"lrFX", b"lsct", b"lsdk")):
            raise ValueError(f"Layer effects and groups are unsupported: {name!r}")
        if b"TySh" in blocks:
            tysh = blocks[b"TySh"]
            layer["text"] = _text_value(tysh, b"/Text")
            if name == "Show Date":
                transform_reader = _Reader(tysh)
                if transform_reader.unpack("H")[0] != 1:
                    raise ValueError("Unsupported Photoshop text-tool version")
                xx, xy, yx, yy, tx, ty = transform_reader.unpack("6d")
                if not all(math.isclose(a, b, abs_tol=1e-9) for a, b in zip((xx, xy, yx, yy), (1, 0, 0, 1))):
                    raise ValueError("The date text must have an unscaled, unrotated transform")
                layer.update(
                    font_size=_number(tysh, b"/FontSize"),
                    tracking=_number(tysh, b"/Tracking"),
                    caps=_number(tysh, b"/FontCaps"),
                    font_index=_number(tysh, b"/Font"),
                    font_name=_text_value(tysh[tysh.find(b"/FontSet"):], b"/Name"),
                    baseline_y=ty,
                )
                white = re.search(rb"/FillColor\s*<<\s*/Type\s+1\s*/Values\s*\[\s*1(?:\.0)?\s+1(?:\.0)?\s+1(?:\.0)?\s+1(?:\.0)?\s*\]", tysh)
                if not white or layer["font_name"] != "Arial-BoldMT" or layer["font_index"] != 0 or layer["caps"] != 2:
                    raise ValueError("Expected white, all-caps Arial Bold date text")
        elif name != "Background":
            raise ValueError(f"Unexpected non-text layer {name!r}")
        if layer["width"] <= 0 or layer["height"] <= 0:
            raise ValueError(f"Empty PSD layer {name!r}")
        layers.append(layer)
    backgrounds = [layer for layer in layers if layer["name"] == "Background"]
    dates = [layer for layer in layers if layer["name"] == "Show Date"]
    if len(backgrounds) != 1 or len(dates) != 1:
        raise ValueError("Expected one Background and one Show Date layer")
    background = backgrounds[0]
    if (background["left"], background["top"], background["width"], background["height"]) != (0, 0, width, height):
        raise ValueError("Background layer must cover the PSD canvas")
    return {"width": width, "height": height, "layers": layers, "date": dates[0]}


def _display_date(value) -> str:
    if isinstance(value, datetime.datetime):
        value = value.date()
    if isinstance(value, str):
        try:
            value = datetime.date.fromisoformat(value)
        except ValueError:
            match = re.fullmatch(r"([A-Za-z]+) ([0-9]{1,2}), ([0-9]{4})", value)
            if match is None or match[1] not in _MONTHS:
                raise ValueError("Date must be YYYY-MM-DD or Month D, YYYY") from None
            value = datetime.date(int(match[3]), _MONTHS.index(match[1]) + 1, int(match[2]))
    if not isinstance(value, datetime.date):
        raise ValueError("Date must be a datetime.date or a supported date string")
    return f"{_MONTHS[value.month - 1]} {value.day}, {value.year}"


def distribute_layers(layers: list[dict], left: int, right: int) -> tuple[list[dict], float]:
    """Distribute pixel bounds with fixed outer edges and at most 1px rounding."""
    if len(layers) < 2:
        raise ValueError("At least two crawl elements are required")
    gap = (right - left - sum(layer["width"] for layer in layers)) / (len(layers) - 1)
    if gap < 0:
        raise ValueError("The date is too wide to fit the crawl without overlapping layers")
    result = []
    cursor = float(left)
    for layer in layers:
        result.append({**layer, "left": round(cursor)})
        cursor += layer["width"] + gap
    return result, gap


def _font_path(value) -> Path:
    candidates = [Path(value)] if value else [
        Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
        Path("/Library/Fonts/Arial Bold.ttf"),
        Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts/arialbd.ttf",
        Path("/usr/share/fonts/truetype/msttcorefonts/Arial_Bold.ttf"),
        Path("/usr/share/fonts/truetype/msttcorefonts/arialbd.ttf"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError("Arial Bold font was not found; pass font_path explicitly")


def _run(magick: str, args: list[str]) -> str:
    command = [str(magick), *args]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        raise FileNotFoundError(f"ImageMagick executable was not found: {magick}") from None
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"ImageMagick failed: {exc.stderr.strip()}") from exc
    return completed.stdout


def generate_crawl(psd_path, date, output_path, magick="magick", font_path=None) -> dict:
    """Create a PNG crawl and return its geometry and fidelity metadata.

    Existing outputs are refused. Date rendering and layout are deterministic;
    all filesystem and subprocess paths are explicit, with no shell execution.
    """
    source = Path(psd_path).resolve(strict=True)
    output = Path(output_path).absolute()
    if output.suffix.lower() != ".png":
        raise ValueError("The crawl output must be a PNG file")
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"Crawl output already exists: {output}")
    template = inspect_crawl(source)
    display_date = _display_date(date)
    date_layer = template["date"]
    original_date = _display_date(date_layer["text"])
    changed = display_date != original_date
    layers = sorted(
        (layer.copy() for layer in template["layers"] if layer["name"] != "Background"),
        key=lambda layer: layer["left"],
    )
    left = layers[0]["left"]
    right = max(layer["left"] + layer["width"] for layer in layers)
    gap = None
    font = None
    with tempfile.TemporaryDirectory(prefix=".fillr-crawl-", dir=output.parent) as temp:
        work = Path(temp)
        rendered = work / "crawl.png"
        if not changed:
            _run(magick, [f"{source}[0]", "-alpha", "off", "-depth", "8", "PNG24:" + str(rendered)])
        else:
            font = _font_path(font_path)
            text_file = work / "date.txt"
            text_file.write_text(display_date.upper(), encoding="utf-8")
            date_image = work / "date.png"
            pointsize = date_layer["font_size"]
            if pointsize <= 0 or pointsize > 128:
                raise ValueError("Date font size must be between 0 and 128 pixels")
            # A generous scratch canvas avoids clipping before measuring glyphs.
            scratch_baseline = 256
            _run(magick, [
                "-size", "4096x512", "xc:none", "-font", str(font),
                "-pointsize", str(pointsize), "-kerning",
                str(date_layer["tracking"] * pointsize / 1000), "-fill", "white",
                "-annotate", f"+64+{scratch_baseline}", "@" + str(text_file),
                "-trim", str(date_image),
            ])
            geometry = _run(magick, ["identify", "-format", "%w %h %X %Y", str(date_image)]).split()
            if len(geometry) != 4:
                raise RuntimeError("ImageMagick did not return the date glyph bounds")
            date_width, date_height, _, date_top = map(int, geometry)
            for layer in layers:
                if layer["name"] == "Show Date":
                    layer.update(
                        width=date_width, height=date_height,
                        top=round(date_layer["baseline_y"] + date_top - scratch_baseline),
                    )
            layers, gap = distribute_layers(layers, left, right)
            background = next(layer for layer in template["layers"] if layer["name"] == "Background")
            args = [f"{source}[{background['frame']}]", "+repage"]
            for index, layer in enumerate(layers):
                image = date_image
                if layer["name"] != "Show Date":
                    image = work / f"layer-{index}.png"
                    _run(magick, [f"{source}[{layer['frame']}]", "+repage", str(image)])
                args.extend([
                    "(", str(image), "+repage", ")", "-geometry",
                    f"{layer['left']:+d}{layer['top']:+d}", "-compose", "Over", "-composite",
                ])
            args.extend(["-alpha", "off", "-depth", "8", "PNG24:" + str(rendered)])
            _run(magick, args)
        # The temporary file shares the output filesystem. Linking is atomic and
        # refuses an existing destination, including a concurrent writer's output.
        os.link(rendered, output)
    return {
        "output_path": str(output), "width": template["width"], "height": template["height"],
        "date": display_date, "original_date": original_date, "date_changed": changed,
        "flatten": True, "pixel_format": "rgb24", "opaque": True,
        "spacing_gap_px": gap, "antialiasing_approximation": changed,
        "fidelity_note": (
            "Only the changed date is rasterized with FreeType; Photoshop antialiasing may differ. "
            "Other text and bullets retain the cached PSD pixels."
            if changed else "The original flattened PSD pixels are preserved without rerasterizing text."
        ),
        "font_path": str(font) if font else None,
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "layers": layers,
    }
