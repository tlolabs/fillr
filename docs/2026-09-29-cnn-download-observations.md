# CNN Newsource download observations and FILLR media policy

Evidence: the two September 29 recorder sessions at `FILLR Monitor Logs/2026-09-29_22-35-00_46320457` and `FILLR Monitor Logs/2026-09-29_22-49-06_961165a1`, plus a read-only probe of the eight completed files in `~/Desktop/CNN Downloads`. The analysis streamed every raw JSONL record and cross-checked its filesystem, process, and ffprobe observations with the event logs. The source logs were not changed.

## Executive findings

**Observed fact, high confidence within these eight transfers:** every download had a 1,064-byte `#chkpt_file#` and a `#work_file#` with the same basename and extension. The work file grew, then appeared at the final name with the *same device and inode*; the checkpoint disappeared in the same 50 ms filesystem sample. No completed final path changed size, mtime, or ctime in subsequent samples. All eight transfers were captured from temporary-file appearance through finalization.

**Observed fact, important qualification:** `SigniantClient` was still seen holding a descriptor after the final-name transition in seven transfers. Its sampled close event occurred from about 35 to 220 ms later. In one transfer its sampled close was 41 ms before the rename sample. `lsof` ran every 250 ms, independently of the 50 ms filesystem scan, so these values bound observations rather than pinpointing the actual close. A final name alone is therefore insufficient evidence for immediate destructive action.

**Recommendation:** keep temporary files untouched; classify media from a read-only probe; only delete an unwanted file after it has a final name, no matching work/checkpoint companion, a sustained unchanged period, a complete media profile, and no observed open descriptor on macOS. The implemented default waits at least ten seconds of unchanged observation and checks `lsof` before deletion. This is deliberately more conservative than the millisecond-scale finalization seen here.

## Observed lifecycle

Times below are elapsed seconds from each monitor session's monotonic origin. `Work/final inode` and `checkpoint inode` share device `16777234` in every row. The first work and checkpoint appearances fell in the same filesystem sample. `Signiant close Δ` is relative to first final-name observation; negative means sampled before it. All final sizes are bytes.

| Download (short label) | Work/final inode | Checkpoint inode | First work/checkpoint | First Signiant open | First size growth | First successful probe | Final name | Signiant close Δ | Final size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| NHL Chicago–Vegas `.mpg` | 60657987 | 60657988 | 22.256 | 22.352 | 22.556 | 23.363 | 27.556 | +106 ms | 329,867,264 |
| Vigil `.mpg` | 60658079 | 60658080 | 37.656 | 37.840 | 38.006 | 38.822 | 41.856 | +39 ms | 284,239,872 |
| Households `.mpg` | 60658197 | 60658198 | 52.506 | 52.592 | 52.856 | 53.673 | 56.806 | +101 ms | 223,883,264 |
| SD widescreen `.mpg` | 60658392 | 60658393 | 90.156 | 90.212 | 90.503 | 91.235 | 92.202 | +35 ms | 79,654,912 |
| SD 4:3 `.mpg` | 60658446 | 60658447 | 104.656 | 104.699 | 105.005 | 105.806 | 105.753 | −41 ms | 11,964,416 |
| Vertical skydivers `.mp4` | 60658603 | 60658604 | 134.106 | 134.206 | 134.456 | 135.205 | 135.652 | +74 ms | 40,881,863 |
| Cubs–Padres `.mp4` | 60662496 | 60662497 | 181.607 | 181.812 | 182.157 | 182.766 | 186.157 | +220 ms | 231,895,135 |
| Egyptian story `.mp4` | 60662705 | 60662706 | 213.107 | 213.078 | 213.357 | 214.120 | 215.307 | +53 ms | 89,161,736 |

