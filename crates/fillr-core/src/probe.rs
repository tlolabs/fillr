use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug)]
pub enum ProbeError {
    Launch(String),
    Failed(String),
    Invalid(String),
}

impl std::fmt::Display for ProbeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Launch(s) | Self::Failed(s) | Self::Invalid(s) => f.write_str(s),
        }
    }
}

impl std::error::Error for ProbeError {}

/// Maximum supported single clip duration: 7 days (604,800,000 milliseconds).
/// Media exceeding this practical limit is rejected to prevent arithmetic overflow and memory exhaustion.
pub const MAX_CLIP_DURATION_MS: u64 = 7 * 24 * 3600 * 1000;

#[derive(Clone)]
pub struct VideoProbe {
    executable: PathBuf,
}

#[derive(Deserialize)]
struct ProbeOutput {
    #[serde(default)]
    streams: Vec<ProbeStream>,
    format: Option<ProbeFormat>,
}

#[derive(Deserialize)]
struct ProbeStream {
    codec_type: Option<String>,
    codec_name: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    sample_aspect_ratio: Option<String>,
    display_aspect_ratio: Option<String>,
    field_order: Option<String>,
    avg_frame_rate: Option<String>,
    r_frame_rate: Option<String>,
    tags: Option<ProbeTags>,
    #[serde(default)]
    side_data_list: Vec<ProbeSideData>,
    duration: Option<String>,
}

#[derive(Deserialize)]
struct ProbeTags {
    rotate: Option<String>,
}

#[derive(Deserialize)]
struct ProbeSideData {
    rotation: Option<f64>,
}

