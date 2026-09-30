# FILLR download flight recorder

## Start and stop

On macOS, double-click `Start FILLR Download Monitor.command` in the project folder. Select the folder receiving CNN files, press Enter to start, and press Enter again to stop. Control-C also stops cleanly. Each run creates a separate dated folder under `~/Documents/FILLR Monitor Logs`; the Terminal window displays its exact path. Keep the window open while Signiant transfers files.

Terminal alternative:

```sh
python3 script/monitor_downloads.py "/path/to/download/folder"
```

If the path is omitted, a Mac folder picker opens. The tool uses only Python 3's standard library and macOS command-line tools. No sudo is needed. The monitor uses only this project's `dist/ffprobe-universal` binary. Build it with `./script/build_ffprobe_macos.sh` first. If the staged probe is absent, file sampling continues and media probing is skipped. `lsof` is used when found.

## Architecture and timing

The main loop takes a full `lstat` snapshot of the selected folder at each configured interval. Recursive scanning is on by default. Each object gets a raw JSONL row on every cycle, including unchanged objects. Directory rows include entry counts. A cycle row measures the actual interval, scan duration, start and end times, object count, and scan errors. `lsof` and `ffprobe` run independently so their often slower calls do not block the filesystem scan. Their own observations also go into the raw log. Events are derived from pairs of snapshots and process/probe observations, with references back to raw observation IDs.

Every observation records local ISO 8601 wall time with nine fractional digits and elapsed `monotonic_ns` since session start. Nine-digit formatting does not guarantee nanosecond accuracy. It records when this program observed a state, not the precise moment a filesystem operation occurred. The cycle statistics in `summary.json` show the observed sampling rate and late cycles. Very short requested intervals can create substantial CPU, disk, and process-scanning load, especially for large folders and many media files. The raw file can grow rapidly because identical observations are retained.

macOS `st_ctime` means status/metadata change time, not creation time. Creation time is recorded as `birthtime_ns`; if Python only exposes floating-point `st_birthtime`, the converted nanoseconds are labeled as an approximation. File-system timestamps reflect the values returned by the OS and its underlying filesystem, whose resolution may be lower than the displayed wall-clock digits. Reads can cause access-time updates on some filesystems. The monitor never intentionally writes, moves, or changes downloaded objects.

Identity is the pair `device:inode`. The event log detects a probable rename when an identity disappears at one path and appears at another in adjacent scans; hard links and moves outside the watched tree can complicate that interpretation. A path that retains its name but changes identity produces `INODE_CHANGED`, which may indicate replacement. These are observations, not completion decisions.

`ffprobe` runs once per configured interval for each visible media file with a recognized extension. It saves the full JSON format and stream metadata, command, elapsed time, exit status, stderr, and failures. A failure during a transfer is expected and remains in the data. `lsof` recursively samples open files in the chosen tree, recording PID, process name, user, descriptor, and access mode when provided by `lsof`. Its exact sample time and any errors are logged. Process names are recorded as reported, without guessing which process is Signiant. Neither probe success nor an open-file close proves transfer completion.

## Options

| Option | Purpose |
| --- | --- |
| `folder` | Watched folder. Omit to use the Mac folder picker. |
| `--poll-interval SECONDS` | Full filesystem sampling interval; default `0.05`. Values such as `0.01` are allowed. |
| `--process-poll-interval SECONDS` | `lsof` interval; default `0.25`. |
| `--ffprobe-interval SECONDS` | Per-media-file probe interval; default `1.0`. |
| `--ffprobe-timeout SECONDS` | Maximum runtime of an individual probe; default `5.0`. |
| `--recursive` / `--no-recursive` | Include subfolders (default) or observe only the top level. |
| `--log-directory PATH` | Parent directory for session log folders. The active log folder is excluded from snapshots if it is inside the watched tree. |
| `--exclude GLOB` | Exclude a matching relative path; repeat as needed. Hidden and temporary files are otherwise included. `.DS_Store` is ignored by default. |
| `--no-ffprobe` / `--no-lsof` | Disable the respective background sampler. |
| `--verbose` | Print the session ID and probe availability. |
| `--duration SECONDS` | Stop automatically after the given duration. |
| `--no-prompt` | Begin immediately; stop with Control-C. |

Example high-rate controlled run:

```sh
python3 script/monitor_downloads.py "/path/to/download/folder" --poll-interval 0.01 --duration 120 --verbose
```

## Log formats

Each JSONL record includes `session_id`, `type`, `wall_time`, and `monotonic_ns`. Files in the session folder:

| File | Contents |
| --- | --- |
| `raw.jsonl` | `session_start`, every `snapshot`, every `cycle`, `process_observation`, `ffprobe_observation`, and `session_end`. `snapshot` contains path, type, identity, size, blocks, raw timestamp values, ownership, flags, xattr summaries, and latest sampled open processes. |
| `events.jsonl` | `event` rows with `event`, `path`, `observation_refs`, and `details`. Includes appearance/disappearance, size/metadata changes, identity changes, probable renames, process opens/closes, and probe transitions. |
| `timeline.txt` | Readable chronological event lines with wall and elapsed time. |
| `summary.json` | Actual interval statistics and per-identity history, growth, paths, processes, xattrs, and probe timeline. |
| `session.json` | Session ID, platform, settings, probe versions, and timing notes. |

For example, a raw row may include `"type":"snapshot","cycle":42,"identity":"16777234:1234567","size":48234496`. An event might include `"event":"SIZE_CHANGED","observation_refs":["fs:41:2","fs:42:2"],"details":{"delta_bytes":2097152,...}`. A timeline line may read `2026-09-29T22:15:31.123456789-07:00 +48.372839102s SIZE_CHANGED /Downloads/CNN/story.mov ...`.

## Controlled CNN/Signiant test

1. Create or select an empty destination folder that Signiant will use. Confirm FILLR itself will not build or move Comp folders during the experiment.
2. Start the recorder on that folder **before** starting the transfer. Note the session log path shown in Terminal.
3. Start a representative CNN Newsource download through Signiant. Let it run through completion, then leave the recorder running for a short post-transfer period to capture release and metadata behavior.
4. Stop with Enter or Control-C. Check `summary.json` for the actual sample intervals and scan errors; keep all raw logs even if the transfer was interrupted.
5. Repeat with files and conditions of interest. Use a separate session for each test.

## What to give FILLR after the experiment

Share the entire session folder: `raw.jsonl`, `events.jsonl`, `timeline.txt`, `summary.json`, and `session.json`. Also note the approximate transfer start/end time and whether Signiant reported a completed or interrupted download. The logs retain evidence; none of their stability or probe signals is labeled as an authoritative completion test.
