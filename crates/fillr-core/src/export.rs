use crate::allocation::{Plan, Rng};
use crate::probe::VideoProbe;
use crate::scan::Clip;
use chrono::Local;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug)]
pub struct ExportError(pub String);

impl std::fmt::Display for ExportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ExportError {}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BuildResult {
    pub output_folder: String,
    pub selected_clips: usize,
    pub archived_clips: usize,
    pub selected_duration_ms: u64,
}

#[derive(Serialize, Deserialize)]
struct Journal {
    version: u32,
    seed: u64,
    moves: Vec<MoveOp>,
}

#[derive(Serialize, Deserialize)]
struct MoveOp {
    source_name: String,
    destination: String,
    duration_ms: u64,
}

pub fn build_export(
    folder: &Path,
    probe: &VideoProbe,
    clips: &[Clip],
    plan: &Plan,
) -> Result<BuildResult, ExportError> {
    build_export_with(folder, clips, plan, |path| {
        probe
            .duration_ms(path)
            .map_err(|e| ExportError(e.to_string()))
    })
}

fn build_export_with<F>(
    folder: &Path,
    clips: &[Clip],
    plan: &Plan,
    mut duration_of: F,
) -> Result<BuildResult, ExportError>
where
    F: FnMut(&Path) -> Result<u64, ExportError>,
{
    let durations: Vec<_> = clips
        .iter()
        .map(|c| (c.filename.clone(), c.duration_ms))
        .collect();
    if !plan.validate(&durations) {
        return Err(ExportError("The Comp layout is no longer valid".into()));
    }
    let mut expected_stamps: HashMap<String, (u64, u64)> = clips
        .iter()
        .map(|clip| (clip.filename.clone(), (clip.size_bytes, clip.modified_ms)))
        .collect();
    for clip in clips {
        let path = folder.join(&clip.filename);
        let meta = fs::symlink_metadata(&path)
            .map_err(|e| ExportError(format!("{} disappeared: {e}", clip.filename)))?;
        if !meta.file_type().is_file() {
            return Err(ExportError(format!(
                "{} is not a regular file",
                clip.filename
            )));
        }
        let modified_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .unwrap_or_default()
            .as_millis() as u64;
        if meta.len() != clip.size_bytes || modified_ms != clip.modified_ms {
            return Err(ExportError(format!(
                "{} changed since the last scan",
                clip.filename
            )));
        }
        if duration_of(&path)? != clip.duration_ms {
            return Err(ExportError(format!(
                "{} has a different video duration",
                clip.filename
            )));
        }
    }
    let mut rng = Rng(plan.seed ^ 0xa5a5_92ee_6431_02ac);
    let mut new_names = HashSet::new();
    let mut selected = HashSet::new();
    let mut moves = Vec::new();
    for assignment in &plan.assignments {
        for source in &assignment.filenames {
            selected.insert(source.clone());
            let new_name = loop {
                let candidate = format!("{:08}.mpg", rng.next() % 100_000_000);
                if new_names.insert(candidate.clone()) {
                    break candidate;
                }
            };
            moves.push(MoveOp {
                source_name: source.clone(),
                destination: format!("Comp {}/{}", assignment.comp, new_name),
                duration_ms: clips
                    .iter()
                    .find(|c| &c.filename == source)
                    .unwrap()
                    .duration_ms,
            });
        }
    }
    let selected_count = moves.len();
    for clip in clips {
        if !selected.contains(&clip.filename) {
            moves.push(MoveOp {
                source_name: clip.filename.clone(),
                destination: format!("Unused/{}", clip.filename),
                duration_ms: clip.duration_ms,
            });
        }
    }
    let now = SystemTime::now();
    for entry in fs::read_dir(folder).map_err(|e| ExportError(e.to_string()))? {
        let entry = entry.map_err(|e| ExportError(e.to_string()))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if expected_stamps.contains_key(&name)
            || name.starts_with('.')
            || name.to_ascii_uppercase().starts_with("#WORK")
            || !entry
                .path()
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("mpg"))
        {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(entry.path()) else {
            continue;
        };
        if !metadata.file_type().is_file()
            || !metadata
                .modified()
                .ok()
                .and_then(|time| now.duration_since(time).ok())
                .is_some_and(|age| age >= Duration::from_secs(10))
        {
            continue;
        }
        let modified_ms = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .unwrap_or_default()
            .as_millis() as u64;
        expected_stamps.insert(name.clone(), (metadata.len(), modified_ms));
        moves.push(MoveOp {
            source_name: name.clone(),
            destination: format!("Unused/{name}"),
            duration_ms: 0,
        });
    }
    let archived_count = moves.len() - selected_count;
    let timestamp = Local::now().format("%Y-%m-%d_%H%M%S").to_string();
    let (staging, final_path) = (0..100)
        .find_map(|suffix| {
            let tag = if suffix == 0 {
                timestamp.clone()
            } else {
                format!("{timestamp}-{suffix}")
            };
            let staging = folder.join(format!(".building-{tag}"));
            let final_path = folder.join(format!("Chabot News Comps {tag}"));
            (!staging.exists() && !final_path.exists()).then_some((staging, final_path))
        })
        .ok_or_else(|| ExportError("Unable to choose a unique export folder name".into()))?;
    fs::create_dir(&staging)
        .map_err(|e| ExportError(format!("Unable to create export folder: {e}")))?;
    let journal = Journal {
        version: 1,
        seed: plan.seed,
        moves,
    };
    if let Err(error) = write_journal(&staging, &journal) {
        let _ = fs::remove_dir_all(&staging);
        return Err(error);
    }
    for assignment in &plan.assignments {
        fs::create_dir(staging.join(format!("Comp {}", assignment.comp)))
            .map_err(|e| ExportError(e.to_string()))?;
    }
    fs::create_dir(staging.join("Unused")).map_err(|e| ExportError(e.to_string()))?;
    write_manifest(&staging, folder, &journal, selected_count)?;
    for operation in &journal.moves {
        let source = folder.join(&operation.source_name);
        let destination = staging.join(&operation.destination);
        let expected = expected_stamps.get(&operation.source_name).unwrap();
        let still_valid = fs::symlink_metadata(&source)
            .ok()
            .filter(|meta| meta.file_type().is_file())
            .is_some_and(|meta| {
                let modified_ms = meta
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                    .unwrap_or_default()
                    .as_millis() as u64;
                meta.len() == expected.0 && modified_ms == expected.1
            });
        if !still_valid {
            let rollback = rollback(folder, &staging, &journal);
            return Err(ExportError(format!(
                "{} changed during Build; rollback: {rollback:?}",
                operation.source_name
            )));
        }
        if let Err(error) = fs::rename(&source, &destination) {
            let rollback = rollback(folder, &staging, &journal);
            return Err(ExportError(match rollback {
                Ok(()) => format!(
                    "Move failed for {}: {error}; all moved files were restored",
                    operation.source_name
                ),
                Err(e) => format!(
                    "Move failed for {}: {error}; recovery folder retained at {}: {e}",
                    operation.source_name,
                    staging.display()
                ),
            }));
        }
    }
    if let Err(error) = fs::rename(&staging, &final_path) {
        let rollback = rollback(folder, &staging, &journal);
        return Err(ExportError(format!(
            "Unable to finish export: {error}; rollback: {rollback:?}"
        )));
    }
    Ok(BuildResult {
        output_folder: final_path.to_string_lossy().into_owned(),
        selected_clips: selected_count,
        archived_clips: archived_count,
        selected_duration_ms: plan.selected_duration_ms,
    })
}