#[derive(Deserialize)]
struct ProbeFormat {
    format_name: Option<String>,
    duration: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct MediaInfo {
    pub duration_ms: Option<u64>,
    pub format_name: String,
    pub codec_name: String,
    pub width: u32,
    pub height: u32,
    pub sample_aspect_ratio: String,
    pub display_aspect_ratio: String,
    pub field_order: String,
    pub frame_rate: String,
    pub rotation_degrees: Option<f64>,
}

impl VideoProbe {
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
        }
    }

    pub fn duration_ms(&self, path: &Path) -> Result<u64, ProbeError> {
        self.media_info(path)?
            .duration_ms
            .ok_or_else(|| ProbeError::Invalid("No usable video duration".into()))
    }

    pub fn media_info(&self, path: &Path) -> Result<MediaInfo, ProbeError> {
        self.media_info_with_stop(path, None)
    }

    // Only background scanning supplies a stop flag. Build/preflight callers
    // keep the normal complete-inspection timeout through media_info().
    pub(crate) fn media_info_cancellable(
        &self,
        path: &Path,
        stop: &AtomicBool,
    ) -> Result<MediaInfo, ProbeError> {
        self.media_info_with_stop(path, Some(stop))
    }

    fn media_info_with_stop(
        &self,
        path: &Path,
        stop: Option<&AtomicBool>,
    ) -> Result<MediaInfo, ProbeError> {
        let stopped = || stop.is_some_and(|flag| flag.load(Ordering::Acquire));
        if stopped() {
            return Err(ProbeError::Failed(
                "Folder scan stopped; file will not be deleted".into(),
            ));
        }
        if !self.executable.is_absolute() {
            return Err(ProbeError::Launch(format!(
                "FFprobe path must be absolute and FILLR-owned: {}",
                self.executable.display()
            )));
        }
        let mut child = Command::new(&self.executable)
            .args([
                "-v",
                "error",
                "-show_entries",
                "stream=codec_type,codec_name,width,height,sample_aspect_ratio,display_aspect_ratio,field_order,avg_frame_rate,r_frame_rate,duration:stream_tags=rotate:stream_side_data=rotation:format=format_name,duration",
                "-of",
                "json",
            ])
            .arg(path)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| ProbeError::Launch(format!("Unable to start ffprobe: {e}")))?;
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let output_reader = thread::spawn(move || read_probe_output(stdout));
        let error_reader = thread::spawn(move || read_probe_output(stderr));
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut sleep_dur = Duration::from_micros(100);
        let status = loop {
            if stopped() {
                break Err("Folder scan stopped; file will not be deleted".to_owned());
            }
            match child.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) if Instant::now() < deadline => {
                    thread::sleep(sleep_dur);
                    if sleep_dur < Duration::from_millis(5) {
                        sleep_dur = (sleep_dur * 2).min(Duration::from_millis(5));
                    }
                }
                Ok(None) => {
                    break Err(
                        "ffprobe timed out after 15 seconds; file will not be deleted".to_owned(),
                    );
                }
                Err(error) => break Err(format!("Unable to wait for ffprobe: {error}")),
            }
        };
        if status.is_err() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let stdout = output_reader
            .join()
            .map_err(|_| ProbeError::Failed("FFprobe output worker stopped".into()))?;
        let stderr = error_reader
            .join()
            .map_err(|_| ProbeError::Failed("FFprobe error worker stopped".into()))?;
        let status = status.map_err(ProbeError::Failed)?;
        if stopped() {
            return Err(ProbeError::Failed(
                "Folder scan stopped; file will not be deleted".into(),
            ));
        }
        let stdout = stdout.map_err(|e| ProbeError::Failed(e.to_string()))?;
        let stderr = stderr.map_err(|e| ProbeError::Failed(e.to_string()))?;
        if !status.success() {
            return Err(ProbeError::Failed(
                String::from_utf8_lossy(&stderr).trim().to_owned(),
            ));
        }
        let data: ProbeOutput = serde_json::from_slice(&stdout)
            .map_err(|e| ProbeError::Invalid(format!("Invalid ffprobe response: {e}")))?;
        let video = data
            .streams
            .iter()
            .find(|stream| stream.codec_type.as_deref() == Some("video"))
            .ok_or_else(|| ProbeError::Invalid("No video stream".into()))?;
        let parse_duration = |value: Option<&str>| -> Option<u64> {
            let raw = value?.trim();
            if raw.is_empty() || raw.eq_ignore_ascii_case("N/A") {
                return None;
            }
            let seconds = raw.parse::<f64>().ok()?;
            if !seconds.is_finite() || seconds.is_nan() || seconds <= 0.0 {
                return None;
            }
            let ms = seconds * 1000.0;
            if !ms.is_finite() || ms < 1.0 || ms > (MAX_CLIP_DURATION_MS as f64) {
                return None;
            }
            Some(ms.floor() as u64)
        };
        let duration = parse_duration(video.duration.as_deref())
            .or_else(|| parse_duration(data.format.as_ref().and_then(|f| f.duration.as_deref())));
        let rate = video
            .avg_frame_rate
            .as_deref()
            .filter(|value| !matches!(*value, "0/0" | "N/A"))
            .or(video.r_frame_rate.as_deref())
            .unwrap_or("unknown");
        let codec_name = video.codec_name.clone().unwrap_or_default();
        let width = video.width.unwrap_or(0);
        let height = video.height.unwrap_or(0);
        if codec_name.is_empty() || width == 0 || height == 0 {
            return Err(ProbeError::Invalid("ffprobe did not provide a complete video codec and resolution; file will not be deleted".into()));
        }
        Ok(MediaInfo {
            duration_ms: duration,
            format_name: data
                .format
                .and_then(|f| f.format_name)
                .unwrap_or_else(|| "unknown".into()),
            codec_name,
            width,
            height,
            sample_aspect_ratio: video
                .sample_aspect_ratio
                .clone()
                .unwrap_or_else(|| "unknown".into()),
            display_aspect_ratio: video
                .display_aspect_ratio
                .clone()
                .unwrap_or_else(|| "unknown".into()),
            field_order: video
                .field_order
                .clone()
                .unwrap_or_else(|| "unknown".into()),
            frame_rate: rate.to_owned(),
            rotation_degrees: video
                .side_data_list
                .iter()
                .find_map(|item| item.rotation)
                .or_else(|| {
                    video
                        .tags
                        .as_ref()
                        .and_then(|tags| tags.rotate.as_deref())
                        .and_then(|value| value.parse::<f64>().ok())
                })
                .filter(|value| value.is_finite()),
        })
    }
}

