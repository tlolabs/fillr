use crate::allocation::{Plan, make_plan_with};
use crate::export::{BuildResult, build_export_filtered_with, recover_interrupted_builds};
use crate::media::MediaPolicy;
use crate::probe::VideoProbe;
use crate::settings::SortSettings;
use notify::{RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
#[cfg(target_os = "macos")]
use std::time::Instant;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const STABLE_FOR: Duration = Duration::from_secs(10);

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Clip {
    pub filename: String,
    pub duration_ms: u64,
    pub size_bytes: u64,
    pub modified_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExcludedFile {
    pub filename: String,
    pub reason: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Collecting,
    Checking,
    Ready,
    Building,
    Error,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub api_version: u32,
    pub folder: String,
    pub status: Status,
    pub available_ms: u64,
    pub remaining_ms: u64,
    pub clips: Vec<Clip>,
    pub pending: Vec<String>,
    pub excluded: Vec<ExcludedFile>,
    pub duplicate_log: Vec<String>,
    pub rejection_log: Vec<String>,
    pub plan: Option<Plan>,
    pub message: String,
}

impl Snapshot {
    fn empty(folder: &Path, settings: &SortSettings) -> Self {
        Self {
            api_version: 1,
            folder: folder.to_string_lossy().into_owned(),
            status: Status::Checking,
            available_ms: 0,
            remaining_ms: settings.total_ms,
            clips: vec![],
            pending: vec![],
            excluded: vec![],
            duplicate_log: vec![],
            rejection_log: vec![],
            plan: None,
            message: "Scanning folder…".into(),
        }
    }
}

#[derive(Debug)]
pub struct EngineError(pub String);

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for EngineError {}

#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    size: u64,
    modified_ms: u64,
    modified_ns: u128,
    identity: u128,
}

struct Cached {
    stamp: Stamp,
    media: Option<Result<crate::probe::MediaInfo, String>>,
    hash: Option<[u8; 32]>,
}

#[derive(Default)]
struct ScanContext {
    seen: HashMap<String, (Stamp, SystemTime)>,
    cached: HashMap<String, Cached>,
    duplicate_log: Vec<String>,
    rejection_log: Vec<String>,
}

pub struct Engine {
    folder: PathBuf,
    probe: VideoProbe,
    policy: Arc<Mutex<MediaPolicy>>,
    settings: Arc<Mutex<SortSettings>>,
    snapshot: Arc<Mutex<Snapshot>>,
    gate: Arc<Mutex<()>>,
    stop: Arc<AtomicBool>,
    wake: mpsc::Sender<()>,
    worker: Option<JoinHandle<()>>,
}

impl Engine {
    pub fn new(
        folder: impl Into<PathBuf>,
        ffprobe: impl Into<PathBuf>,
    ) -> Result<Self, EngineError> {
        Self::new_with_settings(
            folder,
            ffprobe,
            MediaPolicy::default(),
            SortSettings::default(),
        )
    }

    pub fn new_with_policy(
        folder: impl Into<PathBuf>,
        ffprobe: impl Into<PathBuf>,
        policy: MediaPolicy,
    ) -> Result<Self, EngineError> {
        Self::new_with_settings(folder, ffprobe, policy, SortSettings::default())
    }

    pub fn new_with_settings(
        folder: impl Into<PathBuf>,
        ffprobe: impl Into<PathBuf>,
        policy: MediaPolicy,
        settings: SortSettings,
    ) -> Result<Self, EngineError> {
        policy.validate().map_err(EngineError)?;
        settings.validate().map_err(EngineError)?;
        let folder = folder.into();
        if !folder.is_dir() {
            return Err(EngineError("Choose an existing download folder".into()));
        }
        recover_interrupted_builds(&folder).map_err(|e| EngineError(e.to_string()))?;
        let probe = VideoProbe::new(ffprobe);
        let policy = Arc::new(Mutex::new(policy));
        let snapshot = Arc::new(Mutex::new(Snapshot::empty(&folder, &settings)));
        let settings = Arc::new(Mutex::new(settings));
        let gate = Arc::new(Mutex::new(()));
        let stop = Arc::new(AtomicBool::new(false));
        let (wake, receiver) = mpsc::channel();
        let worker_folder = folder.clone();
        let worker_probe = probe.clone();
        let worker_policy = Arc::clone(&policy);
        let worker_settings = Arc::clone(&settings);
        let worker_snapshot = Arc::clone(&snapshot);
        let worker_gate = Arc::clone(&gate);
        let worker_stop = Arc::clone(&stop);
        let worker_wake = wake.clone();
        let worker = thread::spawn(move || {
            let mut context = ScanContext::default();
            let mut watcher = notify::recommended_watcher(move |_| {
                let _ = worker_wake.send(());
            })
            .ok();
            if let Some(watcher) = &mut watcher {
                let _ = watcher.watch(&worker_folder, RecursiveMode::NonRecursive);
            }
            loop {
                if worker_stop.load(Ordering::Relaxed) {
                    break;
                }
                let _guard = worker_gate.lock().unwrap();
                let current_policy = worker_policy.lock().unwrap().clone();
                let current_settings = worker_settings.lock().unwrap().clone();
                let next = scan_once_with(
                    &worker_folder,
                    &worker_probe,
                    &current_policy,
                    &current_settings,
                    &mut context,
                );
                *worker_snapshot.lock().unwrap() = next;
                drop(_guard);
                let _ = receiver.recv_timeout(Duration::from_secs(5));
                while receiver.try_recv().is_ok() {}
            }
        });
        Ok(Self {
            folder,
            probe,
            policy,
            settings,
            snapshot,
            gate,
            stop,
            wake,
            worker: Some(worker),
        })
    }

    pub fn snapshot(&self) -> Snapshot {
        self.snapshot.lock().unwrap().clone()
    }

    pub fn refresh(&self) {
        let _ = self.wake.send(());
    }

    pub fn set_policy(&self, policy: MediaPolicy) -> Result<(), EngineError> {
        policy.validate().map_err(EngineError)?;
        let _guard = self.gate.lock().unwrap();
        *self.policy.lock().unwrap() = policy;
        self.snapshot.lock().unwrap().status = Status::Checking;
        self.refresh();
        Ok(())
    }

    pub fn set_settings(&self, settings: SortSettings) -> Result<(), EngineError> {
        settings.validate().map_err(EngineError)?;
        let _guard = self.gate.lock().unwrap();
        *self.settings.lock().unwrap() = settings;
        self.snapshot.lock().unwrap().status = Status::Checking;
        self.refresh();
        Ok(())
    }

    pub fn build(&self) -> Result<BuildResult, EngineError> {
        let _guard = self.gate.lock().unwrap();
        let current = self.snapshot();
        if current.status != Status::Ready {
            return Err(EngineError("A verified folder layout is not ready".into()));
        }
        let plan = current.plan.as_ref().unwrap();
        self.snapshot.lock().unwrap().status = Status::Building;
        let policy = self.policy.lock().unwrap().clone();
        let settings = self.settings.lock().unwrap().clone();
        for clip in &current.clips {
            let path = self.folder.join(&clip.filename);
            let info = self
                .probe
                .media_info(&path)
                .map_err(|e| EngineError(e.to_string()))?;
            let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("");
            let reasons = policy.reject_reasons(extension, &info);
            if !reasons.is_empty() {
                return Err(EngineError(format!(
                    "{} no longer matches the media preferences: {}",
                    clip.filename,
                    reasons.join("; ")
                )));
            }
        }
        let excluded: HashSet<String> = current
            .excluded
            .iter()
            .map(|item| item.filename.clone())
            .collect();
        let result = build_export_filtered_with(
            &self.folder,
            &self.probe,
            &current.clips,
            plan,
            &excluded,
            !policy.enabled,
            &settings,
        )
        .map_err(|e| EngineError(e.to_string()));
        self.snapshot.lock().unwrap().status = Status::Checking;
        self.refresh();
        result
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = self.wake.send(());
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
fn scan_once(
    folder: &Path,
    probe: &VideoProbe,
    policy: &MediaPolicy,
    context: &mut ScanContext,
) -> Snapshot {
    scan_once_with(folder, probe, policy, &SortSettings::default(), context)
}

fn scan_once_with(
    folder: &Path,
    probe: &VideoProbe,
    policy: &MediaPolicy,
    settings: &SortSettings,
    context: &mut ScanContext,
) -> Snapshot {
    let mut snapshot = Snapshot::empty(folder, settings);
    let entries = match fs::read_dir(folder) {
        Ok(e) => e,
        Err(e) => {
            snapshot.status = Status::Error;
            snapshot.message = format!("Unable to read folder: {e}");
            return snapshot;
        }
    };
    let entries: Vec<_> = entries.flatten().collect();
    let now = SystemTime::now();
    let mut stable: BTreeMap<String, (PathBuf, Stamp)> = BTreeMap::new();
    let mut present = HashSet::new();
    let temporary_companions: HashSet<String> = entries
        .iter()
        .filter_map(|entry| {
            let filename = entry.file_name().to_string_lossy().into_owned();
            filename
                .strip_prefix("#work_file#")
                .or_else(|| filename.strip_prefix("#chkpt_file#"))
                .map(str::to_owned)
        })
        .collect();
    for entry in entries {
        let path = entry.path();
        let filename = entry.file_name().to_string_lossy().into_owned();
        if filename.starts_with("#work_file#") || filename.starts_with("#chkpt_file#") {
            continue;
        }
        if filename.starts_with('.')
            || filename.to_ascii_uppercase().starts_with("#WORK")
            || !entry.file_type().is_ok_and(|kind| kind.is_file())
            || !path.extension().is_some_and(|x| {
                [
                    "mpg", "mpeg", "mp4", "mov", "mxf", "ts", "m2ts", "avi", "mkv",
                ]
                .iter()
                .any(|allowed| x.eq_ignore_ascii_case(allowed))
            })
        {
            continue;
        }
        present.insert(filename.clone());
        let Ok(metadata) = entry.metadata() else {
            snapshot.excluded.push(ExcludedFile {
                filename,
                reason: "Cannot read metadata".into(),
            });
            continue;
        };
        let stamp = stamp(&metadata);
        let first_seen = context.seen.entry(filename.clone()).or_insert((stamp, now));
        if first_seen.0 != stamp {
            *first_seen = (stamp, now);
        }
        let unchanged = now.duration_since(first_seen.1).unwrap_or_default() >= STABLE_FOR;
        let old_enough = metadata
            .modified()
            .ok()
            .and_then(|t| now.duration_since(t).ok())
            .unwrap_or_default()
            >= STABLE_FOR;
        if !old_enough || !unchanged || temporary_companions.contains(&filename) {
            snapshot.pending.push(filename);
            continue;
        }
        stable.insert(filename, (path, stamp));
    }
    context.seen.retain(|name, _| present.contains(name));
    context.cached.retain(|name, _| present.contains(name));

    let mut by_size: BTreeMap<u64, Vec<String>> = BTreeMap::new();
    for (name, (_, stamp)) in &stable {
        by_size.entry(stamp.size).or_default().push(name.clone());
    }
    let mut duplicates = HashSet::new();
    for names in by_size.values_mut().filter(|names| names.len() > 1) {
        names.sort_by_key(|n| (stable[n].1.modified_ms, n.clone()));
        let mut retained: Vec<String> = Vec::new();
        for name in names.iter() {
            let (path, stamp) = &stable[name];
            let hash = match cached_hash(path, name, *stamp, context) {
                Ok(hash) => hash,
                Err(e) => {
                    snapshot.excluded.push(ExcludedFile {
                        filename: name.clone(),
                        reason: e,
                    });
                    duplicates.insert(name.clone());
                    continue;
                }
            };
            let mut match_name = None;
            for previous in &retained {
                let (prev_path, prev_stamp) = &stable[previous];
                if let Ok(prev_hash) = cached_hash(prev_path, previous, *prev_stamp, context)
                    && hash == prev_hash
                    && byte_equal(path, prev_path).unwrap_or(false)
                {
                    match_name = Some(previous.clone());
                    break;
                }
            }
            if let Some(keeper) = match_name {
                duplicates.insert(name.clone());
                if current_stamp(path) == Some(*stamp)
                    && current_stamp(&stable[&keeper].0) == Some(stable[&keeper].1)
                {
                    match file_is_open(path) {
                        Ok(false) => {}
                        Ok(true) => {
                            snapshot.excluded.push(ExcludedFile {
                                filename: name.clone(),
                                reason: format!(
                                    "Duplicate of {keeper}; waiting for processes to release it"
                                ),
                            });
                            continue;
                        }
                        Err(error) => {
                            snapshot.excluded.push(ExcludedFile {
                                filename: name.clone(),
                                reason: format!(
                                    "Duplicate of {keeper}; cannot verify file is closed: {error}"
                                ),
                            });
                            continue;
                        }
                    }
                    if current_stamp(path) != Some(*stamp) {
                        snapshot.pending.push(name.clone());
                        continue;
                    }
                    match fs::remove_file(path) {
                        Ok(()) => {
                            let action = format!("Deleted exact duplicate {name}; kept {keeper}");
                            context.duplicate_log.push(action.clone());
                            if let Err(error) = append_duplicate_log(folder, &action) {
                                snapshot.excluded.push(ExcludedFile {
                                    filename: name.clone(),
                                    reason: format!(
                                        "Duplicate deleted, but log could not be saved: {error}"
                                    ),
                                });
                            }
                            context.cached.remove(name);
                        }
                        Err(e) => snapshot.excluded.push(ExcludedFile {
                            filename: name.clone(),
                            reason: format!("Duplicate of {keeper}, but deletion failed: {e}"),
                        }),
                    }
                }
            } else {
                retained.push(name.clone());
            }
        }
    }
    for (name, (path, stamp)) in stable {
        if duplicates.contains(&name) {
            continue;
        }
        let media = match context
            .cached
            .get(&name)
            .filter(|cached| cached.stamp == stamp)
            .and_then(|cached| cached.media.clone())
        {
            Some(media) => media,
            None => {
                let media = probe.media_info(&path).map_err(|e| e.to_string());
                let cacheable = media.is_ok().then(|| media.clone());
                context
                    .cached
                    .entry(name.clone())
                    .and_modify(|cached| {
                        if cached.stamp != stamp {
                            cached.hash = None;
                        }
                        cached.stamp = stamp;
                        cached.media = cacheable.clone();
                    })
                    .or_insert(Cached {
                        stamp,
                        media: cacheable,
                        hash: None,
                    });
                media
            }
        };
        match media {
            Ok(info) => {
                let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("");
                let reasons = policy.reject_reasons(extension, &info);
                if !reasons.is_empty() {
                    let reason = reasons.join("; ");
                    if policy.delete_rejected
                        && current_stamp(&path) == Some(stamp)
                        && !folder.join(format!("#work_file#{name}")).exists()
                        && !folder.join(format!("#chkpt_file#{name}")).exists()
                    {
                        match file_is_open(&path) {
                            Ok(true) => {
                                snapshot.excluded.push(ExcludedFile { filename: name.clone(), reason: format!("Rejected ({reason}); waiting for all processes to release the file") });
                                continue;
                            }
                            Err(error) => {
                                snapshot.excluded.push(ExcludedFile {
                                    filename: name.clone(),
                                    reason: format!(
                                        "Rejected ({reason}); cannot verify file is closed: {error}"
                                    ),
                                });
                                continue;
                            }
                            Ok(false) => {}
                        }
                        if current_stamp(&path) != Some(stamp) {
                            snapshot.pending.push(name);
                            continue;
                        }
                        match fs::remove_file(&path) {
                            Ok(()) => {
                                let action = format!("Deleted rejected media {name}: {reason}");
                                context.rejection_log.push(action.clone());
                                if let Err(error) =
                                    append_action_log(folder, ".fillr-rejections.log", &action)
                                {
                                    snapshot.excluded.push(ExcludedFile {
                                        filename: name.clone(),
                                        reason: format!("{action}; logging failed: {error}"),
                                    });
                                }
                                context.cached.remove(&name);
                            }
                            Err(error) => snapshot.excluded.push(ExcludedFile {
                                filename: name.clone(),
                                reason: format!(
                                    "Rejected ({reason}), but deletion failed: {error}"
                                ),
                            }),
                        }
                    } else {
                        snapshot.excluded.push(ExcludedFile {
                            filename: name.clone(),
                            reason,
                        });
                    }
                } else if let Some(duration_ms) = info.duration_ms {
                    snapshot.clips.push(Clip {
                        filename: name,
                        duration_ms,
                        size_bytes: stamp.size,
                        modified_ms: stamp.modified_ms,
                    });
                } else {
                    snapshot.excluded.push(ExcludedFile {
                        filename: name,
                        reason: "No usable video duration".into(),
                    });
                }
            }
            Err(reason) => snapshot.excluded.push(ExcludedFile {
                filename: name,
                reason,
            }),
        }
    }
    snapshot.available_ms = snapshot.clips.iter().map(|c| c.duration_ms).sum();
    snapshot.remaining_ms = settings.total_ms.saturating_sub(snapshot.available_ms);
    snapshot.duplicate_log = context
        .duplicate_log
        .iter()
        .rev()
        .take(100)
        .cloned()
        .collect();
    snapshot.rejection_log = context
        .rejection_log
        .iter()
        .rev()
        .take(100)
        .cloned()
        .collect();
    if snapshot.available_ms < settings.total_ms {
        snapshot.status = Status::Collecting;
        snapshot.message = "Keep downloading CNN footage".into();
    } else {
        snapshot.status = Status::Checking;
        snapshot.message = format!("Checking {}-folder layout…", settings.folder_count);
        let durations: Vec<_> = snapshot
            .clips
            .iter()
            .map(|c| (c.filename.clone(), c.duration_ms))
            .collect();
        snapshot.plan = make_plan_with(&durations, settings);
        if snapshot.plan.is_some() {
            snapshot.status = Status::Ready;
            snapshot.message = "Ready — no more downloads needed".into();
        } else {
            snapshot.message = format!(
                "More usable clips are needed for {} complete folders",
                settings.folder_count
            );
        }
    }
    snapshot
}

fn stamp(metadata: &Metadata) -> Stamp {
    let modified = metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .unwrap_or_default();
    Stamp {
        size: metadata.len(),
        modified_ms: modified.as_millis() as u64,
        modified_ns: modified.as_nanos(),
        #[cfg(unix)]
        identity: ((metadata.dev() as u128) << 64) | metadata.ino() as u128,
        #[cfg(not(unix))]
        identity: metadata
            .created()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_nanos())
            .unwrap_or(0),
    }
}

fn append_duplicate_log(folder: &Path, action: &str) -> std::io::Result<()> {
    append_action_log(folder, ".backgrounder-duplicates.log", action)
}

fn append_action_log(folder: &Path, filename: &str, action: &str) -> std::io::Result<()> {
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(folder.join(filename))?;
    writeln!(file, "{} {action}", chrono::Local::now().to_rfc3339())?;
    file.flush()
}

fn current_stamp(path: &Path) -> Option<Stamp> {
    fs::metadata(path).ok().map(|m| stamp(&m))
}

#[cfg(target_os = "macos")]
fn file_is_open(path: &Path) -> Result<bool, String> {
    let mut child = Command::new("lsof")
        .args(["-nP"])
        .arg(path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    let deadline = Instant::now() + Duration::from_secs(2);
    while child
        .try_wait()
        .map_err(|error| error.to_string())?
        .is_none()
    {
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err("lsof timed out".into());
        }
        thread::sleep(Duration::from_millis(20));
    }
    let output = child
        .wait_with_output()
        .map_err(|error| error.to_string())?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) if output.stderr.is_empty() => Ok(false),
        _ => Err(String::from_utf8_lossy(&output.stderr).trim().to_owned()),
    }
}

