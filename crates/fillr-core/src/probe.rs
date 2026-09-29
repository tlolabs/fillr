use serde::Deserialize;
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
    duration: Option<String>,
}

#[derive(Deserialize)]
struct ProbeFormat {
    duration: Option<String>,
}

impl VideoProbe {
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
        }
    }

    pub fn duration_ms(&self, path: &Path) -> Result<u64, ProbeError> {
        let mut child = Command::new(&self.executable)
            .args([
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=duration:format=duration",
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
        if data.streams.is_empty() {
            return Err(ProbeError::Invalid("No video stream".into()));
        }
        let parse_duration = |value: Option<&str>| {
            value
                .and_then(|s| s.parse::<f64>().ok())
                .filter(|n| n.is_finite() && *n > 0.0)
        };
        let duration = parse_duration(data.streams[0].duration.as_deref())
            .or_else(|| parse_duration(data.format.as_ref().and_then(|f| f.duration.as_deref())))
            .ok_or_else(|| ProbeError::Invalid("No usable video duration".into()))?;
        Ok((duration * 1000.0).floor() as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
