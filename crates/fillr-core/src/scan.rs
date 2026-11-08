use crate::allocation::{Plan, make_plan_with};
use crate::download::{DownloadObservation, DownloadProgress, DownloadTracker, download_name};
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
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
#[cfg(windows)]
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const STABLE_FOR: Duration = Duration::from_secs(10);
const MAX_ACTION_LOG_ENTRIES: usize = 100;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileOpenStatus {
    Open,
    Closed,
    Unknown,
}

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
    #[serde(default)]
    pub downloads: Vec<DownloadProgress>,
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
            downloads: vec![],
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
    downloads: DownloadTracker,
    seen: HashMap<String, (Stamp, SystemTime)>,
    cached: HashMap<String, Cached>,
    duplicate_log: Vec<String>,
    rejection_log: Vec<String>,
    last_plan: Option<Plan>,
}

pub struct Engine {
    folder: PathBuf,
    probe: VideoProbe,
    policy: Arc<Mutex<MediaPolicy>>,
    settings: Arc<Mutex<SortSettings>>,
    snapshot: Arc<Mutex<(Snapshot, Arc<String>)>>,
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
        let initial_snapshot = Snapshot::empty(&folder, &settings);
        let initial_json = Arc::new(serde_json::to_string(&initial_snapshot).unwrap_or_default());
        let snapshot = Arc::new(Mutex::new((initial_snapshot, initial_json)));
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
                let json = Arc::new(serde_json::to_string(&next).unwrap_or_default());
                *worker_snapshot.lock().unwrap() = (next, json);
                drop(_guard);
                let interval = if context.downloads.is_active() { 1 } else { 5 };
                let _ = receiver.recv_timeout(Duration::from_secs(interval));
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

    fn set_snapshot_status(&self, status: Status) {
        let mut snap = self.snapshot.lock().unwrap();
        snap.0.status = status;
        snap.1 = Arc::new(serde_json::to_string(&snap.0).unwrap_or_default());
    }

    pub fn snapshot(&self) -> Snapshot {
        self.snapshot.lock().unwrap().0.clone()
    }

    pub fn snapshot_json(&self) -> Arc<String> {
        self.snapshot.lock().unwrap().1.clone()
    }

    pub fn refresh(&self) {
        let _ = self.wake.send(());
    }

    pub fn set_policy(&self, policy: MediaPolicy) -> Result<(), EngineError> {
        policy.validate().map_err(EngineError)?;
        let _guard = self.gate.lock().unwrap();
        *self.policy.lock().unwrap() = policy;
        self.set_snapshot_status(Status::Checking);
        self.refresh();
        Ok(())
    }

    pub fn set_settings(&self, settings: SortSettings) -> Result<(), EngineError> {
        settings.validate().map_err(EngineError)?;
        let _guard = self.gate.lock().unwrap();
        *self.settings.lock().unwrap() = settings;
        self.set_snapshot_status(Status::Checking);
        self.refresh();
        Ok(())
    }

    pub fn set_configuration(
        &self,
        policy: MediaPolicy,
        settings: SortSettings,
    ) -> Result<(), EngineError> {
        policy.validate().map_err(EngineError)?;
        settings.validate().map_err(EngineError)?;
        let _guard = self.gate.lock().unwrap();
        *self.policy.lock().unwrap() = policy;
        *self.settings.lock().unwrap() = settings;
        self.set_snapshot_status(Status::Checking);
        self.refresh();
        Ok(())
    }

