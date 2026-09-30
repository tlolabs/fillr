//! Read-only preview of media preference decisions for a folder.
use fillr_core::{MediaPolicy, VideoProbe, staged_ffprobe_path};
use serde_json::json;
use std::env;
use std::fs;
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let folder = PathBuf::from(
        env::args()
            .nth(1)
            .ok_or("Usage: fillr-media-check FOLDER [POLICY_JSON]")?,
    );
    let policy: MediaPolicy = match env::args().nth(2) {
        Some(path) => serde_json::from_slice(&fs::read(path)?)?,
        None => MediaPolicy::default(),
    };
    policy.validate()?;
    let probe = VideoProbe::new(staged_ffprobe_path()?);
    for entry in fs::read_dir(folder)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let path = entry.path();
        let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ![
            "mpg", "mpeg", "mp4", "mov", "mxf", "ts", "m2ts", "avi", "mkv",
        ]
        .iter()
        .any(|x| x.eq_ignore_ascii_case(extension))
        {
            continue;
        }
        let value = match probe.media_info(&path) {
            Ok(info) => {
                let reasons = policy.reject_reasons(extension, &info);
                json!({"file": path.file_name().unwrap().to_string_lossy(), "accepted": reasons.is_empty(), "reasons": reasons, "media": info})
            }
            Err(error) => {
                json!({"file": path.file_name().unwrap().to_string_lossy(), "accepted": false, "error": error.to_string(), "deletion_safe": false})
            }
        };
        println!("{}", value);
    }
    Ok(())
}
