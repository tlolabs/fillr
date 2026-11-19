Chabot background video experiment

Run from the repository:

  python3 script/background_video.py

The command prompts for the show date and the video to loop in Comp 1. By
default it produces both a VideoToolbox hardware encode and a libx264 software
encode. Pass --date YYYY-MM-DD and --intro /path/to/video.mov for a headless job.
Use --help to see paths, duration, encoder, concurrency and tool overrides.

Direct-from-source timing test (macOS/Linux):

  python3 script/background_video.py --pipeline direct --date 2026-11-12 --intro 'CNN Downloads/Chabot News Intro November 12, 2026.mov' --encoder both

The direct pipeline decodes/deinterlaces/scales each original clip and streams
raw frames through anonymous memory pipes. The compositor encodes those frames
straight into the final H.264 MP4. It writes no normalized video or lossless
master. Only the flattened crawl and static image banners are prepared first.
Each encoder independently reads the original sources; the runs are sequential.
--jobs controls only the master pipeline: direct rendering needs every panel
stream active concurrently. This transport currently requires POSIX pass_fds.
No disk-cache flushing is performed for timing tests.

For --pipeline direct, render_encode_seconds includes source decoding, scaling,
composition and H.264 encoding. preparation_seconds covers artwork and planning
only. Compare preparation_plus_encode_seconds with the prior master pipeline's
end-to-end number; its encode_seconds alone omitted the earlier preparation.
Per-panel/per-cut raw byte counts detect incomplete frames, and the direct
consumer writes a .progress.txt file for monitoring. Output verification is
timed separately from rendering.

Direct performance experiments can set --compositor-threads (default 2),
--source-threads (default 1), and --source-filter-threads (default 1). Reports
include render-only user/system CPU seconds, equivalent occupied cores and
percentage of the machine's logical CPUs, including all waited FFmpeg children.
--test-label adds a filename-safe test identifier to the output MP4 and logs.
--source-map accepts a JSON object mapping original absolute source paths to
verified copies (for example, a temporary RAM-disk subset). Planning still reads
the original project and media tree; only selected rendering inputs are remapped.
The experiment runner must verify copy integrity and count preloading separately.

Example matching the November 12 reference:

  python3 script/background_video.py --date 2026-11-12 --intro 'CNN Downloads/Chabot News Intro November 12, 2026.mov' --encoder both

Requires Python 3.10+, FFmpeg/ffprobe with FFV1, libx264 and VideoToolbox (for
hardware output), and ImageMagick 7. Arial Bold is needed only for a date that
differs from the PSD template. Run in a normal terminal with hardware encoder
access; macOS sandboxes may prevent creating a VideoToolbox session. Hardware
output explicitly disables software fallback.

The PSD remains an editable source template. The script exports an opaque,
flattened RGB PNG before FFmpeg sees the crawl. An unchanged date retains the
cached Photoshop pixels. A changed date uses the cached labels and bullets,
renders the date with Arial Bold, and redistributes the horizontal gaps while
holding the outside edges fixed. FreeType and Photoshop antialiasing can differ.

The importer reads the saved Footage.prproj timelines, preserves source trims
and cut order, and rejects unsupported edits, overlapping clips or gaps. It
does not import arbitrary AEP files. The v27 layout, borders and two animated
crawls are a fixed template reconstructed from the supplied AEP and checked
against the Adobe reference. Later Adobe template edits need corresponding
layout changes and verification. Interlaced inputs use frame-rate-preserving
deinterlacing. A single end frame may be repeated for Premiere/MPEG rounding;
material source shortfalls and decoding errors fail the job.

A fresh dist/background-benchmark directory holds job.json, report.json,
flattened artwork, normalized FFV1 segments, a shared lossless composition,
both silent MP4 outputs, FFmpeg filter graph, command arguments and logs.
Existing output directories and files are refused. Intermediates can be large.
The MP4 target is 1920x1080, 30000/1001 fps, progressive, square pixels,
limited-range Rec.709, H.264 High/4.2, 16 Mbps VBR target/maximum, no audio.
The reference's ten minutes is exactly 17,982 frames / 599.9994 seconds.

