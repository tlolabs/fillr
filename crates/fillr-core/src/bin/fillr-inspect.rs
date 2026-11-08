use fillr_core::{TARGET_MS, VideoProbe, make_plan, staged_ffprobe_path};
use serde_json::json;
use std::env;
use std::fs;
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let folder = PathBuf::from(env::args().nth(1).ok_or("Usage: fillr-inspect FOLDER")?);
    if env::args().nth(2).is_some() {
        return Err("Usage: fillr-inspect FOLDER".into());
    }
    let probe = VideoProbe::new(staged_ffprobe_path()?);
    let mut files_to_probe = Vec::new();
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
        files_to_probe.push((name, entry.path()));
    }

    let probe_results: Vec<(String, Result<u64, String>)> = if files_to_probe.is_empty() {
        Vec::new()
    } else {
        let parallelism = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4)
            .min(files_to_probe.len().max(1));
        let chunk_size = files_to_probe.len().div_ceil(parallelism).max(1);

        std::thread::scope(|s| {
            let mut handles = Vec::new();
            for chunk in files_to_probe.chunks(chunk_size) {
                let probe_ref = &probe;
                handles.push(s.spawn(move || {
                    let mut out = Vec::with_capacity(chunk.len());
                    for (name, path) in chunk {
                        let res = probe_ref.duration_ms(path).map_err(|e| e.to_string());
                        out.push((name.clone(), res));
                    }
                    out
                }));
            }
            handles
                .into_iter()
                .flat_map(|h| h.join().unwrap())
                .collect()
        })
    };

    let mut clips = Vec::new();
    let mut errors = Vec::new();
    for (name, res) in probe_results {
        match res {
            Ok(duration) => clips.push((name, duration)),
            Err(error) => errors.push(format!("{name}: {error}")),
        }
    }
    errors.sort();
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