const PROBE_OUTPUT_LIMIT: u64 = 4 * 1024 * 1024;
fn read_probe_output(mut pipe: impl Read) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::with_capacity(4096);
    pipe.by_ref()
        .take(PROBE_OUTPUT_LIMIT + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > PROBE_OUTPUT_LIMIT {
        // Continue draining so the child cannot block on a full pipe.
        std::io::copy(&mut pipe, &mut std::io::sink())?;
        return Err(std::io::Error::other(
            "FFprobe output exceeds safe size limit",
        ));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn cancellation_busy_probe(folder: &Path) -> (VideoProbe, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let executable = folder.join("busy-probe");
        std::fs::write(
            &executable,
            r#"#!/bin/sh
probe_dir=${0%/*}
printf '%s\n' "$$" > "$probe_dir/started-pid"
exec sleep 30
"#,
        )
        .unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();
        (VideoProbe::new(executable), folder.join("started-pid"))
    }

    #[cfg(unix)]
    fn cancellation_wait_pid(path: &Path) -> libc::pid_t {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(pid) = std::fs::read_to_string(path)
                .ok()
                .and_then(|value| value.trim().parse().ok())
            {
                return pid;
            }
            assert!(Instant::now() < deadline, "Busy probe did not start");
            thread::sleep(Duration::from_millis(1));
        }
    }

    #[cfg(unix)]
    fn cancellation_assert_reaped(pid: libc::pid_t) {
        // SAFETY: signal0 only checks the captured child PID; it does not send
        // a signal or access user memory. The child was killed and waited above.
        let result = unsafe { libc::kill(pid, 0) };
        let error = std::io::Error::last_os_error();
        assert_eq!(result, -1, "Cancelled child remains alive: {pid}");
        assert_eq!(error.raw_os_error(), Some(libc::ESRCH));
    }

    #[cfg(unix)]
    #[test]
    fn pre_cancelled_background_probe_does_not_launch_and_public_probe_still_inspects() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("probe");
        std::fs::write(&executable, r#"#!/bin/sh
probe_dir=${0%/*}
: > "$probe_dir/launched"
printf '%s\n' '{"streams":[{"codec_type":"video","codec_name":"mpeg2video","width":1920,"height":1080,"duration":"1.0"}]}'
"#).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();
        let probe = VideoProbe::new(executable);
        let stop = AtomicBool::new(true);
        let error = probe
            .media_info_cancellable(&directory.path().join("source.mpg"), &stop)
            .unwrap_err();
        assert!(error.to_string().contains("scan stopped"));
        assert!(!directory.path().join("launched").exists());
        // Build/public callers never inherit background cancellation.
        assert_eq!(
            probe
                .media_info(&directory.path().join("source.mpg"))
                .unwrap()
                .duration_ms,
            Some(1_000)
        );
        assert!(directory.path().join("launched").exists());
    }

    #[cfg(unix)]
    #[test]
    fn busy_probe_cancellation_kills_reaps_and_returns_before_normal_timeout() {
        use std::sync::Arc;
        let mut samples = Vec::new();
        for _ in 0..10 {
            let directory = tempfile::tempdir().unwrap();
            let source = directory.path().join("source.mpg");
            std::fs::write(&source, b"source must survive cancellation").unwrap();
            let (probe, started) = cancellation_busy_probe(directory.path());
            let stop = Arc::new(AtomicBool::new(false));
            let (pid, elapsed, error) = thread::scope(|scope| {
                let pending = scope.spawn(|| probe.media_info_cancellable(&source, &stop));
                let pid = cancellation_wait_pid(&started);
                let at = Instant::now();
                stop.store(true, Ordering::Release);
                let error = pending.join().unwrap().unwrap_err();
                (pid, at.elapsed(), error)
            });
            assert!(error.to_string().contains("scan stopped"));
            assert!(
                elapsed < Duration::from_secs(2),
                "Cancellation waited {elapsed:?}"
            );
            cancellation_assert_reaped(pid);
            assert_eq!(
                std::fs::read(source).unwrap(),
                b"source must survive cancellation"
            );
            samples.push(elapsed.as_secs_f64() * 1000.0);
        }
        println!(
            "FILLR_CANCEL_PERF {}",
            serde_json::json!({
                "mode": "busy_single_probe_cancel", "samples":10, "raw_ms":samples,
                "conditions":"actual exec-sleep mock child, killed+reaped after start handshake; excludes setup; not media throughput; existing poll max5ms, OS pipe drain/scheduling can add latency",
            })
        );
    }

    #[cfg(unix)]
    #[test]
    fn normal_probe_retains_real_fifteen_second_timeout_without_background_flag() {
        let directory = tempfile::tempdir().unwrap();
        let (probe, started) = cancellation_busy_probe(directory.path());
        let at = Instant::now();
        let error = probe
            .media_info(&directory.path().join("source.mpg"))
            .unwrap_err();
        let elapsed = at.elapsed();
        assert!(error.to_string().contains("timed out after 15 seconds"));
        assert!(elapsed >= Duration::from_secs(15));
        assert!(
            elapsed < Duration::from_secs(20),
            "Normal timeout took {elapsed:?}"
        );
        let pid = std::fs::read_to_string(started)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        cancellation_assert_reaped(pid);
        println!(
            "FILLR_CANCEL_PERF {}",
            serde_json::json!({
                "mode":"normal_uncancelled_timeout", "elapsed_ms":elapsed.as_secs_f64()*1000.0,
                "conditions":"actual exec-sleep mock; public/build path remains15s; child killed and reaped",
            })
        );
    }

    #[test]
    fn rejects_path_lookup_for_probe() {
        let error = VideoProbe::new("ffprobe")
            .media_info(Path::new("clip.mpg"))
            .unwrap_err();
        assert!(error.to_string().contains("must be absolute"));
    }

    #[cfg(unix)]
    #[test]
    fn incomplete_video_profile_cannot_authorize_deletion() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let command = dir.path().join("incomplete-ffprobe");
        fs::write(&command, "#!/bin/sh\nprintf '%s\\n' '{\"streams\":[{\"codec_type\":\"video\",\"width\":0,\"height\":0}],\"format\":{\"format_name\":\"mpeg\",\"duration\":\"10.0\"}}'\n").unwrap();
        fs::set_permissions(&command, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(VideoProbe::new(command).media_info(dir.path()).is_err());
    }

    #[test]
    fn container_duration_is_used_when_stream_duration_is_missing() {
        let data: ProbeOutput =
            serde_json::from_str(r#"{"streams":[{}],"format":{"duration":"117.864000"}}"#).unwrap();
        assert_eq!(
            data.streams[0]
                .duration
                .as_deref()
                .or_else(|| data.format.as_ref().and_then(|f| f.duration.as_deref())),
            Some("117.864000")
        );
    }

    #[test]
    fn invalid_stream_duration_falls_back_to_container() {
        let data: ProbeOutput = serde_json::from_str(
            r#"{"streams":[{"duration":"N/A"}],"format":{"duration":"12.5"}}"#,
        )
        .unwrap();
        let stream = data.streams[0]
            .duration
            .as_deref()
            .and_then(|s| s.parse::<f64>().ok());
        let container = data
            .format
            .unwrap()
            .duration
            .unwrap()
            .parse::<f64>()
            .unwrap();
        assert_eq!(stream.or(Some(container)), Some(12.5));
    }
    #[test]
    fn oversized_probe_output_is_rejected() {
        assert!(read_probe_output(std::io::repeat(b'x').take(PROBE_OUTPUT_LIMIT + 100)).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn probe_drains_stdout_and_stderr_before_waiting() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let script = temp.path().join("probe");
        std::fs::write(&script, "#!/bin/sh
head -c 131072 /dev/zero | tr '\\0' ' ' >&2
head -c 131072 /dev/zero | tr '\\0' ' '
printf '%s' '{\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"h264\",\"width\":1920,\"height\":1080,\"duration\":\"1.0\"}]}'
").unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        let probe = VideoProbe::new(script);
        assert!(probe.media_info(&temp.path().join("fixture")).is_ok());
    }

    #[test]
    fn extreme_nonfinite_and_negative_durations_are_rejected() {
        let test_cases = [
            ("NaN", false),
            ("Infinity", false),
            ("-Infinity", false),
            ("-1.0", false),
            ("0.0", false),
            ("1e308", false),
            ("999999999999999.0", false),
            ("N/A", false),
            ("invalid", false),
            ("10.5", true),
            ("604800.0", true), // Exactly 7 days (604,800,000 ms)
        ];
        for (raw, valid) in test_cases {
            let parse_duration = |value: Option<&str>| -> Option<u64> {
                let raw = value?.trim();
                if raw.is_empty() || raw.eq_ignore_ascii_case("N/A") {
                    return None;
                }
                let seconds = raw.parse::<f64>().ok()?;
                if !seconds.is_finite() || seconds.is_nan() || seconds <= 0.0 {
                    return None;
                }
                let ms = seconds * 1000.0;
                if !ms.is_finite() || ms < 1.0 || ms > (MAX_CLIP_DURATION_MS as f64) {
                    return None;
                }
                Some(ms.floor() as u64)
            };
            assert_eq!(
                parse_duration(Some(raw)).is_some(),
                valid,
                "Case {raw} expected valid={valid}"
            );
        }
    }
}