The first session sampled 3,196 cycles, with a median reconstructed interval of 49.99 ms, 95th percentile 52.91 ms, and maximum 55.09 ms. The second sampled 7,020 cycles, with a median of 50.00 ms, 95th percentile 53.17 ms, and maximum 100.74 ms. These intervals were reconstructed from successive raw monotonic cycle timestamps: the recorder version used for these runs left its `actual_interval_ns` field empty. That recorder bug has been fixed for future sessions.

The last observed work-file size increase was approximately 46–104 ms before the first final-name sample. The gap between scans leaves room for operations not directly observed; it does not prove that no write happened between the last work sample and rename. The first final sample already had the final size, and every later final sample showed one size, one mtime, and one ctime for that identity. No post-final ffprobe profile change was observed.

## Completion signal analysis

| Signal | Supporting evidence | Limitation and risk | Confidence here |
| --- | --- | --- | --- |
| Same inode moves from `#work_file#` to final name | All eight transfers did so. Detectable at the next filesystem scan, normally within about 50 ms. | A final name appeared while Signiant could still hold the file open. A future client version could use a different method. | High for these runs; medium for future releases |
| Matching checkpoint disappears | All eight disappeared in the same observed sample as the rename. | The 50 ms sample cannot establish atomic order; interruption behavior was not captured. | High within these runs |
| Signiant descriptor closes | The sampled close followed rename in seven of eight cases. | `lsof` is intermittent, permission dependent, and reports an observation time rather than the exact close. One close sampled before rename. | Medium |
| No size/mtime change after final name | True for every final path in these runs. | A paused or failed transfer can also be stable. A normal-looking final name from another producer could still grow. | Medium alone |
| ffprobe succeeds | Seven of eight profiles were readable before finalization. | Success explicitly does **not** imply completion. | Low as completion evidence |
| Fixed waiting period | Ten seconds covers the largest observed rename-to-close sample gap of about 220 ms. | It is a conservative margin, not a Signiant contract; a sufficiently long paused writer is still possible without an open-file check. | Medium |

The strongest observed finalization transition is **same-inode work-to-final rename plus checkpoint disappearance**. For safe deletion, the implementation additionally requires an unchanged final path and, on macOS, no process holding it open. It does not designate any single observation as an authoritative transfer-complete flag.

## Media metadata and profiles

The first successful ffprobe occurred before finalization for seven clips. The short SD 4:3 transfer had its first success about 53 ms after the final-name sample because its download finished between one-second probe attempts. Once successful, codec, dimensions, display ratio, frame rate, and field order did not change in any observed probe sequence. MPEG program-stream *reported duration* grew substantially during four longer `.mpg` transfers; `format.size` grew as bytes arrived. Duration and reported size must not be used for early completion or final size decisions. The `.mp4` examples exposed their final duration early, but that container-specific observation should not be generalized.

| Profile | Examples | Container / codec | Stored pixels | SAR / DAR | Frame rate | Field order | Default decision |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| HD NTSC interlaced | 3 | MPEG-PS / MPEG-2 | 1920×1080 | 1:1 / 16:9 | 30000/1001 | top-field-first (`tt`) | Accept |
| SD anamorphic widescreen | 1 | MPEG-PS / MPEG-2 | 720×480 | 32:27 / 16:9 | 30000/1001 | `tt` | Reject: SD resolution |
| SD 4:3 | 1 | MPEG-PS / MPEG-2 | 720×480 | 8:9 / 4:3 | 30000/1001 | `tt` | Reject: SD and 4:3 |
| Vertical MP4 | 1 | MP4 / H.264 | 1080×1920 | 1:1 / 9:16 | 30000/1001 | progressive | Reject |
| Horizontal H.264 MP4 | 1 | MP4 / H.264 | 1920×1080 | 1:1 / 16:9 | 30000/1001 | not reported | Reject: container and codec |
| 25 fps H.264 MP4 | 1 | MP4 / H.264 | 1920×1080 | 1:1 / 16:9 | 25/1 | `tt` | Reject: container, codec, and non-NTSC rate |

