use fillr_core::{TARGET_MS, VideoProbe, make_plan};
use serde_json::json;
use std::env;
use std::fs;
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let folder = PathBuf::from(
        env::args()
            .nth(1)
            .ok_or("Usage: fillr-inspect FOLDER [FFPROBE]")?,
    );
    let probe = VideoProbe::new(env::args().nth(2).unwrap_or_else(|| "ffprobe".into()));
    let mut clips = Vec::new();
    let mut errors = Vec::new();
    for entry in fs::read_dir(&folder)? {
        let entry = entry?;
        if !entry.file_type()?.is_file()
            || !entry
                .path()
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("mpg"))
        {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        match probe.duration_ms(&entry.path()) {
            Ok(duration) => clips.push((name, duration)),
            Err(error) => errors.push(format!("{name}: {error}")),
        }
    }
    clips.sort_by(|a, b| a.0.cmp(&b.0));
    let total: u64 = clips.iter().map(|(_, d)| *d).sum();
    let plan = make_plan(&clips);
    let result = json!({
        "clip_count": clips.len(),
        "available_minutes": total as f64 / 60_000.0,
        "remaining_minutes": (TARGET_MS * 14).saturating_sub(total) as f64 / 60_000.0,
        "ready": plan.is_some(),
        "selected_clips": plan.as_ref().map(|p| p.assignments.iter().map(|a| a.filenames.len()).sum::<usize>()),
        "selected_minutes": plan.as_ref().map(|p| p.selected_duration_ms as f64 / 60_000.0),
        "comp_minutes": plan.as_ref().map(|p| p.assignments.iter().map(|a| (a.comp, a.duration_ms as f64 / 60_000.0)).collect::<Vec<_>>()),
        "errors": errors,
    });
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