pub fn recover_interrupted_builds(folder: &Path) -> Result<(), ExportError> {
    for entry in fs::read_dir(folder).map_err(|e| ExportError(e.to_string()))? {
        let entry = entry.map_err(|e| ExportError(e.to_string()))?;
        if !entry
            .file_type()
            .map_err(|e| ExportError(e.to_string()))?
            .is_dir()
        {
            continue;
        }
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with(".building-")
        {
            continue;
        }
        let path = entry.path();
        let journal: Journal = serde_json::from_reader(
            File::open(path.join("journal.json"))
                .map_err(|e| ExportError(format!("Cannot recover {}: {e}", path.display())))?,
        )
        .map_err(|e| {
            ExportError(format!(
                "Invalid recovery journal in {}: {e}",
                path.display()
            ))
        })?;
        rollback(folder, &path, &journal)?;
    }
    Ok(())
}

fn write_journal(staging: &Path, journal: &Journal) -> Result<(), ExportError> {
    let path = staging.join("journal.json");
    let mut file = File::create(path).map_err(|e| ExportError(e.to_string()))?;
    serde_json::to_writer_pretty(&mut file, journal).map_err(|e| ExportError(e.to_string()))?;
    file.flush().map_err(|e| ExportError(e.to_string()))?;
    file.sync_all().map_err(|e| ExportError(e.to_string()))
}