The three accepted HD MPEG-2 examples are the three clips explicitly named as correctly formatted in the request, including the NHL Chicago–Vegas clip. The 25 fps Egyptian clip is consistent with a PAL-rate version; the metadata establishes its rate, not a separate analog PAL encoding flag. The SD widescreen clip demonstrates why stored 720÷480 must not be used as display aspect ratio: its 32:27 sample ratio yields a 16:9 display.

## State machine and production rule

| State | Entry / transition | Allowed action |
| --- | --- | --- |
| Temporary transfer | `#work_file#` or `#chkpt_file#` exists. Any normal path with a matching companion remains pending. | Observe only. Probe if useful, but never move or delete. |
| Final candidate | Normal media filename exists without companions. | Observe size, high-resolution mtime, identity, and media profile. Do not count while newly seen or changing. |
| Profile unknown | ffprobe fails or omits codec or dimensions. | Exclude from ready count; do not delete. Retry when file changes or on refresh. |
| Settling | Final candidate's stamp has changed or has not been observed unchanged for ten seconds; mtime is also less than ten seconds old. | No move or delete. |
| Accepted | Settled file has a complete profile matching current preferences and a usable duration. | Count toward footage; re-probe and recheck during Build. |
| Rejected | Settled file has a complete profile that violates a preference. | Exclude from count. If automatic deletion is enabled, verify no companion, unchanged stamp, and on macOS no open descriptor; then delete and log reason. |
| Abandoned/failed candidate | Temporary object remains without normal finalization. | Keep untouched; do not infer completion from a quiet interval. |

Pseudocode for the implemented decision:

```text
for each top-level media candidate:
    if temporary name or matching work/checkpoint companion exists: pending
    else if stamp changed or <10 seconds unchanged or mtime <10 seconds old: pending
    else:
        info = ffprobe(file)
        if missing video codec or dimensions: excluded, never auto-delete
        else if policy rejects info:
            exclude from ready count
            if deletion enabled and stamp still matches and companions absent:
                on macOS require lsof to report no open process
                recheck stamp, then delete and append .fillr-rejections.log
        else if duration is usable: count as accepted
on Build:
    re-probe every selected clip against the current policy before moving files
    never move an unscanned or rejected file when filtering is enabled
```

The default is an editable policy, not a list of filenames: extension `mpg`, container `mpeg`, codec `mpeg2video`, 1920×1080, NTSC, `30000/1001`, interlaced, horizontal, DAR `16:9`. Empty allowed lists or optional values mean “any.” The filter and automatic deletion each have their own switch. Settings are saved by the native apps.

## Edge cases and remaining confidence

There were no interrupted transfers, abandoned work files, work files without checkpoints, checkpoint-only remnants, inode replacements, duplicate final names, or post-final size changes in these two sessions. Several transfers were sequential; these sessions do not establish behavior for many simultaneous transfers. MP4 streams differed in probe behavior from MPEG-PS, and one MP4 had no reported field order. The in-app bundled ffprobe previously lacked the raw MPEG video demuxer and MP4 demuxer; its build has been corrected and validated against all eight supplied files. A partial or failed probe remains non-deletable.

Confidence in the observed rename/checkpoint pattern and the six media profiles is **high** for these files. Confidence that the same pattern covers every Signiant version and failure mode is **medium**. Confidence in any instantaneous “safe to delete” signal is **low** without observing release and testing interruptions; the implemented settling and open-file guard mitigate that uncertainty.

### Next tests to run

1. Interrupt and resume a transfer, including a long pause after the final-looking name, to test for false completion.
2. Start FILLR midway through an active transfer and after one has completed, to validate restart behavior.
3. Download several clips simultaneously and reuse a destination filename, to test companion matching and inode replacement.
4. Repeat with a large MP4 whose metadata is stored at the end, and with a Signiant update, to test early classification and the finalization contract.
