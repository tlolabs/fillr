use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;
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
        let deadline = Instant::now() + Duration::from_secs(15);
        while child
            .try_wait()
            .map_err(|e| ProbeError::Failed(format!("Unable to wait for ffprobe: {e}")))?
            .is_none()
        {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ProbeError::Failed(
                    "ffprobe timed out after 15 seconds".into(),
                ));
            }
            thread::sleep(Duration::from_millis(25));
        }
        let output = child
            .wait_with_output()
            .map_err(|e| ProbeError::Failed(format!("Unable to read ffprobe output: {e}")))?;
        if !output.status.success() {
            return Err(ProbeError::Failed(
                String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            ));
        }
        let data: ProbeOutput = serde_json::from_slice(&output.stdout)
            .map_err(|e| ProbeError::Invalid(format!("Invalid ffprobe response: {e}")))?;
        let video = data
            .streams
            .iter()
            .find(|stream| stream.codec_type.as_deref() == Some("video"))
            .ok_or_else(|| ProbeError::Invalid("No video stream".into()))?;
        let parse_duration = |value: Option<&str>| {
            value
                .and_then(|s| s.parse::<f64>().ok())
                .filter(|n| n.is_finite() && *n > 0.0)
        };
        let duration = parse_duration(video.duration.as_deref())
            .or_else(|| parse_duration(data.format.as_ref().and_then(|f| f.duration.as_deref())))
            .map(|duration| (duration * 1000.0).floor() as u64);
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