fn write_manifest(
    staging: &Path,
    folder: &Path,
    journal: &Journal,
    selected_count: usize,
) -> Result<(), ExportError> {
    let old_names = original_names(folder);
    let mut writer = csv::Writer::from_path(staging.join("manifest.csv"))
        .map_err(|e| ExportError(e.to_string()))?;
    writer
        .write_record([
            "original_cnn_filename",
            "input_filename",
            "output_path",
            "video_duration_ms",
            "selected",
            "random_seed",
        ])
        .map_err(|e| ExportError(e.to_string()))?;
    for (index, operation) in journal.moves.iter().enumerate() {
        let original = old_names
            .get(&operation.source_name)
            .map(String::as_str)
            .unwrap_or(&operation.source_name);
        writer
            .write_record([
                original,
                &operation.source_name,
                &operation.destination,
                &operation.duration_ms.to_string(),
                if index < selected_count { "yes" } else { "no" },
                &journal.seed.to_string(),
            ])
            .map_err(|e| ExportError(e.to_string()))?;
    }
    writer.flush().map_err(|e| ExportError(e.to_string()))
}

fn original_names(folder: &Path) -> HashMap<String, String> {
    let mut result = HashMap::new();
    if let Ok(entries) = fs::read_dir(folder) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with("rename-map-") || !name.ends_with(".csv") {
                continue;
            }
            if let Ok(mut reader) = csv::Reader::from_path(entry.path()) {
                for row in reader.records().flatten() {
                    if row.len() >= 2 {
                        result.insert(row[1].to_owned(), row[0].to_owned());
                    }
                }
            }
        }
    }
    result
}