    pub fn build(&self) -> Result<BuildResult, EngineError> {
        let _guard = self.gate.lock().unwrap();
        let current = self.snapshot();
        if current.status != Status::Ready {
            return Err(EngineError("A verified folder layout is not ready".into()));
        }
        let plan = current
            .plan
            .as_ref()
            .ok_or_else(|| EngineError("A verified folder layout is not ready".into()))?;
        self.set_snapshot_status(Status::Building);
        let result = (|| {
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
                .chain(current.pending.iter().cloned())
                .collect();
            build_export_filtered_with(
                &self.folder,
                &self.probe,
                &current.clips,
                plan,
                &excluded,
                !policy.enabled,
                &settings,
            )
            .map_err(|e| EngineError(e.to_string()))
        })();
        self.set_snapshot_status(Status::Checking);
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

fn strip_companion_prefix(filename: &str) -> Option<String> {
    let lower = filename.to_ascii_lowercase();
    if lower.starts_with("#work_file#") {
        Some(filename["#work_file#".len()..].to_owned())
    } else if lower.starts_with("#chkpt_file#") {
        Some(filename["#chkpt_file#".len()..].to_owned())
    } else {
        None
    }
}

fn has_temporary_companion(folder: &Path, name: &str, known_companions: &HashSet<String>) -> bool {
    if known_companions.contains(name) {
        return true;
    }
    for prefix in &["#work_file#", "#WORK_FILE#", "#chkpt_file#", "#CHKPT_FILE#"] {
        if folder.join(format!("{prefix}{name}")).exists() {
            return true;
        }
    }
    // A downloader can create a mixed-case marker after the initial scan.
    // Refresh the directory before deleting, and defer if it cannot be read.
    let Ok(entries) = fs::read_dir(folder) else {
        return true;
    };
    for entry in entries {
        let Ok(entry) = entry else {
            return true;
        };
        if strip_companion_prefix(&entry.file_name().to_string_lossy()).as_deref() == Some(name) {
            return true;
        }
    }
    false
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
    let mut entries_list = Vec::new();
    let mut scan_incomplete = false;
    for entry_res in entries {
        match entry_res {
            Ok(e) => entries_list.push(e),
            Err(e) => {
                scan_incomplete = true;
                snapshot.excluded.push(ExcludedFile {
                    filename: "(unreadable-directory-entry)".into(),
                    reason: format!("Directory entry read failure: {e}"),
                });
            }
        }
    }
    let now = SystemTime::now();
    let mut stable: BTreeMap<String, (PathBuf, Stamp)> = BTreeMap::new();
    let mut present = HashSet::new();
    let temporary_companions: HashSet<String> = entries_list
        .iter()
        .filter_map(|entry| strip_companion_prefix(&entry.file_name().to_string_lossy()))
        .collect();
    // Measure temporary and final media paths independently of media eligibility.
    // No file content is read, and this never changes the settling/deletion rules.
    let observed_at = Instant::now();
    let mut download_samples: BTreeMap<String, DownloadObservation> = BTreeMap::new();
    let mut download_scan_complete = !scan_incomplete;
    for entry in &entries_list {
        let source_name = entry.file_name().to_string_lossy().into_owned();
        let Some((filename, temporary)) = download_name(&source_name) else {
            continue;
        };
        let Ok(kind) = entry.file_type() else {
            download_scan_complete = false;
            continue;
        };
        if !kind.is_file() {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            download_scan_complete = false;
            continue;
        };
        let stamp = stamp(&metadata);
        let sample = DownloadObservation {
            filename: filename.clone(),
            size_bytes: stamp.size,
            identity: stamp.identity,
            temporary: temporary || temporary_companions.contains(&filename),
        };
        // A new temporary transfer may coexist with an older final file. Watch
        // the temporary bytes, regardless of directory enumeration order.
        if temporary || !download_samples.contains_key(&filename) {
            download_samples.insert(filename, sample);
        }
    }
    snapshot.downloads = context.downloads.sample(
        download_samples,
        observed_at,
        STABLE_FOR,
        download_scan_complete,
    );
    for entry in entries_list {
        let path = entry.path();
        let filename = entry.file_name().to_string_lossy().into_owned();
        let upper = filename.to_ascii_uppercase();
        if upper.starts_with("#WORK") || upper.starts_with("#CHKPT") {
            continue;
        }
        if filename.starts_with('.')
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
        let mut retained_by_hash: HashMap<[u8; 32], Vec<String>> = HashMap::new();
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
            for previous in retained_by_hash.get(&hash).into_iter().flatten() {
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
                if scan_incomplete {
                    snapshot.excluded.push(ExcludedFile {
                        filename: name.clone(),
                        reason: format!(
                            "Duplicate of {keeper}; scan incomplete due to directory errors; deletion deferred"
                        ),
                    });
                    continue;
                }
                if has_temporary_companion(folder, name, &temporary_companions)
                    || has_temporary_companion(folder, &keeper, &temporary_companions)
                {
                    snapshot.pending.push(name.clone());
                    continue;
                }
                if current_stamp(path) == Some(*stamp)
                    && current_stamp(&stable[&keeper].0) == Some(stable[&keeper].1)
                {
                    match file_is_open(path) {
                        Ok(FileOpenStatus::Closed) => {}
                        Ok(FileOpenStatus::Open) => {
                            snapshot.excluded.push(ExcludedFile {
                                filename: name.clone(),
                                reason: format!(
                                    "Duplicate of {keeper}; waiting for processes to release it"
                                ),
                            });
                            continue;
                        }
                        Ok(FileOpenStatus::Unknown) | Err(_) => {
                            snapshot.excluded.push(ExcludedFile {
                                filename: name.clone(),
                                reason: format!(
                                    "Duplicate of {keeper}; cannot verify file is closed; deferring deletion"
                                ),
                            });
                            continue;
                        }
                    }
                    if current_stamp(path) != Some(*stamp)
                        || current_stamp(&stable[&keeper].0) != Some(stable[&keeper].1)
                        || has_temporary_companion(folder, name, &temporary_companions)
                        || has_temporary_companion(folder, &keeper, &temporary_companions)
                    {
                        snapshot.pending.push(name.clone());
                        continue;
                    }
                    match fs::remove_file(path) {
                        Ok(()) => {
                            let action = format!("Deleted exact duplicate {name}; kept {keeper}");
                            push_action_log(&mut context.duplicate_log, action.clone());
                            if let Err(error) = append_duplicate_log(folder, &action) {
                                snapshot.excluded.push(ExcludedFile {
                                    filename: name.clone(),
                                    reason: format!(
                                        "Duplicate deleted, but log could not be saved: {error}"
                                    ),
                                });
                            }
                            context.cached.remove(name);
                            context.seen.remove(name);
                        }
                        Err(e) => snapshot.excluded.push(ExcludedFile {
                            filename: name.clone(),
                            reason: format!("Duplicate of {keeper}, but deletion failed: {e}"),
                        }),
                    }
                }
            } else {
                retained_by_hash.entry(hash).or_default().push(name.clone());
            }
        }
    }

    let to_probe: Vec<(String, PathBuf, Stamp)> = stable
        .iter()
        .filter(|(name, (_, stamp))| {
            !duplicates.contains(*name)
                && context
                    .cached
                    .get(*name)
                    .filter(|cached| cached.stamp == *stamp)
                    .and_then(|cached| cached.media.as_ref())
                    .is_none()
        })
        .map(|(name, (path, stamp))| ((*name).clone(), (*path).clone(), *stamp))
        .collect();

    // Failures are retried on later scans, but must not be probed twice while
    // assembling this scan's snapshot after the parallel pass.
    let mut parallel_failures = HashMap::new();
    if to_probe.len() > 1 {
        let parallelism = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4)
            .min(to_probe.len());
        let chunk_size = to_probe.len().div_ceil(parallelism);
        let probed_results: Vec<(String, Stamp, Result<crate::probe::MediaInfo, String>)> =
            std::thread::scope(|s| {
                let mut handles = Vec::new();
                for chunk in to_probe.chunks(chunk_size) {
                    handles.push(s.spawn(move || {
                        let mut results = Vec::with_capacity(chunk.len());
                        for (name, path, stamp) in chunk {
                            let media = probe.media_info(path).map_err(|e| e.to_string());
                            results.push((name.clone(), *stamp, media));
                        }
                        results
                    }));
                }
                handles
                    .into_iter()
                    .flat_map(|h| h.join().unwrap())
                    .collect()
            });

        for (name, stamp, media) in probed_results {
            if let Err(reason) = &media {
                parallel_failures.insert(name.clone(), reason.clone());
            }
            let cacheable = media.is_ok().then(|| media.clone());
            context
                .cached
                .entry(name)
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
            .or_else(|| parallel_failures.remove(&name).map(Err))
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
                    if policy.delete_rejected {
                        if scan_incomplete {
                            snapshot.excluded.push(ExcludedFile {
                                filename: name.clone(),
                                reason: format!(
                                    "Rejected ({reason}); scan incomplete due to directory errors; deletion deferred"
                                ),
                            });
                            continue;
                        }
                        if has_temporary_companion(folder, &name, &temporary_companions) {
                            snapshot.pending.push(name);
                            continue;
                        }
                        if current_stamp(&path) != Some(stamp) {
                            snapshot.pending.push(name);
                            continue;
                        }
                        match file_is_open(&path) {
                            Ok(FileOpenStatus::Closed) => {}
                            Ok(FileOpenStatus::Open) => {
                                snapshot.excluded.push(ExcludedFile {
                                    filename: name.clone(),
                                    reason: format!(
                                        "Rejected ({reason}); waiting for all processes to release the file"
                                    ),
                                });
                                continue;
                            }
                            Ok(FileOpenStatus::Unknown) | Err(_) => {
                                snapshot.excluded.push(ExcludedFile {
                                    filename: name.clone(),
                                    reason: format!(
                                        "Rejected ({reason}); cannot verify file is closed; deferring deletion"
                                    ),
                                });
                                continue;
                            }
                        }
                        if current_stamp(&path) != Some(stamp)
                            || has_temporary_companion(folder, &name, &temporary_companions)
                        {
                            snapshot.pending.push(name);
                            continue;
                        }
                        match fs::remove_file(&path) {
                            Ok(()) => {
                                let action = format!("Deleted rejected media {name}: {reason}");
                                push_action_log(&mut context.rejection_log, action.clone());
                                if let Err(error) =
                                    append_action_log(folder, ".fillr-rejections.log", &action)
                                {
                                    snapshot.excluded.push(ExcludedFile {
                                        filename: name.clone(),
                                        reason: format!("{action}; logging failed: {error}"),
                                    });
                                }
                                context.cached.remove(&name);
                                context.seen.remove(&name);
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
    let mut available_ms: u64 = 0;
    let mut sum_overflow = false;
    for c in &snapshot.clips {
        match available_ms.checked_add(c.duration_ms) {
            Some(sum) => available_ms = sum,
            None => {
                sum_overflow = true;
                break;
            }
        }
    }
    if sum_overflow {
        snapshot.status = Status::Error;
        snapshot.message = "Total clip duration exceeded integer limits".into();
        return snapshot;
    }
    snapshot.available_ms = available_ms;
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
    if scan_incomplete {
        snapshot.status = Status::Checking;
        snapshot.message =
            "Folder scan incomplete due to filesystem errors; destructive actions deferred".into();
    } else if snapshot.available_ms < settings.total_ms {
        snapshot.status = Status::Collecting;
        snapshot.message = "Keep downloading CNN footage".into();
        context.last_plan = None;
    } else {
        snapshot.status = Status::Checking;
        snapshot.message = format!("Checking {}-folder layout…", settings.folder_count);
        let durations: Vec<_> = snapshot
            .clips
            .iter()
            .map(|c| (c.filename.clone(), c.duration_ms))
            .collect();
        if let Some(existing_plan) = context
            .last_plan
            .as_ref()
            .filter(|p| p.validate_with(&durations, settings))
        {
            snapshot.plan = Some(existing_plan.clone());
        } else {
            snapshot.plan = make_plan_with(&durations, settings);
            context.last_plan = snapshot.plan.clone();
        }
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

fn push_action_log(log: &mut Vec<String>, action: String) {
    if log.len() >= MAX_ACTION_LOG_ENTRIES {
        let excess = log.len() - MAX_ACTION_LOG_ENTRIES + 1;
        log.drain(0..excess);
    }
    log.push(action);
}

fn sanitize_log_message(msg: &str) -> String {
    let mut s = String::with_capacity(msg.len());
    for c in msg.chars() {
        match c {
            '\n' => s.push_str("\\n"),
            '\r' => s.push_str("\\r"),
            '\t' => s.push_str("\\t"),
            c if c.is_control() => {
                use std::fmt::Write;
                let _ = write!(s, "\\u{{{:04x}}}", c as u32);
            }
            c => s.push(c),
        }
    }
    s
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
    let log_path = folder.join(filename);
    let mut options = OpenOptions::new();
    options.create(true).append(true);

    #[cfg(unix)]
    {
        // O_NOFOLLOW: prevent symlink following (fails with ELOOP)
        // O_CLOEXEC: close on exec
        // O_NONBLOCK: fail immediately on FIFO/named pipes (returns ENXIO) without hanging
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }

    let mut file = options.open(&log_path)?;
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Action log destination is not a regular file",
        ));
    }

    #[cfg(unix)]
    {
        if meta.nlink() > 1 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "Action log target has multiple hard links",
            ));
        }
        let file_uid = meta.uid();
        let proc_uid = unsafe { libc::geteuid() };
        if file_uid != proc_uid && file_uid != 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "Action log file is not owned by the current user",
            ));
        }
    }

    #[cfg(windows)]
    {
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x00000400;
        if (meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "Action log target is a reparse point or link",
            ));
        }
    }

    let clean_action = sanitize_log_message(action);
    writeln!(file, "{} {clean_action}", chrono::Local::now().to_rfc3339())?;
    file.flush()
}

