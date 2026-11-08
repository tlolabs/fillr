use crate::allocation::{Plan, Rng};
use crate::probe::VideoProbe;
use crate::scan::Clip;
use crate::settings::SortSettings;
use chrono::Local;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Write};
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
    #[serde(default)]
    folder_names: Vec<String>,
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
    build_export_filtered(folder, probe, clips, plan, &HashSet::new(), true)
}

pub fn build_export_filtered(
    folder: &Path,
    probe: &VideoProbe,
    clips: &[Clip],
    plan: &Plan,
    excluded: &HashSet<String>,
    archive_unscanned: bool,
) -> Result<BuildResult, ExportError> {
    build_export_filtered_with(
        folder,
        probe,
        clips,
        plan,
        excluded,
        archive_unscanned,
        &SortSettings::default(),
    )
}

pub fn build_export_filtered_with(
    folder: &Path,
    probe: &VideoProbe,
    clips: &[Clip],
    plan: &Plan,
    excluded: &HashSet<String>,
    archive_unscanned: bool,
    settings: &SortSettings,
) -> Result<BuildResult, ExportError> {
    build_export_with_settings(
        folder,
        clips,
        plan,
        excluded,
        archive_unscanned,
        settings,
        |path| {
            probe
                .duration_ms(path)
                .map_err(|e| ExportError(e.to_string()))
        },
    )
}

#[cfg(test)]
fn build_export_with<F>(
    folder: &Path,
    clips: &[Clip],
    plan: &Plan,
    duration_of: F,
) -> Result<BuildResult, ExportError>
where
    F: FnMut(&Path) -> Result<u64, ExportError>,
{
    build_export_with_exclusions(folder, clips, plan, &HashSet::new(), true, duration_of)
}

#[cfg(test)]
fn build_export_with_exclusions<F>(
    folder: &Path,
    clips: &[Clip],
    plan: &Plan,
    excluded: &HashSet<String>,
    archive_unscanned: bool,
    duration_of: F,
) -> Result<BuildResult, ExportError>
where
    F: FnMut(&Path) -> Result<u64, ExportError>,
{
    build_export_with_settings(
        folder,
        clips,
        plan,
        excluded,
        archive_unscanned,
        &SortSettings::default(),
        duration_of,
    )
}

#[cfg(test)]
fn build_export_with_hook<F, H>(
    folder: &Path,
    clips: &[Clip],
    plan: &Plan,
    duration_of: F,
    hook: H,
) -> Result<BuildResult, ExportError>
where
    F: FnMut(&Path) -> Result<u64, ExportError>,
    H: FnMut(ExportHookEvent<'_>) -> Result<(), ExportError>,
{
    build_export_with_settings_and_hook(
        folder,
        clips,
        plan,
        &HashSet::new(),
        true,
        &SortSettings::default(),
        duration_of,
        hook,
    )
}

#[allow(dead_code)]
#[derive(Debug)]
pub enum ExportHookEvent<'a> {
    BeforeMove {
        index: usize,
        source: &'a Path,
        destination: &'a Path,
    },
    AfterMove {
        index: usize,
        source: &'a Path,
        destination: &'a Path,
    },
    BeforePublish {
        staging: &'a Path,
        final_path: &'a Path,
    },
}

pub fn sanitize_spreadsheet_field(value: &str) -> String {
    let trimmed = value.trim_start();
    if trimmed.starts_with(['=', '+', '-', '@']) || value.starts_with(['\t', '\r']) {
        format!("'{value}")
    } else {
        value.to_string()
    }
}

fn build_export_with_settings<F>(
    folder: &Path,
    clips: &[Clip],
    plan: &Plan,
    excluded: &HashSet<String>,
    archive_unscanned: bool,
    settings: &SortSettings,
    duration_of: F,
) -> Result<BuildResult, ExportError>
where
    F: FnMut(&Path) -> Result<u64, ExportError>,
{
    build_export_with_settings_and_hook(
        folder,
        clips,
        plan,
        excluded,
        archive_unscanned,
        settings,
        duration_of,
        |_| Ok(()),
    )
}