fn rollback(folder: &Path, staging: &Path, journal: &Journal) -> Result<(), ExportError> {
    for operation in journal.moves.iter().rev() {
        let source = folder.join(&operation.source_name);
        let destination = staging.join(&operation.destination);
        if destination.exists() {
            if source.exists() {
                return Err(ExportError(format!(
                    "Both source and staged copy exist for {}",
                    operation.source_name
                )));
            }
            fs::rename(&destination, &source).map_err(|e| {
                ExportError(format!("Cannot restore {}: {e}", operation.source_name))
            })?;
        }
    }
    fs::remove_dir_all(staging)
        .map_err(|e| ExportError(format!("Cannot remove recovery folder: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation::{Assignment, COMP_NUMBERS, TARGET_MS};
    use std::fs::FileTimes;

    fn clip(path: &Path, duration_ms: u64) -> Clip {
        let meta = fs::metadata(path).unwrap();
        Clip {
            filename: path.file_name().unwrap().to_string_lossy().into_owned(),
            duration_ms,
            size_bytes: meta.len(),
            modified_ms: meta
                .modified()
                .unwrap()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis() as u64,
        }
    }

    fn fixture(folder: &Path) -> (Vec<Clip>, Plan) {
        let mut clips = Vec::new();
        let mut assignments = Vec::new();
        for comp in COMP_NUMBERS {
            let filename = format!("source-{comp}.mpg");
            let path = folder.join(&filename);
            fs::write(&path, format!("video-{comp}")).unwrap();
            clips.push(clip(&path, TARGET_MS));
            assignments.push(Assignment {
                comp,
                filenames: vec![filename],
                duration_ms: TARGET_MS,
            });
        }
        fs::write(folder.join("extra.mpg"), b"extra").unwrap();
        clips.push(clip(&folder.join("extra.mpg"), 20_000));
        (
            clips,
            Plan {
                seed: 42,
                assignments,
                selected_duration_ms: TARGET_MS * 14,
            },
        )
    }

    #[test]
    fn build_moves_selected_and_archives_unused_files() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        fs::write(
            temp.path().join("rename-map-2026.csv"),
            "Original filename,New filename\nCNN original.mpg,source-2.mpg\n",
        )
        .unwrap();
        let unreadable = temp.path().join("unreadable.mpg");
        fs::write(&unreadable, b"not a video").unwrap();
        File::open(&unreadable)
            .unwrap()
            .set_times(FileTimes::new().set_modified(SystemTime::now() - Duration::from_secs(30)))
            .unwrap();
        let result = build_export_with(temp.path(), &clips, &plan, |path| {
            Ok(if path.file_name().unwrap() == "extra.mpg" {
                20_000
            } else {
                TARGET_MS
            })
        })
        .unwrap();
        assert_eq!(result.selected_clips, 14);
        assert_eq!(result.archived_clips, 2);
        let output = Path::new(&result.output_folder);
        assert!(output.join("Unused/extra.mpg").exists());
        assert!(output.join("Unused/unreadable.mpg").exists());
        assert_eq!(fs::read_dir(output.join("Comp 2")).unwrap().count(), 1);
        let manifest = fs::read_to_string(output.join("manifest.csv")).unwrap();
        assert!(manifest.contains("CNN original.mpg,source-2.mpg"));
        let mut names = HashSet::new();
        for comp in COMP_NUMBERS {
            let entry = fs::read_dir(output.join(format!("Comp {comp}")))
                .unwrap()
                .next()
                .unwrap()
                .unwrap();
            let name = entry.file_name().to_string_lossy().into_owned();
            assert!(
                name.ends_with(".mpg")
                    && name.len() == 12
                    && name[..8].bytes().all(|b| b.is_ascii_digit())
            );
            assert!(names.insert(name));
        }
        assert!(!temp.path().join("source-2.mpg").exists());
    }

    #[test]
    fn changed_file_prevents_all_moves() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        fs::write(temp.path().join("source-2.mpg"), b"changed size").unwrap();
        assert!(build_export_with(temp.path(), &clips, &plan, |_| Ok(TARGET_MS)).is_err());
        assert!(temp.path().join("source-3.mpg").exists());
        assert!(!temp.path().join("Comp 3").exists());
    }

    #[test]
    fn change_after_preflight_rolls_back_earlier_moves() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        let mut calls = 0;
        let result = build_export_with(temp.path(), &clips, &plan, |_| {
            calls += 1;
            if calls == clips.len() {
                fs::write(temp.path().join("source-3.mpg"), b"changed during build").unwrap();
            }
            Ok(if calls == clips.len() {
                20_000
            } else {
                TARGET_MS
            })
        });
        assert!(result.is_err());
        assert!(temp.path().join("source-2.mpg").exists());
        assert!(temp.path().join("source-3.mpg").exists());
        assert!(!fs::read_dir(temp.path()).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".building-")
        }));
    }

    #[test]
    fn recovery_restores_a_partially_moved_build() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path();
        let staging = folder.join(".building-test");
        fs::create_dir(&staging).unwrap();
        fs::create_dir(staging.join("Comp 2")).unwrap();
        fs::write(staging.join("Comp 2/12345678.mpg"), b"sample").unwrap();
        let journal = Journal {
            version: 1,
            seed: 1,
            moves: vec![MoveOp {
                source_name: "a.mpg".into(),
                destination: "Comp 2/12345678.mpg".into(),
                duration_ms: 1,
            }],
        };
        write_journal(&staging, &journal).unwrap();
        recover_interrupted_builds(folder).unwrap();
        assert_eq!(fs::read(folder.join("a.mpg")).unwrap(), b"sample");
        assert!(!staging.exists());
    }
}