fn current_stamp(path: &Path) -> Option<Stamp> {
    fs::metadata(path).ok().map(|m| stamp(&m))
}

#[cfg(unix)]
fn run_open_check_command(
    program: &str,
    args: &[&str],
    path: &Path,
) -> Result<FileOpenStatus, String> {
    let mut child = Command::new(program)
        .args(args)
        .arg(path)
        // Only the exit code and presence of diagnostics are needed. Discard
        // stdout so a verbose descriptor listing can never fill a pipe.
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    let mut stderr = child.stderr.take().ok_or("Failed to capture stderr")?;
    // A child or descendant may hold stderr open after the command exits.
    // Nonblocking reads keep both that case and the timeout bounded, without
    // reader threads that could remain blocked waiting for EOF.
    let flags = unsafe { libc::fcntl(stderr.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(stderr.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        let error = std::io::Error::last_os_error();
        let _ = child.kill();
        let _ = child.wait();
        return Err(error.to_string());
    }
    let mut diagnostics = false;
    let mut buffer = [0; 4096];
    let deadline = Instant::now() + Duration::from_secs(2);
    let status = loop {
        // Limit each drain to 64 KiB so an endless producer cannot prevent the
        // deadline check. Continue discarding diagnostics on subsequent polls.
        for _ in 0..16 {
            match stderr.read(&mut buffer) {
                Ok(0) => break,
                Ok(_) => diagnostics = true,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(error.to_string());
                }
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Ok(FileOpenStatus::Unknown);
            }
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e.to_string());
            }
        }
    };
    // Diagnostics may have arrived between the last drain and process exit.
    // One byte is enough to distinguish a clean "no open files" result.
    match stderr.read(&mut buffer[..1]) {
        Ok(0) => {}
        Ok(_) => diagnostics = true,
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
        Err(_) => return Ok(FileOpenStatus::Unknown),
    }
    match status.code() {
        Some(0) => Ok(FileOpenStatus::Open),
        Some(1) if !diagnostics => Ok(FileOpenStatus::Closed),
        _ => Ok(FileOpenStatus::Unknown),
    }
}