report.json separates shared preparation, each encode and full decode checks.
Each encoder's end-to-end comparison includes the shared preparation cost.
The 9,717-second Adobe baseline is the owner's SOFTWARE encode log; the supplied
settings screenshots show hardware encoding. Hardware-vs-Adobe speedup therefore
compares different encoders. Short previews omit this ten-minute speed ratio.
Rate control, scaling, color handling and crawl rasterization can differ from
Adobe. Matching output settings does not imply identical decoded pixels.

Tests:

  python3 -m unittest discover -s script -p 'test_background_*.py' -v

Project tests create their own media/XML fixtures. FFmpeg integration tests use
synthetic media. Crawl raster tests run when the supplied PSD and ImageMagick
are available; otherwise they are explicitly skipped.

Future FILLR integration: keep the terminal prompts outside the render engine.
The explicit arguments and JSON job/report are the prototype boundary for an
asynchronous app job after folder allocation. FILLR currently bundles ffprobe
only; a rendering-capable FFmpeg and a portable crawl rasterizer must be packaged
separately before this can become an app feature. No app/release configuration
or publishing behavior is changed by this experiment.

Experimental macOS GPU path (full ten-minute renders only):

  python3 script/background_gpu.py --output-dir dist/background-benchmark/my-gpu-test --test-label MY_GPU_FULL10MIN

This prompts for date and Comp 1 video, then uses the same project plan and
flattened PSD-derived artwork. Explicit --date and --intro also work. A new
output directory is required. --prepare-only writes a job without rendering;
--run-prepared resumes that prepared job. --skip-build requires a matching
build-time source/binary hash manifest. Compilation is timed separately from
planning/artwork and full source-to-MP4 rendering. Verification is excluded
from render timing. Incomplete attempts must be labeled and kept separate from
completed full encode results.