#[cfg(not(target_os = "macos"))]
fn file_is_open(_path: &Path) -> Result<bool, String> {
    Ok(false)
}

fn cached_hash(
    path: &Path,
    name: &str,
    stamp: Stamp,
    context: &mut ScanContext,
) -> Result<[u8; 32], String> {
    if let Some(hash) = context
        .cached
        .get(name)
        .filter(|c| c.stamp == stamp)
        .and_then(|c| c.hash)
    {
        return Ok(hash);
    }
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    if current_stamp(path) != Some(stamp) {
        return Err("File changed while hashing".into());
    }
    let hash: [u8; 32] = hasher.finalize().into();
    context
        .cached
        .entry(name.to_owned())
        .and_modify(|c| {
            if c.stamp != stamp {
                c.media = None;
            }
            c.stamp = stamp;
            c.hash = Some(hash);
        })
        .or_insert(Cached {
            stamp,
            media: None,
            hash: Some(hash),
        });
    Ok(hash)
}

fn byte_equal(a: &Path, b: &Path) -> std::io::Result<bool> {
    let mut one = File::open(a)?;
    let mut two = File::open(b)?;
    let mut left = vec![0u8; 1024 * 1024];
    let mut right = vec![0u8; 1024 * 1024];
    loop {
        let n1 = one.read(&mut left)?;
        let n2 = two.read(&mut right)?;
        if n1 != n2 || left[..n1] != right[..n2] {
            return Ok(false);
        }
        if n1 == 0 {
            return Ok(true);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::FileTimes;

    fn age(path: &Path) {
        let old = SystemTime::now() - Duration::from_secs(30);
        File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_times(FileTimes::new().set_modified(old))
            .unwrap();
    }

    fn mark_observed(context: &mut ScanContext, path: &Path) {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        context.seen.insert(
            name,
            (
                stamp(&fs::metadata(path).unwrap()),
                SystemTime::now() - STABLE_FOR - Duration::from_secs(1),
            ),
        );
    }

    #[test]
    fn exact_byte_comparison_distinguishes_files() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a.mpg");
        let b = dir.path().join("b.mpg");
        fs::write(&a, b"abc").unwrap();
        fs::write(&b, b"abc").unwrap();
        assert!(byte_equal(&a, &b).unwrap());
        fs::write(&b, b"abd").unwrap();
        assert!(!byte_equal(&a, &b).unwrap());
    }

    #[test]
    fn deletes_exact_duplicate_but_ignores_work_file() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["a.mpg", "b.mpg", "#WORK-c.mpg"] {
            let path = dir.path().join(name);
            fs::write(&path, b"identical").unwrap();
            age(&path);
        }
        let mut context = ScanContext::default();
        mark_observed(&mut context, &dir.path().join("a.mpg"));
        mark_observed(&mut context, &dir.path().join("b.mpg"));
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new("missing-ffprobe"),
            &MediaPolicy::default(),
            &mut context,
        );
        assert!(dir.path().join("a.mpg").exists());
        assert!(!dir.path().join("b.mpg").exists());
        assert!(dir.path().join("#WORK-c.mpg").exists());
        assert_eq!(snapshot.duplicate_log.len(), 1);
        assert!(
            fs::read_to_string(dir.path().join(".backgrounder-duplicates.log"))
                .unwrap()
                .contains("Deleted exact duplicate b.mpg; kept a.mpg")
        );
    }

    #[test]
    fn recent_and_nested_files_do_not_count() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("new.mpg"), b"in progress").unwrap();
        fs::create_dir(dir.path().join("Chabot News Comps old")).unwrap();
        let nested = dir.path().join("Chabot News Comps old/old.mpg");
        fs::write(&nested, b"old").unwrap();
        age(&nested);
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new("missing-ffprobe"),
            &MediaPolicy::default(),
            &mut ScanContext::default(),
        );
        assert_eq!(snapshot.pending, ["new.mpg"]);
        assert!(snapshot.clips.is_empty());
        assert!(snapshot.excluded.is_empty());
    }

    #[test]
    fn unreadable_video_is_excluded() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bad.mpg");
        fs::write(&path, b"invalid").unwrap();
        age(&path);
        let mut context = ScanContext::default();
        mark_observed(&mut context, &path);
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new("missing-ffprobe"),
            &MediaPolicy::default(),
            &mut context,
        );
        assert_eq!(snapshot.excluded.len(), 1);
        assert_eq!(snapshot.available_ms, 0);
    }

    #[cfg(unix)]
    #[test]
    fn deletes_only_settled_final_rejected_media() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let fake_probe = dir.path().join("ffprobe-mock");
        fs::write(&fake_probe, "#!/bin/sh\nprintf '%s\\n' '{\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"mpeg2video\",\"width\":1920,\"height\":1080,\"sample_aspect_ratio\":\"1:1\",\"display_aspect_ratio\":\"16:9\",\"field_order\":\"tt\",\"avg_frame_rate\":\"30000/1001\"}],\"format\":{\"format_name\":\"mpeg\",\"duration\":\"20.0\"}}'\n").unwrap();
        fs::set_permissions(&fake_probe, fs::Permissions::from_mode(0o755)).unwrap();
        let good = dir.path().join("good.mpg");
        let bad = dir.path().join("bad.mp4");
        let active = dir.path().join("active.mp4");
        for (path, contents) in [
            (&good, b"good".as_slice()),
            (&bad, b"bad invalid".as_slice()),
            (&active, b"active".as_slice()),
        ] {
            fs::write(path, contents).unwrap();
            age(path);
        }
        fs::write(
            dir.path().join("#work_file#active.mp4"),
            b"still downloading",
        )
        .unwrap();
        let mut context = ScanContext::default();
        for path in [&good, &bad, &active] {
            mark_observed(&mut context, path);
        }
        #[cfg(target_os = "macos")]
        let held_open = File::open(&bad).unwrap();
        #[cfg(target_os = "macos")]
        {
            let first = scan_once(
                dir.path(),
                &VideoProbe::new(&fake_probe),
                &MediaPolicy::default(),
                &mut context,
            );
            assert!(bad.exists());
            assert!(first.rejection_log.is_empty());
            drop(held_open);
        }
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new(&fake_probe),
            &MediaPolicy::default(),
            &mut context,
        );
        assert_eq!(snapshot.clips.len(), 1);
        assert_eq!(snapshot.clips[0].filename, "good.mpg");
        assert!(!bad.exists());
        assert!(active.exists());
        assert_eq!(snapshot.pending, ["active.mp4"]);
        assert_eq!(snapshot.rejection_log.len(), 1);
        assert!(
            fs::read_to_string(dir.path().join(".fillr-rejections.log"))
                .unwrap()
                .contains("bad.mp4")
        );
    }
}