#[cfg(target_os = "macos")]
fn file_is_open(path: &Path) -> Result<FileOpenStatus, String> {
    run_open_check_command("lsof", &["-nP"], path)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn file_is_open(path: &Path) -> Result<FileOpenStatus, String> {
    if let Ok(status) = run_open_check_command("lsof", &["-nP"], path)
        && status != FileOpenStatus::Unknown
    {
        return Ok(status);
    }
    if let Ok(status) = run_open_check_command("fuser", &[], path)
        && status != FileOpenStatus::Unknown
    {
        return Ok(status);
    }
    Ok(FileOpenStatus::Unknown)
}

#[cfg(windows)]
fn file_is_open(path: &Path) -> Result<FileOpenStatus, String> {
    match OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(0)
        .open(path)
    {
        Ok(_) => Ok(FileOpenStatus::Closed),
        Err(err) => {
            if let Some(code) = err.raw_os_error() {
                if code == 32 || code == 33 {
                    return Ok(FileOpenStatus::Open);
                }
            }
            Ok(FileOpenStatus::Unknown)
        }
    }
}

#[cfg(not(any(unix, windows)))]
fn file_is_open(_path: &Path) -> Result<FileOpenStatus, String> {
    Ok(FileOpenStatus::Unknown)
}

const HASH_BUFFER_SIZE: usize = 128 * 1024;

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
    let mut buffer = Box::new([0u8; HASH_BUFFER_SIZE]);
    loop {
        match file.read(&mut buffer[..]) {
            Ok(0) => break,
            Ok(count) => hasher.update(&buffer[..count]),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.to_string()),
        }
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

fn fill_buffer(reader: &mut impl Read, mut buf: &mut [u8]) -> std::io::Result<usize> {
    let mut total = 0;
    while !buf.is_empty() {
        match reader.read(buf) {
            Ok(0) => break,
            Ok(n) => {
                total += n;
                buf = &mut buf[n..];
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(total)
}

fn byte_equal(a: &Path, b: &Path) -> std::io::Result<bool> {
    let mut one = File::open(a)?;
    let mut two = File::open(b)?;
    let mut left = Box::new([0u8; HASH_BUFFER_SIZE]);
    let mut right = Box::new([0u8; HASH_BUFFER_SIZE]);
    loop {
        let n1 = fill_buffer(&mut one, &mut left[..])?;
        let n2 = fill_buffer(&mut two, &mut right[..])?;
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
    fn fill_buffer_retries_short_and_interrupted_reads() {
        struct Fragmented<'a> {
            remaining: &'a [u8],
            interrupt_next: bool,
        }
        impl Read for Fragmented<'_> {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                if self.interrupt_next {
                    self.interrupt_next = false;
                    return Err(std::io::ErrorKind::Interrupted.into());
                }
                self.interrupt_next = true;
                let limit = buffer.len().min(2);
                self.remaining.read(&mut buffer[..limit])
            }
        }
        let mut reader = Fragmented {
            remaining: b"abcdefgh",
            interrupt_next: true,
        };
        let mut buffer = [0; 6];
        assert_eq!(fill_buffer(&mut reader, &mut buffer).unwrap(), 6);
        assert_eq!(&buffer, b"abcdef");
        assert_eq!(fill_buffer(&mut reader, &mut buffer).unwrap(), 2);
        assert_eq!(&buffer[..2], b"gh");
        assert_eq!(fill_buffer(&mut reader, &mut buffer).unwrap(), 0);
    }

    #[test]
    fn fill_buffer_propagates_read_failures() {
        struct FailingReader;
        impl Read for FailingReader {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                Err(std::io::ErrorKind::PermissionDenied.into())
            }
        }
        let mut reader = std::io::Cursor::new(b"prefix").chain(FailingReader);
        let mut buffer = [0; 16];
        let error = fill_buffer(&mut reader, &mut buffer).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        assert_eq!(&buffer[..6], b"prefix");
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

    #[cfg(unix)]
    #[test]
    fn open_check_handles_output_larger_than_pipe_capacity() {
        let path = Path::new("unused.mpg");
        assert_eq!(
            run_open_check_command(
                "/bin/sh",
                &["-c", "head -c 1048576 /dev/zero; exit 0"],
                path,
            )
            .unwrap(),
            FileOpenStatus::Open
        );
        assert_eq!(
            run_open_check_command(
                "/bin/sh",
                &["-c", "head -c 1048576 /dev/zero >&2; exit 1"],
                path,
            )
            .unwrap(),
            FileOpenStatus::Unknown
        );
    }

    #[cfg(unix)]
    #[test]
    fn open_check_does_not_wait_for_descendant_pipe_eof() {
        let start = Instant::now();
        assert_eq!(
            run_open_check_command(
                "/bin/sh",
                &["-c", "sleep 4 & exit 1"],
                Path::new("unused.mpg"),
            )
            .unwrap(),
            FileOpenStatus::Closed
        );
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[cfg(unix)]
    #[test]
    fn open_check_times_out_without_reporting_closed() {
        let start = Instant::now();
        assert_eq!(
            run_open_check_command("/bin/sh", &["-c", "exec sleep 10"], Path::new("unused.mpg"),)
                .unwrap(),
            FileOpenStatus::Unknown
        );
        assert!(start.elapsed() < Duration::from_secs(5));
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
    fn equal_size_distinct_files_are_not_duplicates() {
        let dir = tempfile::tempdir().unwrap();
        let mut context = ScanContext::default();
        for (name, content) in [("a.mpg", b"aaa"), ("b.mpg", b"bbb"), ("c.mpg", b"ccc")] {
            let path = dir.path().join(name);
            fs::write(&path, content).unwrap();
            age(&path);
            mark_observed(&mut context, &path);
        }
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new("missing-ffprobe"),
            &MediaPolicy::default(),
            &mut context,
        );
        assert!(snapshot.duplicate_log.is_empty());
        for name in ["a.mpg", "b.mpg", "c.mpg"] {
            assert!(dir.path().join(name).is_file());
        }
    }

    #[test]
    fn digest_collision_still_requires_bytes_and_keeps_first_equal_file() {
        let dir = tempfile::tempdir().unwrap();
        let mut context = ScanContext::default();
        let old = SystemTime::now() - Duration::from_secs(30);
        for (name, content) in [("a.mpg", b"aaa"), ("b.mpg", b"bbb"), ("c.mpg", b"bbb")] {
            let path = dir.path().join(name);
            fs::write(&path, content).unwrap();
            File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_times(FileTimes::new().set_modified(old))
                .unwrap();
            mark_observed(&mut context, &path);
            // Simulate a digest collision: distinct bytes must coexist in the
            // bucket, and the later exact duplicate must match its actual keeper.
            context.cached.insert(
                name.into(),
                Cached {
                    stamp: stamp(&fs::metadata(&path).unwrap()),
                    media: None,
                    hash: Some([42; 32]),
                },
            );
        }
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new("missing-ffprobe"),
            &MediaPolicy::default(),
            &mut context,
        );
        assert!(dir.path().join("a.mpg").is_file());
        assert!(dir.path().join("b.mpg").is_file());
        assert!(!dir.path().join("c.mpg").exists());
        assert_eq!(
            snapshot.duplicate_log,
            ["Deleted exact duplicate c.mpg; kept b.mpg"]
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
    fn speed_watches_work_bytes_and_preserves_the_average_after_rename() {
        let dir = tempfile::tempdir().unwrap();
        let work = dir.path().join("#work_file#clip.mpg");
        let final_path = dir.path().join("clip.mpg");
        let checkpoint = dir.path().join("#chkpt_file#clip.mpg");
        fs::write(&work, [0; 1_000]).unwrap();
        fs::write(&checkpoint, [0; 1_064]).unwrap();
        // An old final path must not take priority over an active work file.
        fs::write(&final_path, [0; 100]).unwrap();
        let mut context = ScanContext::default();
        context.downloads.sample(
            BTreeMap::from([(
                "clip.mpg".into(),
                DownloadObservation {
                    filename: "clip.mpg".into(),
                    size_bytes: 1_000,
                    identity: stamp(&fs::metadata(&work).unwrap()).identity,
                    temporary: true,
                },
            )]),
            Instant::now() - Duration::from_secs(2),
            STABLE_FOR,
            true,
        );
        fs::write(&work, [0; 5_000]).unwrap();
        let probe = VideoProbe::new("missing-ffprobe");
        let growing = scan_once(dir.path(), &probe, &MediaPolicy::default(), &mut context);
        assert_eq!(growing.downloads.len(), 1);
        assert_eq!(growing.downloads[0].observed_bytes, 4_000);
        assert_eq!(growing.downloads[0].size_bytes, 5_000);
        assert!(!growing.downloads[0].completed);
        assert!(growing.clips.is_empty());
        assert_eq!(growing.pending, ["clip.mpg"]);
        fs::remove_file(&final_path).unwrap();
        fs::rename(&work, &final_path).unwrap();
        fs::remove_file(&checkpoint).unwrap();
        let finished = scan_once(dir.path(), &probe, &MediaPolicy::default(), &mut context);
        assert_eq!(finished.downloads[0].observed_bytes, 4_000);
        assert!(finished.downloads[0].completed);
        assert!(finished.clips.is_empty());
        assert_eq!(finished.pending, ["clip.mpg"]);
        let json = serde_json::to_value(&finished).unwrap();
        assert_eq!(json["downloads"][0]["filename"], "clip.mpg");
        assert!(
            json["downloads"][0]["average_bytes_per_second"]
                .as_f64()
                .unwrap()
                > 0.0
        );
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
    fn failed_parallel_probes_run_once_per_scan_then_retry_and_cache_recovery() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let fake_probe = dir.path().join("ffprobe-mock");
        fs::write(&fake_probe, r#"#!/bin/sh
probe_dir=${0%/*}
for input do :; done
printf '%s\n' "${input##*/}" >> "$probe_dir/probe-calls"
if [ -f "$probe_dir/probe-fails" ]; then
    printf '%s\n' 'transient probe failure' >&2
    exit 1
fi
duration=20.0
if [ "${input##*/}" = a.mpg ] && [ -f "$probe_dir/replaced" ]; then
    duration=35.0
fi
printf '{"streams":[{"codec_type":"video","codec_name":"mpeg2video","width":1920,"height":1080,"sample_aspect_ratio":"1:1","display_aspect_ratio":"16:9","field_order":"tt","avg_frame_rate":"30000/1001"}],"format":{"format_name":"mpeg","duration":"%s"}}\n' "$duration"
"#).unwrap();
        fs::set_permissions(&fake_probe, fs::Permissions::from_mode(0o755)).unwrap();
        let failing = dir.path().join("probe-fails");
        fs::write(&failing, b"unavailable").unwrap();
        let a = dir.path().join("a.mpg");
        let b = dir.path().join("b.mpg");
        // Distinct lengths bypass duplicate detection and require two uncached probes.
        fs::write(&a, b"aaa").unwrap();
        fs::write(&b, b"bbbb").unwrap();
        let mut context = ScanContext::default();
        for path in [&a, &b] {
            age(path);
            mark_observed(&mut context, path);
        }
        let probe = VideoProbe::new(&fake_probe);
        let calls = || fs::read_to_string(dir.path().join("probe-calls")).unwrap();
        let first = scan_once(dir.path(), &probe, &MediaPolicy::default(), &mut context);
        assert!(first.clips.is_empty());
        assert_eq!(first.excluded.len(), 2);
        assert!(
            first
                .excluded
                .iter()
                .all(|entry| entry.reason == "transient probe failure")
        );
        assert_eq!(calls().lines().filter(|name| *name == "a.mpg").count(), 1);
        assert_eq!(calls().lines().filter(|name| *name == "b.mpg").count(), 1);
        assert!(context.cached.values().all(|cached| cached.media.is_none()));

        // A recovered tool must be retried even though the media stamps did not change.
        fs::remove_file(failing).unwrap();
        let recovered = scan_once(dir.path(), &probe, &MediaPolicy::default(), &mut context);
        assert_eq!(recovered.clips.len(), 2);
        assert_eq!(recovered.available_ms, 40_000);
        assert_eq!(calls().lines().filter(|name| *name == "a.mpg").count(), 2);
        assert_eq!(calls().lines().filter(|name| *name == "b.mpg").count(), 2);
        let cached = scan_once(dir.path(), &probe, &MediaPolicy::default(), &mut context);
        assert_eq!(cached.available_ms, 40_000);
        assert_eq!(calls().lines().count(), 4);

        // Atomic replacement invalidates only that source's successful cache entry.
        let replacement = dir.path().join("replacement.tmp");
        fs::write(&replacement, b"new source bytes").unwrap();
        age(&replacement);
        fs::rename(&replacement, &a).unwrap();
        mark_observed(&mut context, &a);
        fs::write(dir.path().join("replaced"), b"new duration").unwrap();
        let replaced = scan_once(dir.path(), &probe, &MediaPolicy::default(), &mut context);
        assert_eq!(replaced.clips.len(), 2);
        assert_eq!(replaced.available_ms, 55_000);
        assert_eq!(calls().lines().filter(|name| *name == "a.mpg").count(), 3);
        assert_eq!(calls().lines().filter(|name| *name == "b.mpg").count(), 2);
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

    #[cfg(unix)]
    #[test]
    fn action_log_rejects_symlink_and_preserves_target() {
        use std::os::unix::fs::symlink;
        let outside_dir = tempfile::tempdir().unwrap();
        let sentinel = outside_dir.path().join("sentinel.txt");
        fs::write(&sentinel, b"SENTINEL_DATA").unwrap();

        let watch_dir = tempfile::tempdir().unwrap();
        let symlink_path = watch_dir.path().join(".fillr-rejections.log");
        symlink(&sentinel, &symlink_path).unwrap();

        let res = append_action_log(watch_dir.path(), ".fillr-rejections.log", "malicious write");
        assert!(res.is_err(), "append_action_log should reject symlinks");
        assert_eq!(
            fs::read_to_string(&sentinel).unwrap(),
            "SENTINEL_DATA",
            "Target sentinel file must not be modified"
        );
    }

    #[cfg(unix)]
    #[test]
    fn action_log_rejects_hard_links() {
        let outside_dir = tempfile::tempdir().unwrap();
        let sentinel = outside_dir.path().join("sentinel.txt");
        fs::write(&sentinel, b"SENTINEL_DATA").unwrap();

        let watch_dir = tempfile::tempdir().unwrap();
        let hardlink_path = watch_dir.path().join(".fillr-rejections.log");
        fs::hard_link(&sentinel, &hardlink_path).unwrap();

        let res = append_action_log(watch_dir.path(), ".fillr-rejections.log", "malicious write");
        assert!(
            res.is_err(),
            "append_action_log should reject hard-linked files"
        );
        assert_eq!(
            fs::read_to_string(&sentinel).unwrap(),
            "SENTINEL_DATA",
            "Target sentinel file must not be modified"
        );
    }

    #[cfg(unix)]
    #[test]
    fn action_log_rejects_fifo_without_hanging() {
        use std::ffi::CString;
        let watch_dir = tempfile::tempdir().unwrap();
        let fifo_path = watch_dir.path().join(".fillr-rejections.log");
        let c_path = CString::new(fifo_path.to_str().unwrap()).unwrap();
        unsafe {
            let res = libc::mkfifo(c_path.as_ptr(), 0o600);
            assert_eq!(res, 0, "mkfifo failed");
        }

        let res = append_action_log(watch_dir.path(), ".fillr-rejections.log", "test fifo");
        assert!(
            res.is_err(),
            "append_action_log should reject FIFO/pipe without hanging"
        );
    }

    #[test]
    fn action_log_escapes_control_characters() {
        let watch_dir = tempfile::tempdir().unwrap();
        let action = "Line 1\nLine 2\r\tSpecial";
        append_action_log(watch_dir.path(), "test.log", action).unwrap();

        let content = fs::read_to_string(watch_dir.path().join("test.log")).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(
            lines.len(),
            1,
            "Log entry with newlines must not create multiple lines"
        );
        assert!(lines[0].contains("Line 1\\nLine 2\\r\\tSpecial"));
    }

    #[test]
    fn push_action_log_bounds_memory_to_100_entries() {
        let mut log = Vec::new();
        for i in 0..150 {
            push_action_log(&mut log, format!("action_{i}"));
        }
        assert_eq!(log.len(), 100);
        assert_eq!(log[0], "action_50");
        assert_eq!(log[99], "action_149");
    }

    #[test]
    fn companion_marker_defers_candidate_as_pending() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["a.mpg", "b.mpg"] {
            let path = dir.path().join(name);
            fs::write(&path, b"identical_content").unwrap();
            age(&path);
        }
        // Place a work file for b.mpg
        fs::write(dir.path().join("#work_file#b.mpg"), b"active download").unwrap();

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
        assert!(
            dir.path().join("b.mpg").exists(),
            "Candidate with companion marker must not be deleted"
        );
        assert!(snapshot.pending.contains(&"b.mpg".to_string()));
    }

    #[test]
    fn companion_refresh_defers_deletion_when_directory_cannot_be_read() {
        let dir = tempfile::tempdir().unwrap();
        assert!(has_temporary_companion(
            &dir.path().join("missing-folder"),
            "clip.mpg",
            &HashSet::new(),
        ));
    }

    #[cfg(unix)]
    #[test]
    fn mixed_case_checkpoint_created_during_probe_defers_rejected_deletion() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let fake_probe = dir.path().join("ffprobe-mock");
        fs::write(
            &fake_probe,
            r##"#!/bin/sh
folder=${0%/*}
: > "$folder/#ChKpT_FiLe#bad.mp4"
printf '%s\n' '{"streams":[{"codec_type":"video","codec_name":"mpeg2video","width":1920,"height":1080,"sample_aspect_ratio":"1:1","display_aspect_ratio":"16:9","field_order":"tt","avg_frame_rate":"30000/1001"}],"format":{"format_name":"mpeg","duration":"20.0"}}'
"##,
        )
        .unwrap();
        fs::set_permissions(&fake_probe, fs::Permissions::from_mode(0o755)).unwrap();
        let clip = dir.path().join("bad.mp4");
        fs::write(&clip, b"completed-looking media").unwrap();
        age(&clip);
        let mut context = ScanContext::default();
        mark_observed(&mut context, &clip);

        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new(&fake_probe),
            &MediaPolicy::default(),
            &mut context,
        );
        assert!(dir.path().join("#ChKpT_FiLe#bad.mp4").exists());
        assert!(
            clip.exists(),
            "New transfer checkpoint must protect its media"
        );
        assert_eq!(snapshot.pending, ["bad.mp4"]);
        assert!(snapshot.rejection_log.is_empty());
    }

    #[test]
    fn uppercase_companion_marker_defers_candidate_as_pending() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["a.mpg", "b.mpg"] {
            let path = dir.path().join(name);
            fs::write(&path, b"identical_content").unwrap();
            age(&path);
        }
        // Place uppercase #CHKPT_FILE# for b.mpg
        fs::write(dir.path().join("#CHKPT_FILE#b.mpg"), b"checkpoint").unwrap();

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
        assert!(
            dir.path().join("b.mpg").exists(),
            "Candidate with uppercase #CHKPT_FILE# companion marker must not be deleted"
        );
        assert!(snapshot.pending.contains(&"b.mpg".to_string()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn duplicate_deletion_deferred_when_file_held_open() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["a.mpg", "b.mpg"] {
            let path = dir.path().join(name);
            fs::write(&path, b"identical_content").unwrap();
            age(&path);
        }
        let mut context = ScanContext::default();
        mark_observed(&mut context, &dir.path().join("a.mpg"));
        mark_observed(&mut context, &dir.path().join("b.mpg"));

        let held = File::open(dir.path().join("b.mpg")).unwrap();
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new("missing-ffprobe"),
            &MediaPolicy::default(),
            &mut context,
        );
        drop(held);

        assert!(dir.path().join("a.mpg").exists());
        assert!(
            dir.path().join("b.mpg").exists(),
            "Duplicate held open must not be deleted"
        );
        assert!(
            snapshot
                .excluded
                .iter()
                .any(|ex| ex.filename == "b.mpg" && ex.reason.contains("waiting for processes"))
        );
    }

    #[test]
    fn build_failure_resets_building_status() {
        let dir = tempfile::tempdir().unwrap();
        let clip_path = dir.path().join("clip.mpg");
        fs::write(&clip_path, b"video").unwrap();
        age(&clip_path);
        let engine = Engine::new_with_settings(
            dir.path(),
            "missing-ffprobe",
            MediaPolicy {
                enabled: false,
                ..MediaPolicy::default()
            },
            SortSettings {
                folder_count: 1,
                folder_prefix: "Comp".into(),
                total_ms: 10_000,
            },
        )
        .unwrap();

        // Inject a Ready snapshot whose clip is subsequently missing when build() runs
        engine.snapshot.lock().unwrap().0 = Snapshot {
            api_version: 1,
            folder: dir.path().to_string_lossy().into_owned(),
            status: Status::Ready,
            available_ms: 10_000,
            remaining_ms: 0,
            clips: vec![Clip {
                filename: "deleted_before_build.mpg".into(),
                duration_ms: 10_000,
                size_bytes: 5,
                modified_ms: 1,
            }],
            pending: vec![],
            downloads: vec![],
            excluded: vec![],
            duplicate_log: vec![],
            rejection_log: vec![],
            plan: Some(Plan {
                seed: 1,
                assignments: vec![crate::allocation::Assignment {
                    comp: 1,
                    filenames: vec!["deleted_before_build.mpg".into()],
                    duration_ms: 10_000,
                }],
                selected_duration_ms: 10_000,
            }),
            message: "Ready".into(),
        };

        assert!(engine.build().is_err());
        assert_ne!(
            engine.snapshot().status,
            Status::Building,
            "Failed build() must not leave snapshot stuck at Status::Building"
        );
    }
}