#[allow(clippy::too_many_arguments)]
fn build_export_with_settings_and_hook<F, H>(
    folder: &Path,
    clips: &[Clip],
    plan: &Plan,
    excluded: &HashSet<String>,
    archive_unscanned: bool,
    settings: &SortSettings,
    mut duration_of: F,
    mut hook: H,
) -> Result<BuildResult, ExportError>
where
    F: FnMut(&Path) -> Result<u64, ExportError>,
    H: FnMut(ExportHookEvent<'_>) -> Result<(), ExportError>,
{
    let durations: Vec<_> = clips
        .iter()
        .map(|c| (c.filename.clone(), c.duration_ms))
        .collect();
    if !plan.validate_with(&durations, settings) {
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
    let mut rng = Rng::new(plan.seed ^ 0xa5a5_92ee_6431_02ac);
    let mut new_names = HashSet::new();
    let mut selected = HashSet::new();
    let mut moves = Vec::new();
    for (index, assignment) in plan.assignments.iter().enumerate() {
        for source in &assignment.filenames {
            selected.insert(source.clone());
            let mut attempts = 0;
            let new_name = loop {
                attempts += 1;
                if attempts > 100_000 {
                    return Err(ExportError(
                        "Unable to allocate unique clip export names".into(),
                    ));
                }
                let extension = Path::new(source)
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("mpg");
                let candidate = format!("{:08}.{extension}", rng.next() % 100_000_000);
                if new_names.insert(candidate.clone()) {
                    break candidate;
                }
            };
            moves.push(MoveOp {
                source_name: source.clone(),
                destination: format!("{}/{}", settings.folder_name(index), new_name),
                duration_ms: clips
                    .iter()
                    .find(|c| &c.filename == source)
                    .map(|c| c.duration_ms)
                    .unwrap_or(0),
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
    if archive_unscanned {
        let now = SystemTime::now();
        let entries: Vec<_> = fs::read_dir(folder)
            .map_err(|e| ExportError(e.to_string()))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| ExportError(e.to_string()))?;
        let temporary_companions: HashSet<String> = entries
            .iter()
            .filter_map(|entry| {
                let filename = entry.file_name().to_string_lossy().into_owned();
                let lower = filename.to_ascii_lowercase();
                if lower.starts_with("#work_file#") {
                    Some(filename["#work_file#".len()..].to_owned())
                } else if lower.starts_with("#chkpt_file#") {
                    Some(filename["#chkpt_file#".len()..].to_owned())
                } else {
                    None
                }
            })
            .collect();
        for entry in entries {
            let name = entry.file_name().to_string_lossy().into_owned();
            let upper = name.to_ascii_uppercase();
            if expected_stamps.contains_key(&name)
                || excluded.contains(&name)
                || temporary_companions.contains(&name)
                || name.starts_with('.')
                || upper.starts_with("#WORK")
                || upper.starts_with("#CHKPT")
                || !entry.path().extension().is_some_and(|ext| {
                    [
                        "mpg", "mpeg", "mp4", "mov", "mxf", "ts", "m2ts", "avi", "mkv",
                    ]
                    .iter()
                    .any(|allowed| ext.eq_ignore_ascii_case(allowed))
                })
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
        version: 2,
        seed: plan.seed,
        folder_names: (0..settings.folder_count)
            .map(|i| settings.folder_name(i))
            .collect(),
        moves,
    };
    if let Err(error) = write_journal(&staging, &journal) {
        let _ = fs::remove_dir_all(&staging);
        return Err(error);
    }
    for index in 0..settings.folder_count {
        fs::create_dir(staging.join(settings.folder_name(index)))
            .map_err(|e| ExportError(e.to_string()))?;
    }
    fs::create_dir(staging.join("Unused")).map_err(|e| ExportError(e.to_string()))?;
    write_manifest(&staging, folder, &journal, selected_count)?;
    for (index, operation) in journal.moves.iter().enumerate() {
        let source = folder.join(&operation.source_name);
        let destination = staging.join(&operation.destination);
        if let Err(error) = hook(ExportHookEvent::BeforeMove {
            index,
            source: &source,
            destination: &destination,
        }) {
            let rollback = rollback(folder, &staging, &journal);
            return Err(ExportError(format!(
                "Move error for {}: {error}; rollback: {rollback:?}",
                operation.source_name
            )));
        }
        if let Err(error) = ensure_no_transfer_marker(folder, &operation.source_name) {
            let rollback = rollback(folder, &staging, &journal);
            return Err(ExportError(format!("{error}; rollback: {rollback:?}")));
        }
        let Some(expected) = expected_stamps.get(&operation.source_name) else {
            let rollback = rollback(folder, &staging, &journal);
            return Err(ExportError(format!(
                "Missing expected stamp for {}; rollback: {rollback:?}",
                operation.source_name
            )));
        };
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
        if let Err(error) = hook(ExportHookEvent::AfterMove {
            index,
            source: &source,
            destination: &destination,
        }) {
            let rollback = rollback(folder, &staging, &journal);
            return Err(ExportError(format!(
                "Post-move error for {}: {error}; rollback: {rollback:?}",
                operation.source_name
            )));
        }
    }
    if let Err(error) = hook(ExportHookEvent::BeforePublish {
        staging: &staging,
        final_path: &final_path,
    }) {
        let rollback = rollback(folder, &staging, &journal);
        return Err(ExportError(format!(
            "Pre-publish error: {error}; rollback: {rollback:?}"
        )));
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

fn ensure_no_transfer_marker(folder: &Path, source_name: &str) -> Result<(), ExportError> {
    // A scanned file may have started another transfer since the scan, or a
    // marker may have arrived after this build began. Check every move, including
    // selected clips and scanned clips destined for Unused.
    for entry in fs::read_dir(folder).map_err(|e| ExportError(e.to_string()))? {
        let entry = entry.map_err(|e| ExportError(e.to_string()))?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let lower = name.to_ascii_lowercase();
        for prefix in ["#work_file#", "#chkpt_file#"] {
            if lower.starts_with(prefix) && &name[prefix.len()..] == source_name {
                return Err(ExportError(format!(
                    "{source_name} has an active transfer marker"
                )));
            }
        }
    }
    Ok(())
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
        let journal_path = path.join("journal.json");
        let meta = match fs::symlink_metadata(&journal_path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let mut dir_entries =
                    fs::read_dir(&path).map_err(|e| ExportError(e.to_string()))?;
                if dir_entries.next().is_none() {
                    let _ = fs::remove_dir(&path);
                    continue;
                }
                return Err(ExportError(format!(
                    "Interrupted build folder {} is missing journal.json; recovery retained",
                    path.display()
                )));
            }
            Err(e) => return Err(ExportError(e.to_string())),
        };
        if !meta.file_type().is_file() {
            return Err(ExportError(
                "Recovery journal must be a regular file".into(),
            ));
        }
        let journal: Journal = serde_json::from_reader(
            File::open(journal_path)
                .map_err(|e| ExportError(format!("Cannot recover {}: {e}", path.display())))?
                .take(4 * 1024 * 1024),
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
    let old_names = original_names(folder)?;
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
        let original_field = sanitize_spreadsheet_field(original);
        let source_field = sanitize_spreadsheet_field(&operation.source_name);
        let dest_field = sanitize_spreadsheet_field(&operation.destination);
        let duration_field = operation.duration_ms.to_string();
        let seed_field = journal.seed.to_string();
        writer
            .write_record([
                original_field.as_str(),
                source_field.as_str(),
                dest_field.as_str(),
                duration_field.as_str(),
                if index < selected_count { "yes" } else { "no" },
                seed_field.as_str(),
            ])
            .map_err(|e| ExportError(e.to_string()))?;
    }
    writer.flush().map_err(|e| ExportError(e.to_string()))?;
    let file = writer
        .into_inner()
        .map_err(|e| ExportError(e.to_string()))?;
    file.sync_all().map_err(|e| ExportError(e.to_string()))
}

fn original_names(folder: &Path) -> Result<HashMap<String, String>, ExportError> {
    let mut result = HashMap::new();
    let entries =
        fs::read_dir(folder).map_err(|e| ExportError(format!("Unable to read folder: {e}")))?;
    for entry in entries {
        let entry = entry.map_err(|e| ExportError(format!("Directory entry error: {e}")))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with("rename-map-") || !name.ends_with(".csv") {
            continue;
        }
        let mut reader = csv::Reader::from_path(entry.path()).map_err(|e| {
            ExportError(format!(
                "Failed to open rename map {}: {e}",
                entry.path().display()
            ))
        })?;
        for row in reader.records() {
            let row = row.map_err(|e| {
                ExportError(format!(
                    "Failed to read record in {}: {e}",
                    entry.path().display()
                ))
            })?;
            if row.len() >= 2 {
                result.insert(row[1].to_owned(), row[0].to_owned());
            }
        }
    }
    Ok(result)
}

// Recovery metadata is input from the watched folder. Validate every operation
// and every staged entry before moving anything or deleting recovery material.
fn validate_recovery(folder: &Path, staging: &Path, journal: &Journal) -> Result<(), ExportError> {
    let invalid = || {
        ExportError(
            "Unsafe recovery journal or unexpected staged content; recovery folder retained".into(),
        )
    };
    fn component(value: &str) -> bool {
        !value.is_empty()
            && value != "."
            && value != ".."
            && !value.contains(['/', '\\', ':'])
            && Path::new(value).components().count() == 1
    }
    let groups: Vec<String> = if journal.version == 1 {
        crate::allocation::COMP_NUMBERS
            .iter()
            .map(|n| format!("Comp {n}"))
            .collect()
    } else {
        journal.folder_names.clone()
    };
    let unique: HashSet<_> = groups.iter().collect();
    if !matches!(journal.version, 1 | 2)
        || groups.is_empty()
        || groups.len() > 100
        || unique.len() != groups.len()
        || groups
            .iter()
            .any(|name| !component(name) || name == "Unused")
        || !fs::symlink_metadata(staging)
            .map_err(|e| ExportError(e.to_string()))?
            .file_type()
            .is_dir()
    {
        return Err(invalid());
    }
    let mut sources = HashSet::new();
    let mut destinations = HashSet::new();
    for operation in &journal.moves {
        let parts: Vec<_> = operation.destination.split('/').collect();
        if !component(&operation.source_name)
            || parts.len() != 2
            || (parts[0] != "Unused" && !groups.iter().any(|name| name == parts[0]))
            || !component(parts[1])
            || !sources.insert(&operation.source_name)
            || !destinations.insert(&operation.destination)
        {
            return Err(invalid());
        }
        let parent = staging.join(parts[0]);
        if let Ok(meta) = fs::symlink_metadata(&parent)
            && !meta.file_type().is_dir()
        {
            return Err(invalid());
        }
        for path in [
            folder.join(&operation.source_name),
            staging.join(&operation.destination),
        ] {
            match fs::symlink_metadata(&path) {
                Ok(meta) if !meta.file_type().is_file() => return Err(invalid()),
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                    return Err(ExportError(error.to_string()));
                }
                _ => {}
            }
        }
        if folder.join(&operation.source_name).exists()
            && staging.join(&operation.destination).exists()
        {
            return Err(invalid());
        }
    }
    for entry in fs::read_dir(staging).map_err(|e| ExportError(e.to_string()))? {
        let entry = entry.map_err(|e| ExportError(e.to_string()))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let kind = entry.file_type().map_err(|e| ExportError(e.to_string()))?;
        if kind.is_file() && ["journal.json", "manifest.csv"].contains(&name.as_str()) {
            continue;
        }
        if !kind.is_dir() || (name != "Unused" && !groups.contains(&name)) {
            return Err(invalid());
        }
        for child in fs::read_dir(entry.path()).map_err(|e| ExportError(e.to_string()))? {
            let child = child.map_err(|e| ExportError(e.to_string()))?;
            let relative = format!("{name}/{}", child.file_name().to_string_lossy());
            if !child
                .file_type()
                .map_err(|e| ExportError(e.to_string()))?
                .is_file()
                || !destinations.contains(&relative)
            {
                return Err(invalid());
            }
        }
    }
    Ok(())
}

fn rollback(folder: &Path, staging: &Path, journal: &Journal) -> Result<(), ExportError> {
    validate_recovery(folder, staging, journal)?;
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
    // Never recursively delete a recovery directory: files arriving after the
    // preflight must survive as well. Only remove empty expected directories.
    for entry in fs::read_dir(staging).map_err(|e| ExportError(e.to_string()))? {
        let entry = entry.map_err(|e| ExportError(e.to_string()))?;
        if entry
            .file_type()
            .map_err(|e| ExportError(e.to_string()))?
            .is_dir()
        {
            fs::remove_dir(entry.path())
                .map_err(|e| ExportError(format!("Recovery folder retained: {e}")))?;
        } else if !["journal.json", "manifest.csv"]
            .contains(&entry.file_name().to_string_lossy().as_ref())
        {
            return Err(ExportError("Unexpected recovery file retained".into()));
        }
    }
    for name in ["manifest.csv", "journal.json"] {
        match fs::remove_file(staging.join(name)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(ExportError(e.to_string())),
        }
    }
    fs::remove_dir(staging).map_err(|e| ExportError(format!("Cannot remove recovery folder: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation::{Assignment, COMP_NUMBERS, TARGET_MS};
    use crate::settings::SortSettings;
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
        File::options()
            .write(true)
            .open(&unreadable)
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
    fn build_uses_configured_prefix_and_count() {
        let temp = tempfile::tempdir().unwrap();
        let settings = SortSettings {
            folder_count: 2,
            folder_prefix: "Scene".into(),
            total_ms: 2_000,
        };
        let mut clips = Vec::new();
        let mut assignments = Vec::new();
        for index in 0..2 {
            let name = format!("source-{index}.mpg");
            fs::write(temp.path().join(&name), b"video").unwrap();
            clips.push(clip(&temp.path().join(&name), 1_000));
            assignments.push(Assignment {
                comp: settings.number(index) as u8,
                filenames: vec![name],
                duration_ms: 1_000,
            });
        }
        let plan = Plan {
            seed: 42,
            assignments,
            selected_duration_ms: 2_000,
        };
        let result = build_export_with_settings(
            temp.path(),
            &clips,
            &plan,
            &HashSet::new(),
            false,
            &settings,
            |_| Ok(1_000),
        )
        .unwrap();
        let output = Path::new(&result.output_folder);
        assert_eq!(fs::read_dir(output.join("Scene 1")).unwrap().count(), 1);
        assert_eq!(fs::read_dir(output.join("Scene 2")).unwrap().count(), 1);
    }

    #[test]
    fn filtered_build_leaves_unscanned_media_in_download_folder() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        let rejected = temp.path().join("rejected.mpg");
        fs::write(&rejected, b"wrong media profile").unwrap();
        let result = build_export_with_exclusions(
            temp.path(),
            &clips,
            &plan,
            &HashSet::new(),
            false,
            |path| {
                Ok(if path.file_name().unwrap() == "extra.mpg" {
                    20_000
                } else {
                    TARGET_MS
                })
            },
        )
        .unwrap();
        assert!(rejected.exists());
        assert!(
            !Path::new(&result.output_folder)
                .join("Unused/rejected.mpg")
                .exists()
        );
        assert_eq!(result.archived_clips, 1);
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
    fn companion_markers_prevent_moving_scanned_clips() {
        for source in ["source-2.mpg", "extra.mpg"] {
            for prefix in ["#work_file#", "#CHKPT_FILE#", "#WoRk_FiLe#"] {
                let temp = tempfile::tempdir().unwrap();
                let (clips, plan) = fixture(temp.path());
                fs::write(
                    temp.path().join(format!("{prefix}{source}")),
                    b"active transfer",
                )
                .unwrap();
                let result = build_export_with(temp.path(), &clips, &plan, |path| {
                    Ok(if path.file_name().unwrap() == "extra.mpg" {
                        20_000
                    } else {
                        TARGET_MS
                    })
                });
                assert!(result.is_err(), "{prefix}{source} must prevent export");
                for clip in &clips {
                    assert!(temp.path().join(&clip.filename).exists());
                }
                assert!(!fs::read_dir(temp.path()).unwrap().any(|entry| {
                    entry
                        .unwrap()
                        .file_name()
                        .to_string_lossy()
                        .starts_with(".building-")
                }));
            }
        }
    }

    #[test]
    fn companion_marker_appearing_mid_build_rolls_back_prior_moves() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        let mut moved_count = 0;
        let result = build_export_with_hook(
            temp.path(),
            &clips,
            &plan,
            |path| {
                Ok(if path.file_name().unwrap() == "extra.mpg" {
                    20_000
                } else {
                    TARGET_MS
                })
            },
            |event| {
                match event {
                    ExportHookEvent::BeforeMove { index: 1, .. } => {
                        fs::write(
                            temp.path().join("#ChKpT_FiLe#source-3.mpg"),
                            b"active transfer",
                        )
                        .unwrap();
                    }
                    ExportHookEvent::AfterMove { .. } => moved_count += 1,
                    _ => {}
                }
                Ok(())
            },
        );
        assert!(result.is_err());
        assert_eq!(moved_count, 1);
        for clip in &clips {
            assert!(temp.path().join(&clip.filename).exists());
        }
        assert_eq!(
            fs::read(temp.path().join("source-2.mpg")).unwrap(),
            b"video-2"
        );
    }

    #[test]
    fn change_during_preflight_aborts_without_moving_files() {
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
    fn mid_move_identity_change_rolls_back_and_restores_files() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        let mut moved_count = 0;
        let result = build_export_with_hook(
            temp.path(),
            &clips,
            &plan,
            |path| {
                Ok(if path.file_name().unwrap() == "extra.mpg" {
                    20_000
                } else {
                    TARGET_MS
                })
            },
            |event| {
                if let ExportHookEvent::AfterMove { index, .. } = event {
                    moved_count += 1;
                    if index == 0 {
                        // Move 0 completed! Now mutate the source of move 1 before it is moved
                        fs::write(temp.path().join("source-3.mpg"), b"mutated mid-move").unwrap();
                    }
                }
                Ok(())
            },
        );
        assert!(result.is_err());
        assert!(moved_count >= 1);
        // Verify source-2.mpg was moved, and rollback moved it back!
        assert_eq!(
            fs::read(temp.path().join("source-2.mpg")).unwrap(),
            b"video-2"
        );
        assert_eq!(
            fs::read(temp.path().join("source-3.mpg")).unwrap(),
            b"mutated mid-move"
        );
        // Recovery folder was cleaned up on clean rollback
        assert!(!fs::read_dir(temp.path()).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".building-")
        }));
    }

    #[test]
    fn mid_move_rename_failure_rolls_back_and_restores_files() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        let mut moved_count = 0;
        let result = build_export_with_hook(
            temp.path(),
            &clips,
            &plan,
            |path| {
                Ok(if path.file_name().unwrap() == "extra.mpg" {
                    20_000
                } else {
                    TARGET_MS
                })
            },
            |event| {
                if let ExportHookEvent::AfterMove {
                    index: 0,
                    destination,
                    ..
                } = event
                {
                    moved_count += 1;
                    assert!(destination.exists());
                }
                if let ExportHookEvent::BeforeMove { index: 1, .. } = event {
                    return Err(ExportError("Injected rename failure".into()));
                }
                Ok(())
            },
        );
        assert!(result.is_err());
        assert_eq!(moved_count, 1);
        // source-2.mpg was restored by rollback
        assert_eq!(
            fs::read(temp.path().join("source-2.mpg")).unwrap(),
            b"video-2"
        );
    }

    #[test]
    fn final_publication_failure_rolls_back_and_restores_files() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        let result = build_export_with_hook(
            temp.path(),
            &clips,
            &plan,
            |path| {
                Ok(if path.file_name().unwrap() == "extra.mpg" {
                    20_000
                } else {
                    TARGET_MS
                })
            },
            |event| {
                if let ExportHookEvent::BeforePublish { final_path, .. } = event {
                    // Create collision at final_path so publication rename fails
                    fs::create_dir(final_path).unwrap();
                    fs::write(final_path.join("blocker.txt"), b"blocker").unwrap();
                }
                Ok(())
            },
        );
        assert!(result.is_err());
        // All original files restored to temp.path()
        for comp in COMP_NUMBERS {
            assert!(temp.path().join(format!("source-{comp}.mpg")).exists());
        }
    }

    #[test]
    fn rollback_failure_preserves_staging_recovery_material() {
        let temp = tempfile::tempdir().unwrap();
        let (clips, plan) = fixture(temp.path());
        let result = build_export_with_hook(
            temp.path(),
            &clips,
            &plan,
            |path| {
                Ok(if path.file_name().unwrap() == "extra.mpg" {
                    20_000
                } else {
                    TARGET_MS
                })
            },
            |event| {
                if let ExportHookEvent::AfterMove { index: 0, .. } = event {
                    // Re-create source-2.mpg in folder so rollback cannot restore move 0 without error
                    fs::write(temp.path().join("source-2.mpg"), b"colliding copy").unwrap();
                    // Mutate source-3.mpg so the next move fails and triggers rollback
                    fs::write(temp.path().join("source-3.mpg"), b"mutated").unwrap();
                }
                Ok(())
            },
        );
        assert!(result.is_err());
        // Rollback failed because source-2.mpg already exists; recovery folder must survive!
        let recovery_dirs: Vec<_> = fs::read_dir(temp.path())
            .unwrap()
            .filter_map(|e| {
                let name = e.unwrap().file_name().to_string_lossy().into_owned();
                name.starts_with(".building-").then_some(name)
            })
            .collect();
        assert_eq!(recovery_dirs.len(), 1);
        let staging = temp.path().join(&recovery_dirs[0]);
        assert!(staging.join("journal.json").exists());
    }

    #[test]
    fn manifest_neutralizes_spreadsheet_formula_prefixes() {
        let test_cases = [
            ("=1+1.mpg", "'=1+1.mpg"),
            ("   =1+1.mpg", "'   =1+1.mpg"),
            ("+cmd.mpg", "'+cmd.mpg"),
            (" +cmd.mpg", "' +cmd.mpg"),
            ("-calc.mpg", "'-calc.mpg"),
            ("@SUM(A1).mpg", "'@SUM(A1).mpg"),
            ("\tclip.mpg", "'\tclip.mpg"),
            ("\rvideo.mpg", "'\rvideo.mpg"),
            ("regular.mpg", "regular.mpg"),
            ("Unicode_ü_テスト.mpg", "Unicode_ü_テスト.mpg"),
            ("quotes\"commas,in,name.mpg", "quotes\"commas,in,name.mpg"),
        ];
        for (input, expected) in test_cases {
            assert_eq!(sanitize_spreadsheet_field(input), expected);
        }
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
            folder_names: vec![],
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
    #[test]
    fn recovery_accepts_configured_folder_names_without_relaxing_paths() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path();
        let staging = folder.join(".building-custom");
        fs::create_dir_all(staging.join("Scene 1")).unwrap();
        fs::write(staging.join("Scene 1/clip.mpg"), b"sample").unwrap();
        let journal = Journal {
            version: 2,
            seed: 1,
            folder_names: vec!["Scene 1".into()],
            moves: vec![MoveOp {
                source_name: "a.mpg".into(),
                destination: "Scene 1/clip.mpg".into(),
                duration_ms: 1000,
            }],
        };
        write_journal(&staging, &journal).unwrap();
        recover_interrupted_builds(folder).unwrap();
        assert_eq!(fs::read(folder.join("a.mpg")).unwrap(), b"sample");
        assert!(!staging.exists());
        let settings = SortSettings {
            folder_count: 1,
            folder_prefix: "Scene".into(),
            total_ms: 1000,
        };
        assert_eq!(settings.folder_name(0), "Scene 1");
    }

    #[test]
    fn recovery_cleans_up_empty_interrupted_staging_directory() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path();
        let staging = folder.join(".building-interrupted-empty");
        fs::create_dir(&staging).unwrap();
        assert!(staging.exists());
        recover_interrupted_builds(folder).unwrap();
        assert!(!staging.exists());
    }

    #[test]
    fn recovery_preserves_non_empty_staging_without_journal() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path();
        let staging = folder.join(".building-interrupted-data");
        fs::create_dir(&staging).unwrap();
        fs::write(staging.join("orphaned.mpg"), b"footage").unwrap();
        let err = recover_interrupted_builds(folder).unwrap_err();
        assert!(err.0.contains("missing journal.json"));
        assert!(staging.join("orphaned.mpg").exists());
    }
    #[test]
    fn hostile_recovery_paths_never_move_or_delete_files() {
        for (source, destination) in [
            ("../escaped", "Comp 2/clip.mpg"),
            ("/tmp/escaped", "Comp 2/clip.mpg"),
            ("clip.mpg", "../../outside"),
            ("clip.mpg", "/tmp/outside"),
            ("clip.mpg", "Comp 1/clip.mpg"),
        ] {
            let temp = tempfile::tempdir().unwrap();
            let folder = temp.path().join("watched");
            let staging = folder.join(".building-test");
            fs::create_dir_all(staging.join("Comp 2")).unwrap();
            fs::write(staging.join("Comp 2/clip.mpg"), b"preserve").unwrap();
            let journal = Journal {
                version: 1,
                seed: 0,
                folder_names: vec![],
                moves: vec![MoveOp {
                    source_name: source.into(),
                    destination: destination.into(),
                    duration_ms: 1,
                }],
            };
            write_journal(&staging, &journal).unwrap();
            assert!(recover_interrupted_builds(&folder).is_err());
            assert_eq!(
                fs::read(staging.join("Comp 2/clip.mpg")).unwrap(),
                b"preserve"
            );
            assert!(!temp.path().join("escaped").exists());
        }
    }
    #[test]
    fn recovery_rejects_unknown_versions_duplicate_moves_and_extra_files() {
        for mode in 0..3 {
            let temp = tempfile::tempdir().unwrap();
            let staging = temp.path().join(".building-test");
            fs::create_dir_all(staging.join("Comp 2")).unwrap();
            fs::write(staging.join("Comp 2/clip.mpg"), b"preserve").unwrap();
            let mut journal = Journal {
                version: 1,
                seed: 0,
                folder_names: vec![],
                moves: vec![MoveOp {
                    source_name: "clip.mpg".into(),
                    destination: "Comp 2/clip.mpg".into(),
                    duration_ms: 1,
                }],
            };
            match mode {
                0 => journal.version = 2,
                1 => journal.moves.push(MoveOp {
                    source_name: "clip.mpg".into(),
                    destination: "Unused/clip.mpg".into(),
                    duration_ms: 1,
                }),
                _ => fs::write(staging.join("unexpected"), b"user data").unwrap(),
            }
            write_journal(&staging, &journal).unwrap();
            assert!(recover_interrupted_builds(temp.path()).is_err());
            assert!(staging.join("Comp 2/clip.mpg").exists());
            assert!(!temp.path().join("clip.mpg").exists());
        }
    }
    #[cfg(unix)]
    #[test]
    fn recovery_rejects_symlinked_destination_directory() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("watched");
        let outside = temp.path().join("outside");
        let staging = folder.join(".building-test");
        fs::create_dir_all(&staging).unwrap();
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("clip.mpg"), b"outside").unwrap();
        std::os::unix::fs::symlink(&outside, staging.join("Comp 2")).unwrap();
        let journal = Journal {
            version: 1,
            seed: 0,
            folder_names: vec![],
            moves: vec![MoveOp {
                source_name: "clip.mpg".into(),
                destination: "Comp 2/clip.mpg".into(),
                duration_ms: 1,
            }],
        };
        write_journal(&staging, &journal).unwrap();
        assert!(recover_interrupted_builds(&folder).is_err());
        assert_eq!(fs::read(outside.join("clip.mpg")).unwrap(), b"outside");
    }

    #[test]
    fn build_export_skips_unscanned_files_with_active_companion_markers() {
        let temp = tempfile::tempdir().unwrap();
        let settings = SortSettings {
            folder_count: 1,
            folder_prefix: "Comp".into(),
            total_ms: 10_000,
        };
        let clip_path = temp.path().join("ready.mpg");
        fs::write(&clip_path, b"ready-video").unwrap();
        let meta = fs::symlink_metadata(&clip_path).unwrap();
        let modified_ms = meta
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let clips = vec![Clip {
            filename: "ready.mpg".into(),
            duration_ms: 10_000,
            size_bytes: meta.len(),
            modified_ms,
        }];
        let plan = Plan {
            seed: 42,
            assignments: vec![crate::allocation::Assignment {
                comp: 1,
                filenames: vec!["ready.mpg".into()],
                duration_ms: 10_000,
            }],
            selected_duration_ms: 10_000,
        };

        // Create an unscanned .mpg file with an old mtime (>= 10s ago) but an active #work_file# companion
        let active_transfer = temp.path().join("transferring.mpg");
        fs::write(&active_transfer, b"partial-data").unwrap();
        let old_time = SystemTime::now() - Duration::from_secs(30);
        File::options()
            .write(true)
            .open(&active_transfer)
            .unwrap()
            .set_modified(old_time)
            .unwrap();
        fs::write(temp.path().join("#work_file#transferring.mpg"), b"marker").unwrap();

        let result = build_export_with_settings(
            temp.path(),
            &clips,
            &plan,
            &HashSet::new(),
            true,
            &settings,
            |_| Ok(10_000),
        )
        .unwrap();
        assert_eq!(result.selected_clips, 1);
        assert_eq!(result.archived_clips, 0);
        assert!(
            active_transfer.exists(),
            "Active transfer with #work_file# companion must remain in watched folder"
        );
    }

    #[test]
    fn export_succeeds_even_when_plan_seed_cancels_rng_xor_mask() {
        let temp = tempfile::tempdir().unwrap();
        let settings = SortSettings {
            folder_count: 2,
            folder_prefix: "Comp".into(),
            total_ms: 20_000,
        };
        for name in ["clip1.mpg", "clip2.mpg"] {
            let p = temp.path().join(name);
            fs::write(&p, b"data").unwrap();
        }
        let c1 = clip(&temp.path().join("clip1.mpg"), 10_000);
        let c2 = clip(&temp.path().join("clip2.mpg"), 10_000);
        let clips = vec![c1, c2];
        let plan = Plan {
            seed: 0xa5a5_92ee_6431_02ac, // Exactly cancels XOR mask, yielding seed 0
            assignments: vec![
                crate::allocation::Assignment {
                    comp: 1,
                    filenames: vec!["clip1.mpg".into()],
                    duration_ms: 10_000,
                },
                crate::allocation::Assignment {
                    comp: 2,
                    filenames: vec!["clip2.mpg".into()],
                    duration_ms: 10_000,
                },
            ],
            selected_duration_ms: 20_000,
        };
        let res = build_export_with_settings(
            temp.path(),
            &clips,
            &plan,
            &HashSet::new(),
            false,
            &settings,
            |_| Ok(10_000),
        );
        assert!(res.is_ok(), "Zeroed RNG state must not hang or fail build");
    }

    #[test]
    fn archive_unscanned_handles_mp4_and_skips_uppercase_checkpoint() {
        let temp = tempfile::tempdir().unwrap();
        let settings = SortSettings {
            folder_count: 1,
            folder_prefix: "Comp".into(),
            total_ms: 10_000,
        };
        let clip_path = temp.path().join("ready.mpg");
        fs::write(&clip_path, b"ready-video").unwrap();
        let meta = fs::symlink_metadata(&clip_path).unwrap();
        let modified_ms = meta
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let clips = vec![Clip {
            filename: "ready.mpg".into(),
            duration_ms: 10_000,
            size_bytes: meta.len(),
            modified_ms,
        }];
        let plan = Plan {
            seed: 42,
            assignments: vec![crate::allocation::Assignment {
                comp: 1,
                filenames: vec!["ready.mpg".into()],
                duration_ms: 10_000,
            }],
            selected_duration_ms: 10_000,
        };

        // Create an unscanned .mp4 file aged 30s
        let extra_mp4 = temp.path().join("extra.mp4");
        fs::write(&extra_mp4, b"mp4-content").unwrap();
        let old_time = SystemTime::now() - Duration::from_secs(30);
        File::options()
            .write(true)
            .open(&extra_mp4)
            .unwrap()
            .set_modified(old_time)
            .unwrap();

        // Create an uppercase checkpoint sidecar aged 30s
        let chkpt = temp.path().join("#CHKPT_FILE#something.mpg");
        fs::write(&chkpt, b"checkpoint-marker").unwrap();
        File::options()
            .write(true)
            .open(&chkpt)
            .unwrap()
            .set_modified(old_time)
            .unwrap();

        let result = build_export_with_settings(
            temp.path(),
            &clips,
            &plan,
            &HashSet::new(),
            true, // archive_unscanned enabled
            &settings,
            |_| Ok(10_000),
        )
        .unwrap();

        assert_eq!(result.selected_clips, 1);
        assert_eq!(result.archived_clips, 1);
        let output = Path::new(&result.output_folder);
        assert!(
            output.join("Unused/extra.mp4").exists(),
            "extra.mp4 must be archived to Unused"
        );
        assert!(chkpt.exists(), "#CHKPT_FILE# must not be moved to Unused");
    }
}