The Python wrapper builds script/background_gpu/*.mm as a development CLI in
.build/background_gpu, using Xcode command-line tools, Homebrew FFmpeg headers/
libraries, and Apple frameworks. It does not build or distribute a macOS app.
Run with normal Metal/VideoToolbox service access; a restricted sandbox can
prevent discovery of the GPU and hardware codec services. No software encoding
fallback is allowed. The native report records the actual encoder ID and
hardware flag, source decode paths, frame counts, CPU use, memory, Metal device
and compositor GPU command times. CPU accounting excludes external hardware
codec service processes.

On this M5 Max, MPEG-2 decoding remains on the CPU. A same-size NV12 layout
conversion/upload follows it. ProRes sources now use a native VideoToolbox
decompression session which requires hardware and queries the active decoder's
hardware flag. It parses progressive/TFF/BFF structure from each ProRes packet,
preserving interlacing for Metal YADIF without CPU image decoding. Three
retained temporal source frames
feed Metal YADIF. Metal Performance Shaders performs antialiased Lanczos Y/UV
downscaling; Metal crops/composites all 15 panels and reconstructs both moving
crawls. Retained IOSurface-backed NV12 outputs go to the required hardware
VideoToolbox H.264 encoder and a compressed passthrough MP4 muxer. Queues are
bounded; no full source videos are preloaded and no intermediate video is made.

The installed FFmpeg 9.0.2 Metal YADIF filter releases autoreleased Metal
objects, causing a crash when its autorelease pool drains. The helper uses a
local ARC-owned adaptation of the upstream LGPL Metal algorithm, with explicit
first/last cut-frame handling; it does not patch the installed FFmpeg. See the
copyright/license and upstream link in GPUDeinterlacer.mm. GPU YADIF, Lanczos,
earlier 8-bit NV12 chroma reduction, chroma phase and crawl antialiasing can
differ from the CPU BWDIF/bicubic path. Compare the actual output quality; this
is not a pixel-identical substitution. Functional still checks do not count as
short video timing benchmarks.

This JSON job/native helper boundary can become a FILLR renderer, but the
current experiment adds no application UI or bundled rendering dependencies.

To encode the same saved app plan independently as H.264 and HEVC:

  python3 script/background_gpu.py --job /absolute/path/job.json --codec h264 --output-dir dist/background-benchmark/new-h264 --test-label H264
  python3 script/background_gpu.py --job /absolute/path/job.json --codec hevc --output-dir dist/background-benchmark/new-hevc --test-label HEVC --skip-build

Run these sequentially. Each reads the original footage directly and copies
the saved artwork into a new output directory. App-owned plans and artwork
are not modified. Saved plans may have any positive frame count. H.264 remains
High/4.2; HEVC uses Main 8-bit with an automatically selected level. Both require
confirmed VideoToolbox hardware encoding with no software fallback and use the
same 16 Mbps target/max. This compares throughput at matching bitrate settings,
not equal visual quality or compression efficiency. Reports record the selected
codec, actual backend, render wall/CPU time, peak process RSS, GPU timings,
output size and full decode verification. Verification and CLI compilation are
excluded from render timing. Other machine activity and filesystem cache warming
can affect sequential single-run measurements.

Converted ProRes source sets can reuse the canonical project/cuts:

  python3 script/background_gpu.py --date 2026-11-12 --intro 'CNN Downloads/Chabot News Intro November 12, 2026.mov' --source-map /absolute/path/source-map.json --require-hardware-decode --output-dir dist/background-benchmark/my-prores-test --test-label MY_PRORES_FULL10MIN

The source map is a JSON object from canonical absolute MPEG source paths to
verified ProRes MOV paths. Planning keeps the original cuts and substitutes
only the footage paths. --require-hardware-decode also checks every cut's
runtime backend report after encoding; codec capability alone cannot pass it,
and any CPU-decoded frame fails verification. The final MP4 stays silent even
when Compressor's source MOV preset includes audio. TEST-07 predates the native
ProRes decoder; its historical report correctly notes that its intro decoder
backend could not be queried through FFmpeg.

The three named ProRes experiment copies are converted by
script/background_prores.py, using the actual Compressor built-in 422, LT or
Proxy preset. It consumes a saved source inventory and writes a resumable
conversion journal, Compressor receipts, checksums, validation logs and the
source-map.json used above. --profile selects 422, lt or proxy; --state-dir
holds the journals. Existing files are not silently overwritten. Batches of
16 work with this Compressor installation; the attempted 152-source batch
failed before queue submission and its failure/queue evidence is retained.

Keep Compressor.app running normally during command-line conversion. On this
installation, CLI-only launches let its background services disappear and a
batch reported "2x job controller down". A normal application launch kept the
services alive. The converter preserves failed batch status and partial MOVs;
only a child's explicit Successful status can authorize normal verification.

Every converted MOV must match codec/profile, resolution, rate, aspect ratio,
color, complete decoded source-frame count and first-frame field parity, and
pass full decode before its MPEG copy can be removed. Removal is restricted to
the three explicit experiment folders and requires unchanged identities and
SHA-256 checksums, plus an identical retained canonical MPEG reference. Failed
or incomplete outputs do not authorize deletion. The original canonical tree
is not deleted. Fixture tests exercise these guards without owner footage.

Some MPEG files contain a valid final decoded picture without a timestamp;
Compressor can omit it. The frame-count-only fallback stream-copies MPEG-2
video and audio into a timestamp-corrected MOV, proves all compressed video
packet bytes are unchanged, and applies the same Compressor preset again.
The corrected asset's audio end is aligned to the video with -shortest. The
new ProRes file must then pass the original strict checks. The previous MOV
and repair evidence are preserved before verified replacement; this does not
relax the count check or add a lossy video generation. Other validation errors
fail without triggering repair. Conversion/import, verification and cleanup
costs are recorded separately from the full background render.
