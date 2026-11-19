# Automatic download → ProRes 422 LT

Double-click **Start FILLR Download Monitor.command** in the FILLR project.
Keep that Terminal window open; Control-C stops the watcher. This is a standalone
script, not an installed login service or a change to the FILLR app binary.

By default it watches these existing folders recursively:

- the project's `CNN Downloads`
- `~/Desktop/CNN Downloads`
- `~/Downloads`

Only newly arriving or changed footage is queued by default. Existing closed files
are baselined, so starting it does not unexpectedly transcode the entire archive.
To catch up after a stopped/interrupted session, or select different folders:

```sh
python3 script/transcode_downloads.py --include-existing '/path/to/CNN Downloads'
python3 script/transcode_downloads.py ~/Downloads
```

Each source gets a verified copy at `ProRes LT/<relative path>/<original name including extension>.ProResLT.mov`
inside its watched root. Audio tracks are retained as 24-bit PCM. Full decoding checks each track's sample count, sample rate, channel layout, duration, and synchronization with video. Missing or inconsistent observations retain the original. Receipts made before these audio checks cannot authorize Trash. Frame count,
resolution and interlaced field order are checked; the script does not resize,
deinterlace or impose a new frame rate. It uses FFmpeg's software `prores_ks`
encoder with the LT profile (the installed FFmpeg has no ProRes VideoToolbox encoder).
Every decoded video frame's relative timestamp and duration are checked, including
silent footage. A constant timeline shift and media-clock rounding are allowed.
After a successful verified conversion, MPEG-2 originals (.mpg/.mpeg/.m2v) move to macOS Trash. Other originals remain untouched. Use `--keep-mpeg` to retain MPEG originals too. Trash is recoverable and does not immediately reclaim disk space. Already-ProRes inputs are retained without re-encoding. Existing output without
a matching successful receipt is left alone and reported, not overwritten.

Version 2 receipts predate these video timing checks. Their existing outputs and
originals are preserved; they cannot authorize Trash under the current version 3
verification schema without fresh verification. `--keep-mpeg` can still recognize
a matching existing output without modifying it or its receipt.

Readiness requires a final-looking video filename, no Signiant work/checkpoint
or browser partial companion, at least 30 seconds of observed unchanged identity,
size and timestamps, and an `lsof` check with no open handles. Full source probing
and result decoding must succeed, with source fingerprint and completion guards
rechecked before publication. These are conservative observations, not an
absolute guarantee for a downloader that can pause and close its final filename.
Any changed source invalidates the pending conversion; failed conversions never trash originals. Trash itself rechecks source identity and failure retains the source.

The script processes one clip at a time using four encoder threads. New arrivals
while encoding are discovered on the next scan. Outputs are excluded from scans.
Successful receipt files prevent duplicate conversions on `--include-existing`
restarts. Each root has an advisory lock against duplicate watcher instances.
Failures retry after 60 seconds; the per-output `.log` gives encoder details.

Requirements: Python 3.10+, FFmpeg/ffprobe with prores_ks, and lsof (macOS/POSIX).
The launcher includes Homebrew and `/usr/local/bin` in PATH. Nothing is installed
automatically. ProRes copies can be much larger than downloads; keep free space.
Use `--settle-seconds` / `--poll-interval` only when the producer's behavior is known.

Tests:

```sh
python3 -m unittest discover -s script -p 'test_transcode_downloads.py' -v
```

The original detailed, read-only recorder remains `script/monitor_downloads.py`.
