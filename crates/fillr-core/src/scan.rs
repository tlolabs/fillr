use crate::allocation::{Plan, make_plan_with};
use crate::download::{DownloadObservation, DownloadProgress, DownloadTracker, download_name};
use crate::export::{BuildResult, build_export_with_policy, recover_interrupted_builds};
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
const RECONCILE_INTERVAL: Duration = Duration::from_secs(5);
const DOWNLOAD_SAMPLE_INTERVAL: Duration = Duration::from_secs(1);
const WATCH_RETRY_INTERVAL: Duration = Duration::from_secs(5);

// One pending token represents all changes not yet reconciled. Nonblocking
// sends preserve a follow-up scan without retaining individual event payloads.
fn signal_wake(wake: &mpsc::SyncSender<()>) {
    let _ = wake.try_send(());
}

fn notification_requires_scan(event: &notify::Event) -> bool {
    // inotify reports OPEN for read_dir and for our own media reads. Opening or
    // reading does not change media content. Preserve write-close, all mutation
    // kinds, unknown events, and every explicit rescan request.
    event.need_rescan()
        || !matches!(
            event.kind,
            notify::EventKind::Access(
                notify::event::AccessKind::Open(_)
                    | notify::event::AccessKind::Read
                    | notify::event::AccessKind::Close(notify::event::AccessMode::Read)
            )
        )
}

fn wait_for_work(
    receiver: &mpsc::Receiver<()>,
    deadline: Instant,
) -> Result<(), mpsc::RecvTimeoutError> {
    // Do not drain after receiving: a later event belongs to the following pass.
    receiver.recv_timeout(deadline.saturating_duration_since(Instant::now()))
}

fn settling_delay(
    now: SystemTime,
    observed: SystemTime,
    modified: Option<SystemTime>,
    has_companion: bool,
) -> Option<Duration> {
    if has_companion {
        return None;
    }
    // Unknown/future filesystem times remain subject to periodic reconciliation;
    // they must not create an expired timer that spins the worker.
    let modified_age = now.duration_since(modified?).ok()?;
    let observed_age = now.duration_since(observed).unwrap_or_default();
    let remaining = STABLE_FOR
        .saturating_sub(modified_age)
        .max(STABLE_FOR.saturating_sub(observed_age));
    (!remaining.is_zero()).then_some(remaining)
}

fn next_worker_deadline(
    scanned_at: Instant,
    downloads_active: bool,
    settling: Option<Instant>,
    watcher_retry: Option<Instant>,
) -> Instant {
    let interval = if downloads_active {
        DOWNLOAD_SAMPLE_INTERVAL
    } else {
        RECONCILE_INTERVAL
    };
    let mut deadline = scanned_at + interval;
    if let Some(settling) = settling {
        deadline = deadline.min(settling);
    }
    if let Some(watcher_retry) = watcher_retry {
        deadline = deadline.min(watcher_retry);
    }
    deadline
}

fn folder_identity(folder: &Path) -> Option<u128> {
    fs::metadata(folder)
        .ok()
        .filter(|metadata| metadata.is_dir())
        .map(|metadata| stamp(&metadata).identity)
}

fn notification_warning(reason: &str) -> String {
    let reason: String = reason
        .chars()
        .take(256)
        .map(|ch| if ch.is_control() { ' ' } else { ch })
        .collect();
    format!("Folder notifications unavailable; checking periodically ({reason})")
}

// Registration is worker-owned. Its generic handle allows deterministic failure
// and replacement tests without depending on a particular notify backend.
struct FolderWatch<W> {
    registered: Option<(u128, W)>,
    retry_at: Instant,
    warning: Option<String>,
}

impl<W> FolderWatch<W> {
    fn new(now: Instant) -> Self {
        Self {
            registered: None,
            retry_at: now,
            warning: None,
        }
    }

    fn reconcile<F>(
        &mut self,
        identity: Option<u128>,
        runtime_failed: bool,
        now: Instant,
        register: F,
    ) where
        F: FnOnce() -> Result<(W, Option<u128>), String>,
    {
        if self
            .registered
            .as_ref()
            .is_some_and(|(old, _)| Some(*old) != identity)
            || runtime_failed
        {
            self.registered = None;
            self.warning = Some(notification_warning(if runtime_failed {
                "watcher reported an error"
            } else {
                "watched folder was replaced or removed"
            }));
        }
        if self.registered.is_some() || now < self.retry_at {
            return;
        }
        self.retry_at = now + WATCH_RETRY_INTERVAL;
        let Some(identity) = identity else {
            self.warning = Some(notification_warning("watched folder is unavailable"));
            return;
        };
        match register() {
            Ok((watcher, Some(after))) if identity == after => {
                self.registered = Some((identity, watcher));
                self.warning = None;
            }
            Ok(_) => {
                self.warning = Some(notification_warning("folder changed during registration"));
            }
            Err(error) => self.warning = Some(notification_warning(&error)),
        }
    }

    fn retry_deadline(&self) -> Option<Instant> {
        self.registered.is_none().then_some(self.retry_at)
    }
}

#[cfg(test)]
mod performance;

#[cfg(all(test, unix))]
mod stress;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileOpenStatus {
    Open,
    Closed,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Clip {
    pub filename: String,
    pub duration_ms: u64,
    pub size_bytes: u64,
    pub modified_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
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
    // Unix change time catches in-place edits whose size and mtime are restored.
    // It is only an invalidation hint; destructive operations still revalidate.
    #[cfg(unix)]
    changed_ns: i128,
}

struct Cached {
    stamp: Stamp,
    media: Option<Result<crate::probe::MediaInfo, String>>,
    hash: Option<[u8; 32]>,
}

#[derive(Default)]
struct ScanContext {
    #[cfg(test)]
    metrics: performance::ScanMetrics,
    downloads: DownloadTracker,
    seen: HashMap<String, (Stamp, SystemTime)>,
    cached: HashMap<String, Cached>,
    duplicate_log: Vec<String>,
    rejection_log: Vec<String>,
    last_plan: Option<Plan>,
    next_settling_deadline: Option<Instant>,
    // Direct scans and foreground build probes are uncancelled by default.
    stop: Option<Arc<AtomicBool>>,
}

impl ScanContext {
    fn stopping(&self) -> bool {
        self.stop
            .as_deref()
            .is_some_and(|stop| stop.load(Ordering::Acquire))
    }

    fn probe_media(
        &self,
        probe: &VideoProbe,
        path: &Path,
    ) -> Result<crate::probe::MediaInfo, crate::probe::ProbeError> {
        match self.stop.as_deref() {
            Some(stop) => probe.media_info_cancellable(path, stop),
            None => probe.media_info(path),
        }
    }

    fn compare_files(&self, left: &Path, right: &Path) -> std::io::Result<bool> {
        match self.stop.as_deref() {
            Some(stop) => byte_equal_with_stop(left, right, Some(stop)),
            None => byte_equal(left, right),
        }
    }
}

fn stopped_snapshot(folder: &Path, settings: &SortSettings) -> Snapshot {
    let mut snapshot = Snapshot::empty(folder, settings);
    snapshot.message = "Folder scan stopped".into();
    snapshot
}

// All writers hold the engine gate. Comparing outside serialization keeps FFI
// reads responsive; unchanged state retains its existing JSON allocation.
fn publish_snapshot(shared: &Mutex<(Snapshot, Arc<String>)>, next: Snapshot) -> bool {
    if shared.lock().unwrap().0 == next {
        return false;
    }
    let json = Arc::new(serde_json::to_string(&next).unwrap_or_default());
    *shared.lock().unwrap() = (next, json);
    true
}

pub struct Engine {
    folder: PathBuf,
    probe: VideoProbe,
    policy: Arc<Mutex<MediaPolicy>>,
    settings: Arc<Mutex<SortSettings>>,
    snapshot: Arc<Mutex<(Snapshot, Arc<String>)>>,
    gate: Arc<Mutex<()>>,
    stop: Arc<AtomicBool>,
    wake: mpsc::SyncSender<()>,
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
        let (wake, receiver) = mpsc::sync_channel(1);
        let worker_folder = folder.clone();
        let worker_probe = probe.clone();
        let worker_policy = Arc::clone(&policy);
        let worker_settings = Arc::clone(&settings);
        let worker_snapshot = Arc::clone(&snapshot);
        let worker_gate = Arc::clone(&gate);
        let worker_stop = Arc::clone(&stop);
        let worker_wake = wake.clone();
        let worker = thread::spawn(move || {
            let mut context = ScanContext {
                stop: Some(Arc::clone(&worker_stop)),
                ..ScanContext::default()
            };
            let watcher_failed = Arc::new(AtomicBool::new(false));
            let mut watcher = FolderWatch::new(Instant::now());
            loop {
                if worker_stop.load(Ordering::Acquire) {
                    break;
                }
                let now = Instant::now();
                let identity = folder_identity(&worker_folder);
                watcher.reconcile(
                    identity,
                    watcher_failed.swap(false, Ordering::AcqRel),
                    now,
                    || {
                        let wake = worker_wake.clone();
                        let failed = Arc::clone(&watcher_failed);
                        let mut registered = notify::recommended_watcher(
                            move |event: notify::Result<notify::Event>| match event {
                                Err(_) => {
                                    failed.store(true, Ordering::Release);
                                    signal_wake(&wake);
                                }
                                Ok(event) if notification_requires_scan(&event) => {
                                    signal_wake(&wake);
                                }
                                Ok(_) => {}
                            },
                        )
                        .map_err(|error| error.to_string())?;
                        registered
                            .watch(&worker_folder, RecursiveMode::NonRecursive)
                            .map_err(|error| error.to_string())?;
                        Ok((registered, folder_identity(&worker_folder)))
                    },
                );
                let _guard = worker_gate.lock().unwrap();
                let current_policy = worker_policy.lock().unwrap().clone();
                let current_settings = worker_settings.lock().unwrap().clone();
                let scanned_at = Instant::now();
                let mut next = scan_once_with(
                    &worker_folder,
                    &worker_probe,
                    &current_policy,
                    &current_settings,
                    &mut context,
                );
                if worker_stop.load(Ordering::Acquire) {
                    break;
                }
                if let Some(warning) = &watcher.warning {
                    next.message.push_str(" — ");
                    next.message.push_str(warning);
                }
                publish_snapshot(&worker_snapshot, next);
                drop(_guard);
                let deadline = next_worker_deadline(
                    scanned_at,
                    context.downloads.is_active(),
                    context.next_settling_deadline,
                    watcher.retry_deadline(),
                );
                let _ = wait_for_work(&receiver, deadline);
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
        signal_wake(&self.wake);
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
        let result = {
            let policy = self.policy.lock().unwrap().clone();
            let settings = self.settings.lock().unwrap().clone();
            let excluded: HashSet<String> = current
                .excluded
                .iter()
                .map(|item| item.filename.clone())
                .chain(current.pending.iter().cloned())
                .collect();
            build_export_with_policy(
                &self.folder,
                &self.probe,
                &current.clips,
                plan,
                &excluded,
                &policy,
                &settings,
            )
            .map_err(|e| EngineError(e.to_string()))
        };
        self.set_snapshot_status(Status::Checking);
        self.refresh();
        result
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        signal_wake(&self.wake);
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
    #[cfg(test)]
    {
        context.metrics.directory_scans += 1;
    }
    if context.stopping() {
        return stopped_snapshot(folder, settings);
    }
    context.next_settling_deadline = None;
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
        if context.stopping() {
            return stopped_snapshot(folder, settings);
        }
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
    // Download accounting and eligibility share this reconciliation's metadata.
    // Destructive decisions below still refresh source/companion state.
    let mut entry_metadata: Vec<_> = (0..entries_list.len()).map(|_| None).collect();
    for (entry, metadata_slot) in entries_list.iter().zip(&mut entry_metadata) {
        if context.stopping() {
            return stopped_snapshot(folder, settings);
        }
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
        #[cfg(test)]
        {
            context.metrics.metadata_calls += 1;
        }
        *metadata_slot = Some(entry.metadata());
        let Ok(metadata) = metadata_slot.as_ref().unwrap() else {
            download_scan_complete = false;
            continue;
        };
        let stamp = stamp(metadata);
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
    for (entry, cached_metadata) in entries_list.into_iter().zip(entry_metadata) {
        if context.stopping() {
            return stopped_snapshot(folder, settings);
        }
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
        let metadata = cached_metadata.unwrap_or_else(|| {
            #[cfg(test)]
            {
                context.metrics.metadata_calls += 1;
            }
            entry.metadata()
        });
        let Ok(metadata) = metadata else {
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
            context.cached.remove(&filename);
        }
        let unchanged = now.duration_since(first_seen.1).unwrap_or_default() >= STABLE_FOR;
        let old_enough = metadata
            .modified()
            .ok()
            .and_then(|t| now.duration_since(t).ok())
            .unwrap_or_default()
            >= STABLE_FOR;
        if !old_enough || !unchanged || temporary_companions.contains(&filename) {
            if let Some(delay) = settling_delay(
                now,
                first_seen.1,
                metadata.modified().ok(),
                temporary_companions.contains(&filename),
            ) {
                let deadline = observed_at + delay;
                context.next_settling_deadline = Some(
                    context
                        .next_settling_deadline
                        .map_or(deadline, |existing| existing.min(deadline)),
                );
            }
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
        if context.stopping() {
            return stopped_snapshot(folder, settings);
        }
        names.sort_by_key(|n| (stable[n].1.modified_ms, n.clone()));
        let mut retained_by_hash: HashMap<[u8; 32], Vec<String>> = HashMap::new();
        for name in names.iter() {
            if context.stopping() {
                return stopped_snapshot(folder, settings);
            }
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
                if context.stopping() {
                    return stopped_snapshot(folder, settings);
                }
                let (prev_path, prev_stamp) = &stable[previous];
                if let Ok(prev_hash) = cached_hash(prev_path, previous, *prev_stamp, context)
                    && hash == prev_hash
                    && context.compare_files(path, prev_path).unwrap_or(false)
                {
                    match_name = Some(previous.clone());
                    break;
                }
            }
            if context.stopping() {
                return stopped_snapshot(folder, settings);
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
                    if context.stopping() {
                        return stopped_snapshot(folder, settings);
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

    if context.stopping() {
        return stopped_snapshot(folder, settings);
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
    #[cfg(test)]
    {
        context.metrics.probe_requests += to_probe.len() as u64;
    }

    // Keep parallel results separate from the cache until the source's stamp
    // is checked immediately before using that result. Another probe in the
    // batch may take long enough for an earlier source to change again.
    let mut parallel_results = HashMap::new();
    if to_probe.len() > 1 {
        let parallelism = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4)
            .min(to_probe.len());
        let chunk_size = to_probe.len().div_ceil(parallelism);
        let stop = context.stop.as_deref();
        let probed_results: Vec<(String, Stamp, Result<crate::probe::MediaInfo, String>)> =
            std::thread::scope(|s| {
                let mut handles = Vec::new();
                for chunk in to_probe.chunks(chunk_size) {
                    handles.push(s.spawn(move || {
                        let mut results = Vec::with_capacity(chunk.len());
                        for (name, path, stamp) in chunk {
                            if stop.is_some_and(|flag| flag.load(Ordering::Acquire)) {
                                break;
                            }
                            let media = match stop {
                                Some(stop) => probe.media_info_cancellable(path, stop),
                                None => probe.media_info(path),
                            }
                            .map_err(|e| e.to_string());
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

        if context.stopping() {
            return stopped_snapshot(folder, settings);
        }
        for (name, stamp, media) in probed_results {
            parallel_results.insert(name, (stamp, media));
        }
    }

    for (name, (path, stamp)) in stable {
        if context.stopping() {
            return stopped_snapshot(folder, settings);
        }
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
                let media = parallel_results
                    .remove(&name)
                    .filter(|(probed_stamp, _)| *probed_stamp == stamp)
                    .map(|(_, media)| media)
                    .unwrap_or_else(|| {
                        context.probe_media(probe, &path).map_err(|e| e.to_string())
                    });
                if context.stopping() {
                    return stopped_snapshot(folder, settings);
                }
                if current_stamp(&path) != Some(stamp) {
                    // A successful response may describe the old source. Do
                    // not cache it, count it toward Ready, or evaluate deletion
                    // policy with it. Require a fresh settling observation.
                    context.cached.remove(&name);
                    context.seen.remove(&name);
                    snapshot.pending.push(name);
                    continue;
                }
                // Missing/invalid duration can be transient even when the
                // remaining profile is readable. Retry it on the next scan.
                let cacheable = media
                    .as_ref()
                    .is_ok_and(|info| info.duration_ms.is_some())
                    .then(|| media.clone());
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
        if context.stopping() {
            return stopped_snapshot(folder, settings);
        }
        match media {
            Ok(info) => {
                // A readable profile without usable duration is incomplete
                // for ingest. It must not authorize media-policy deletion.
                let Some(duration_ms) = info.duration_ms else {
                    snapshot.excluded.push(ExcludedFile {
                        filename: name,
                        reason: "No usable video duration".into(),
                    });
                    continue;
                };
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
                        if context.stopping() {
                            return stopped_snapshot(folder, settings);
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
                } else {
                    snapshot.clips.push(Clip {
                        filename: name,
                        duration_ms,
                        size_bytes: stamp.size,
                        modified_ms: stamp.modified_ms,
                    });
                }
            }
            Err(reason) => snapshot.excluded.push(ExcludedFile {
                filename: name,
                reason,
            }),
        }
    }
    if context.stopping() {
        return stopped_snapshot(folder, settings);
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
    if context.stopping() {
        return stopped_snapshot(folder, settings);
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
        changed_ns: i128::from(metadata.ctime()) * 1_000_000_000
            + i128::from(metadata.ctime_nsec()),
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
    if context.stopping() {
        return Err("Folder scan stopped while hashing".into());
    }
    if let Some(hash) = context
        .cached
        .get(name)
        .filter(|c| c.stamp == stamp)
        .and_then(|c| c.hash)
    {
        return Ok(hash);
    }
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    #[cfg(test)]
    {
        context.metrics.hash_operations += 1;
    }
    let mut hasher = Sha256::new();
    let mut buffer = Box::new([0u8; HASH_BUFFER_SIZE]);
    loop {
        if context.stopping() {
            return Err("Folder scan stopped while hashing".into());
        }
        match file.read(&mut buffer[..]) {
            Ok(0) => break,
            Ok(count) => {
                #[cfg(test)]
                {
                    context.metrics.hash_bytes += count as u64;
                }
                hasher.update(&buffer[..count]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.to_string()),
        }
    }
    if context.stopping() {
        return Err("Folder scan stopped while hashing".into());
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

fn fill_buffer(reader: &mut impl Read, buf: &mut [u8]) -> std::io::Result<usize> {
    fill_buffer_with_stop(reader, buf, None)
}

fn fill_buffer_with_stop(
    reader: &mut impl Read,
    mut buf: &mut [u8],
    stop: Option<&AtomicBool>,
) -> std::io::Result<usize> {
    let mut total = 0;
    while !buf.is_empty() {
        if stop.is_some_and(|flag| flag.load(Ordering::Acquire)) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Folder scan stopped while comparing",
            ));
        }
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
    byte_equal_with_stop(a, b, None)
}

fn byte_equal_with_stop(a: &Path, b: &Path, stop: Option<&AtomicBool>) -> std::io::Result<bool> {
    let stopped = || stop.is_some_and(|flag| flag.load(Ordering::Acquire));
    if stopped() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Interrupted,
            "Folder scan stopped while comparing",
        ));
    }
    let mut one = File::open(a)?;
    let mut two = File::open(b)?;
    let mut left = Box::new([0u8; HASH_BUFFER_SIZE]);
    let mut right = Box::new([0u8; HASH_BUFFER_SIZE]);
    loop {
        if stopped() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Folder scan stopped while comparing",
            ));
        }
        let n1 = match stop {
            Some(stop) => fill_buffer_with_stop(&mut one, &mut left[..], Some(stop)),
            None => fill_buffer(&mut one, &mut left[..]),
        }?;
        let n2 = match stop {
            Some(stop) => fill_buffer_with_stop(&mut two, &mut right[..], Some(stop)),
            None => fill_buffer(&mut two, &mut right[..]),
        }?;
        if n1 != n2 || left[..n1] != right[..n2] {
            return Ok(false);
        }
        if stopped() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Folder scan stopped while comparing",
            ));
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

    #[cfg(unix)]
    fn freshness_probe(folder: &Path, hold_name: Option<&str>) -> VideoProbe {
        use std::os::unix::fs::PermissionsExt;
        let executable = folder.join("freshness-ffprobe");
        if let Some(name) = hold_name {
            fs::write(folder.join("hold-name"), format!("{name}\n")).unwrap();
        }
        fs::write(
            &executable,
            r#"#!/bin/sh
probe_dir=${0%/*}
for input do :; done
name=${input##*/}
printf '%s\n' "$name" >> "$probe_dir/probe-calls"
duration=20.0
if [ -f "$probe_dir/new-profile" ]; then duration=35.0; fi
hold_name=
if [ -f "$probe_dir/hold-name" ]; then IFS= read -r hold_name < "$probe_dir/hold-name"; fi
if [ "$name" = "$hold_name" ]; then
    : > "$probe_dir/probe-started"
    while [ ! -f "$probe_dir/release-probe" ]; do sleep 0.01; done
fi
printf '{"streams":[{"codec_type":"video","codec_name":"mpeg2video","width":1920,"height":1080,"sample_aspect_ratio":"1:1","display_aspect_ratio":"16:9","field_order":"tt","avg_frame_rate":"30000/1001"}],"format":{"format_name":"mpeg","duration":"%s"}}\n' "$duration"
if [ "$name" = b.mpg ]; then : > "$probe_dir/b-finished"; fi
"#,
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        VideoProbe::new(executable)
    }

    #[cfg(unix)]
    fn wait_for_probe_signal(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !path.exists() {
            assert!(
                Instant::now() < deadline,
                "Probe signal timed out: {}",
                path.display()
            );
            thread::sleep(Duration::from_millis(1));
        }
    }

    #[cfg(unix)]
    fn replace_preserving_metadata(path: &Path, replacement: bool) {
        let before = fs::metadata(path).unwrap();
        let modified = before.modified().unwrap();
        if replacement {
            let temporary = path.with_extension("replacement");
            fs::write(&temporary, vec![b'z'; before.len() as usize]).unwrap();
            File::options()
                .write(true)
                .open(&temporary)
                .unwrap()
                .set_times(FileTimes::new().set_modified(modified))
                .unwrap();
            fs::rename(temporary, path).unwrap();
        } else {
            fs::write(path, vec![b'z'; before.len() as usize]).unwrap();
            File::options()
                .write(true)
                .open(path)
                .unwrap()
                .set_times(FileTimes::new().set_modified(modified))
                .unwrap();
        }
        let after = fs::metadata(path).unwrap();
        assert_eq!(before.len(), after.len());
        assert_eq!(before.modified().unwrap(), after.modified().unwrap());
        if !replacement {
            assert_eq!(stamp(&before).identity, stamp(&after).identity);
            assert_ne!(
                stamp(&before).changed_ns,
                stamp(&after).changed_ns,
                "This Unix fixture filesystem must expose a changed ctime"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn preserved_mtime_edit_invalidates_media_and_hash_caches() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("a.mpg");
        fs::write(&path, b"aaaa").unwrap();
        age(&path);
        let probe = freshness_probe(directory.path(), None);
        let mut context = ScanContext::default();
        mark_observed(&mut context, &path);
        let old_stamp = current_stamp(&path).unwrap();
        let old_hash = cached_hash(&path, "a.mpg", old_stamp, &mut context).unwrap();
        let first = scan_once(
            directory.path(),
            &probe,
            &MediaPolicy::default(),
            &mut context,
        );
        assert_eq!(first.available_ms, 20_000);
        assert!(context.cached["a.mpg"].media.is_some());
        assert_eq!(context.cached["a.mpg"].hash, Some(old_hash));

        replace_preserving_metadata(&path, false);
        fs::write(
            directory.path().join("new-profile"),
            b"new media information",
        )
        .unwrap();
        let changed = scan_once(
            directory.path(),
            &probe,
            &MediaPolicy::default(),
            &mut context,
        );
        assert!(changed.clips.is_empty());
        assert_eq!(changed.pending, ["a.mpg"]);
        assert!(!context.cached.contains_key("a.mpg"));
        assert_eq!(context.metrics.probe_requests, 1);

        mark_observed(&mut context, &path);
        let new_stamp = current_stamp(&path).unwrap();
        let new_hash = cached_hash(&path, "a.mpg", new_stamp, &mut context).unwrap();
        assert_ne!(old_hash, new_hash);
        let refreshed = scan_once(
            directory.path(),
            &probe,
            &MediaPolicy::default(),
            &mut context,
        );
        assert_eq!(refreshed.available_ms, 35_000);
        assert_eq!(context.cached["a.mpg"].hash, Some(new_hash));
        assert_eq!(context.metrics.probe_requests, 2);
        assert_eq!(context.metrics.hash_operations, 2);
    }

    #[cfg(unix)]
    #[test]
    fn serial_and_parallel_changed_probe_results_stay_pending_and_uncached() {
        for parallel in [false, true] {
            for replacement in [false, true] {
                // Both accepted and policy-rejected extensions must defer on
                // stale success, before caching or authorizing deletion.
                for extension in ["mpg", "mp4"] {
                    let directory = tempfile::tempdir().unwrap();
                    let name = format!("a.{extension}");
                    let path = directory.path().join(&name);
                    fs::write(&path, b"aaa").unwrap();
                    age(&path);
                    let mut context = ScanContext::default();
                    mark_observed(&mut context, &path);
                    if parallel {
                        let other = directory.path().join("b.mpg");
                        fs::write(&other, b"bbbb").unwrap();
                        age(&other);
                        mark_observed(&mut context, &other);
                    }
                    let probe = freshness_probe(directory.path(), Some(&name));
                    let release = directory.path().join("release-probe");
                    struct ReleaseOnDrop(PathBuf);
                    impl Drop for ReleaseOnDrop {
                        fn drop(&mut self) {
                            let _ = fs::write(&self.0, b"release");
                        }
                    }
                    let release_guard = ReleaseOnDrop(release.clone());
                    let snapshot = thread::scope(|scope| {
                        let worker = scope.spawn(|| {
                            scan_once(
                                directory.path(),
                                &probe,
                                &MediaPolicy::default(),
                                &mut context,
                            )
                        });
                        wait_for_probe_signal(&directory.path().join("probe-started"));
                        replace_preserving_metadata(&path, replacement);
                        fs::write(directory.path().join("new-profile"), b"new profile").unwrap();
                        fs::write(&release, b"release").unwrap();
                        worker.join().unwrap()
                    });
                    drop(release_guard);
                    assert!(path.exists());
                    assert!(snapshot.clips.iter().all(|clip| clip.filename != name));
                    assert!(snapshot.pending.contains(&name));
                    assert!(snapshot.rejection_log.is_empty());
                    assert!(!context.cached.contains_key(&name));
                    assert!(!context.seen.contains_key(&name));
                    assert_eq!(context.metrics.probe_requests, if parallel { 2 } else { 1 });

                    // Recovery starts with a fresh settling observation and
                    // fresh probe; a stale batch must not overwrite it.
                    mark_observed(&mut context, &path);
                    let permissive = MediaPolicy {
                        enabled: false,
                        ..MediaPolicy::default()
                    };
                    let recovered = scan_once(directory.path(), &probe, &permissive, &mut context);
                    assert_eq!(
                        recovered
                            .clips
                            .iter()
                            .find(|clip| clip.filename == name)
                            .unwrap()
                            .duration_ms,
                        35_000
                    );
                    let calls = fs::read_to_string(directory.path().join("probe-calls")).unwrap();
                    assert_eq!(calls.lines().filter(|called| *called == name).count(), 2);
                    let cached = scan_once(directory.path(), &probe, &permissive, &mut context);
                    assert!(cached.clips.iter().any(|clip| clip.filename == name));
                    assert_eq!(
                        fs::read_to_string(directory.path().join("probe-calls")).unwrap(),
                        calls
                    );
                }
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn earlier_parallel_result_is_revalidated_after_slow_batch_peer() {
        let directory = tempfile::tempdir().unwrap();
        let a = directory.path().join("a.mpg");
        let b = directory.path().join("b.mpg");
        fs::write(&a, b"aaa").unwrap();
        fs::write(&b, b"bbbb").unwrap();
        let mut context = ScanContext::default();
        for path in [&a, &b] {
            age(path);
            mark_observed(&mut context, path);
        }
        let probe = freshness_probe(directory.path(), Some("a.mpg"));
        let release = directory.path().join("release-probe");
        let snapshot = thread::scope(|scope| {
            let worker = scope.spawn(|| {
                scan_once(
                    directory.path(),
                    &probe,
                    &MediaPolicy::default(),
                    &mut context,
                )
            });
            wait_for_probe_signal(&directory.path().join("probe-started"));
            wait_for_probe_signal(&directory.path().join("b-finished"));
            replace_preserving_metadata(&b, false);
            fs::write(&release, b"release").unwrap();
            worker.join().unwrap()
        });
        assert_eq!(snapshot.clips.len(), 1);
        assert_eq!(snapshot.clips[0].filename, "a.mpg");
        assert_eq!(snapshot.pending, ["b.mpg"]);
        assert!(context.cached.contains_key("a.mpg"));
        assert!(!context.cached.contains_key("b.mpg"));
        assert!(!context.seen.contains_key("b.mpg"));
    }

    #[cfg(unix)]
    #[test]
    fn successful_media_cache_reevaluates_policy_and_evicts_removed_sources() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("a.mpg");
        fs::write(&path, b"aaa").unwrap();
        age(&path);
        let probe = freshness_probe(directory.path(), None);
        let mut context = ScanContext::default();
        mark_observed(&mut context, &path);
        assert_eq!(
            scan_once(
                directory.path(),
                &probe,
                &MediaPolicy::default(),
                &mut context
            )
            .clips
            .len(),
            1
        );
        let rejecting = MediaPolicy {
            allowed_codecs: vec!["h264".into()],
            delete_rejected: false,
            ..MediaPolicy::default()
        };
        let filtered = scan_once(directory.path(), &probe, &rejecting, &mut context);
        assert!(filtered.clips.is_empty());
        assert_eq!(filtered.excluded.len(), 1);
        assert!(path.exists());
        assert_eq!(
            scan_once(
                directory.path(),
                &probe,
                &MediaPolicy::default(),
                &mut context
            )
            .clips
            .len(),
            1
        );
        assert_eq!(context.metrics.probe_requests, 1);
        fs::remove_file(&path).unwrap();
        assert!(
            scan_once(
                directory.path(),
                &probe,
                &MediaPolicy::default(),
                &mut context
            )
            .clips
            .is_empty()
        );
        assert!(context.cached.is_empty());
        assert!(context.seen.is_empty());
    }

    #[test]
    fn unchanged_snapshot_keeps_json_and_progress_transitions_publish() {
        let settings = SortSettings::default();
        let initial = Snapshot::empty(Path::new("/temporary-fixture"), &settings);
        let json = Arc::new(serde_json::to_string(&initial).unwrap());
        let shared = Mutex::new((initial.clone(), json.clone()));
        assert!(!publish_snapshot(&shared, initial.clone()));
        assert!(Arc::ptr_eq(&shared.lock().unwrap().1, &json));
        let mut next = initial;
        next.pending.push("settling.mpg".into());
        assert!(publish_snapshot(&shared, next.clone()));
        next.downloads.push(DownloadProgress {
            filename: "settling.mpg".into(),
            size_bytes: 2000,
            observed_bytes: 1000,
            elapsed_ms: 1000,
            average_bytes_per_second: 1000.0,
            completed: false,
        });
        assert!(publish_snapshot(&shared, next.clone()));
        next.downloads[0].completed = true;
        assert!(publish_snapshot(&shared, next.clone()));
        next.status = Status::Ready;
        next.message = "Ready".into();
        assert!(publish_snapshot(&shared, next.clone()));
        let guard = shared.lock().unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&guard.1).unwrap(),
            serde_json::to_value(&next).unwrap()
        );
        assert!(!Arc::ptr_eq(&guard.1, &json));
    }

    // Insert inside the original scan::tests module. All inputs are temporary or
    // synthetic; this exercises the actual existing C ABI without changing it.
    mod ffi_snapshot_contract {
        use super::*;
        use std::ffi::{CStr, c_char};
        use std::hint::black_box;

        struct OwnedSnapshotString(*mut c_char);

        impl OwnedSnapshotString {
            fn read(engine: &Engine) -> Self {
                // SAFETY: engine remains alive at its current address during the
                // call. fillr_snapshot reads shared, internally synchronized
                // state and returns a new, independently owned C allocation.
                let raw =
                    unsafe { crate::ffi::fillr_snapshot(engine as *const Engine as *mut Engine) };
                assert!(!raw.is_null());
                Self(raw)
            }

            fn bytes(&self) -> &[u8] {
                // SAFETY: this wrapper owns a non-null C string returned by
                // fillr_snapshot; Drop has not run and the allocation is live.
                unsafe { CStr::from_ptr(self.0).to_bytes() }
            }
        }

        impl Drop for OwnedSnapshotString {
            fn drop(&mut self) {
                // SAFETY: each allocation enters one wrapper and is released
                // exactly once by its matching C ABI deallocator.
                unsafe { crate::ffi::fillr_free_string(self.0) };
            }
        }

        fn large_fixture(folder: &Path) -> Snapshot {
            let settings = SortSettings::default();
            let mut snapshot = Snapshot::empty(folder, &settings);
            snapshot.clips = (0..2_000)
                .map(|index| Clip {
                    filename: format!("synthetic-{index:04}.mpg"),
                    duration_ms: crate::allocation::TARGET_MS,
                    size_bytes: 150_000_000,
                    modified_ms: 1_728_000_000_000,
                })
                .collect();
            let durations: Vec<_> = snapshot
                .clips
                .iter()
                .map(|clip| (clip.filename.clone(), clip.duration_ms))
                .collect();
            let plan = make_plan_with(&durations, &settings).unwrap();
            assert!(plan.validate_with(&durations, &settings));
            snapshot.available_ms = snapshot.clips.iter().map(|clip| clip.duration_ms).sum();
            snapshot.remaining_ms = 0;
            snapshot.status = Status::Ready;
            snapshot.plan = Some(plan);
            snapshot.message = "Synthetic 2,000-clip ABI fixture".into();
            snapshot
        }

        fn transfer_bytes(engine: &Engine) -> Vec<u8> {
            // Model native callers that copy the owned C result before freeing
            // it. The returned Vec owns all bytes independently of the engine.
            let owned = OwnedSnapshotString::read(engine);
            owned.bytes().to_vec()
        }

        #[test]
        fn ffi_snapshot_strings_survive_other_frees_publication_and_engine_drop() {
            let directory = tempfile::tempdir().unwrap();
            let engine =
                Engine::new(directory.path(), directory.path().join("unused-probe")).unwrap();
            // Freeze only this test's temporary engine. Its worker cannot
            // overwrite the synthetic fixture while ABI ownership is exercised.
            let gate = engine.gate.lock().unwrap();
            let fixture = large_fixture(directory.path());
            let original_bytes = serde_json::to_vec(&fixture).unwrap();
            publish_snapshot(&engine.snapshot, fixture.clone());

            let first = OwnedSnapshotString::read(&engine);
            let surviving = OwnedSnapshotString::read(&engine);
            assert_ne!(first.0, surviving.0);
            assert_eq!(first.bytes(), original_bytes);
            assert_eq!(surviving.bytes(), original_bytes);
            drop(first);

            let mut changed = fixture;
            changed.status = Status::Checking;
            changed.plan = None;
            changed.message = "Updated publication — independent C strings".into();
            publish_snapshot(&engine.snapshot, changed.clone());
            let latest = OwnedSnapshotString::read(&engine);
            let decoded_latest: Snapshot = serde_json::from_slice(latest.bytes()).unwrap();
            assert_eq!(decoded_latest, changed);
            assert_eq!(surviving.bytes(), original_bytes);
            drop(latest);
            assert_eq!(surviving.bytes(), original_bytes);

            drop(gate);
            drop(engine);
            let decoded_survivor: Snapshot = serde_json::from_slice(surviving.bytes()).unwrap();
            assert_eq!(decoded_survivor.clips.len(), 2_000);
            assert_eq!(decoded_survivor.status, Status::Ready);
            assert_eq!(decoded_survivor.message, "Synthetic 2,000-clip ABI fixture");
            // surviving is freed through fillr_free_string even after its engine
            // has been destroyed, as required by owned-result ABI semantics.
        }

        fn timing_summary(raw_ms: &[f64]) -> serde_json::Value {
            let mut sorted = raw_ms.to_vec();
            sorted.sort_by(f64::total_cmp);
            let count = sorted.len();
            let median = if count.is_multiple_of(2) {
                (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
            } else {
                sorted[count / 2]
            };
            let mean = sorted.iter().sum::<f64>() / count as f64;
            let stddev = (sorted
                .iter()
                .map(|sample| (sample - mean).powi(2))
                .sum::<f64>()
                / count as f64)
                .sqrt();
            serde_json::json!({
                "samples": count, "p50_ms": median,
                "p95_ms": sorted[(count * 95).div_ceil(100) - 1],
                "max_ms": sorted[count - 1], "stddev_ms": stddev,
                "raw_ms": raw_ms,
            })
        }

        #[test]
        #[ignore = "opt-in final-stage large-snapshot C ABI and JSON decode measurement"]
        #[allow(clippy::assertions_on_constants)]
        fn ffi_snapshot_transfer_decode_performance_2000() {
            assert!(
                !cfg!(debug_assertions),
                "Run this experiment with --release"
            );
            let directory = tempfile::tempdir().unwrap();
            let engine =
                Engine::new(directory.path(), directory.path().join("unused-probe")).unwrap();
            let _gate = engine.gate.lock().unwrap();
            let fixture = large_fixture(directory.path());
            publish_snapshot(&engine.snapshot, fixture);
            let payload_bytes = engine.snapshot_json().len();
            for _ in 0..10 {
                let bytes = transfer_bytes(&engine);
                let snapshot: Snapshot = serde_json::from_slice(black_box(&bytes)).unwrap();
                assert_eq!(snapshot.clips.len(), 2_000);
                black_box(snapshot);
            }
            let mut transfer_ms = Vec::with_capacity(100);
            let mut decode_ms = Vec::with_capacity(100);
            let mut total_ms = Vec::with_capacity(100);
            for _ in 0..100 {
                let start = Instant::now();
                let bytes = transfer_bytes(&engine);
                transfer_ms.push(start.elapsed().as_secs_f64() * 1_000.0);
                let decode_started = Instant::now();
                let snapshot: Snapshot = serde_json::from_slice(black_box(&bytes)).unwrap();
                decode_ms.push(decode_started.elapsed().as_secs_f64() * 1_000.0);
                total_ms.push(start.elapsed().as_secs_f64() * 1_000.0);
                assert_eq!(snapshot.clips.len(), 2_000);
                assert_eq!(snapshot.status, Status::Ready);
                assert_eq!(bytes.len(), payload_bytes);
                black_box(snapshot);
            }
            println!(
                "FILLR_FFI_PERF {}",
                serde_json::json!({
                    "conditions": "final-stage measurement only; synthetic 2,000-clip valid Ready snapshot; empty temporary Engine; gate held; 10 warmups; 100 samples; release mode; not pre-optimization large-FFI baseline, media throughput, native Swift/Qt decode or UI presentation",
                    "payload_bytes": payload_bytes,
                    "c_abi_transfer_client_copy_and_free": timing_summary(&transfer_ms),
                    "serde_snapshot_decode": timing_summary(&decode_ms),
                    "combined_transfer_and_decode": timing_summary(&total_ms),
                })
            );
        }
    }

    #[test]
    fn cancelled_hash_and_fragmented_byte_comparison_do_not_finish_inspection() {
        let directory = tempfile::tempdir().unwrap();
        let first = directory.path().join("first.mpg");
        let second = directory.path().join("second.mpg");
        fs::write(&first, b"identical source bytes").unwrap();
        fs::write(&second, b"identical source bytes").unwrap();
        let stop = Arc::new(AtomicBool::new(true));
        let mut context = ScanContext {
            stop: Some(Arc::clone(&stop)),
            ..ScanContext::default()
        };
        let source_stamp = current_stamp(&first).unwrap();
        assert!(cached_hash(&first, "first.mpg", source_stamp, &mut context).is_err());
        assert_eq!(context.metrics.hash_operations, 0);
        assert!(context.cached.is_empty());
        assert_eq!(
            byte_equal_with_stop(&first, &second, Some(&stop))
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::Interrupted
        );
        stop.store(false, Ordering::Release);
        assert!(byte_equal(&first, &second).unwrap());

        struct CancelsAfterRead<'a> {
            stop: &'a AtomicBool,
            calls: usize,
        }
        impl Read for CancelsAfterRead<'_> {
            fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
                self.calls += 1;
                output[0] = b'x';
                self.stop.store(true, Ordering::Release);
                Ok(1)
            }
        }
        let mut reader = CancelsAfterRead {
            stop: &stop,
            calls: 0,
        };
        let mut output = [0; 8];
        assert_eq!(
            fill_buffer_with_stop(&mut reader, &mut output, Some(&stop))
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::Interrupted
        );
        assert_eq!(
            reader.calls, 1,
            "Cancellation must be checked between fragmented reads"
        );
        assert_eq!(fs::read(first).unwrap(), fs::read(second).unwrap());
    }

    #[cfg(unix)]
    fn cancellable_batch_fixture(folder: &Path) -> (VideoProbe, Vec<(PathBuf, Vec<u8>)>, usize) {
        use std::os::unix::fs::PermissionsExt;
        let parallelism = thread::available_parallelism()
            .map(|value| value.get())
            .unwrap_or(4);
        let count = parallelism * 2 + 1;
        let mut sources = Vec::new();
        for index in 0..count {
            let path = folder.join(format!("source-{index:04}.mpg"));
            let contents = vec![b'x'; 32 + index];
            fs::write(&path, &contents).unwrap();
            age(&path);
            sources.push((path, contents));
        }
        fs::create_dir(folder.join("started")).unwrap();
        let executable = folder.join("cancellable-batch-probe");
        fs::write(
            &executable,
            r#"#!/bin/sh
probe_dir=${0%/*}
for input do :; done
name=${input##*/}
: > "$probe_dir/started/$$-$name"
exec sleep 30
"#,
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        // Preserve the existing chunk algorithm; this is its actual handle bound.
        let chunk_size = count.div_ceil(parallelism);
        let workers = count.div_ceil(chunk_size);
        (VideoProbe::new(executable), sources, workers)
    }

    #[cfg(unix)]
    fn wait_for_batch_start(folder: &Path, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        loop {
            let started = fs::read_dir(folder.join("started"))
                .unwrap()
                .filter_map(Result::ok)
                .any(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .split_once('-')
                        .and_then(|(pid, _)| pid.parse::<libc::pid_t>().ok())
                        .is_some()
                });
            if started {
                return;
            }
            assert!(Instant::now() < deadline, "Batch probe did not start");
            thread::sleep(Duration::from_millis(1));
        }
    }

    #[cfg(unix)]
    fn assert_cancelled_batch_preserved(
        folder: &Path,
        sources: &[(PathBuf, Vec<u8>)],
        workers: usize,
    ) -> usize {
        let started: Vec<_> = fs::read_dir(folder.join("started"))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert!(!started.is_empty());
        assert!(
            started.len() <= workers,
            "Queued probes launched after stop: {} > {workers}",
            started.len()
        );
        for entry in &started {
            let filename = entry.file_name();
            let filename = filename.to_string_lossy();
            let pid: libc::pid_t = filename.split_once('-').unwrap().0.parse().unwrap();
            // SAFETY: signal0 checks the PID recorded by a temporary mock child;
            // it sends no signal and touches no user-memory pointers.
            let result = unsafe { libc::kill(pid, 0) };
            let error = std::io::Error::last_os_error();
            assert_eq!(result, -1, "Probe child was not reaped: {pid}");
            assert_eq!(error.raw_os_error(), Some(libc::ESRCH));
        }
        for (path, contents) in sources {
            assert_eq!(&fs::read(path).unwrap(), contents);
        }
        assert!(!folder.join(".fillr-rejections.log").exists());
        assert!(!folder.join(".backgrounder-duplicates.log").exists());
        started.len()
    }

    #[cfg(unix)]
    #[test]
    fn cancelled_batch_launches_no_queued_probes_and_caches_no_partial_results() {
        let directory = tempfile::tempdir().unwrap();
        let (probe, sources, workers) = cancellable_batch_fixture(directory.path());
        let stop = Arc::new(AtomicBool::new(false));
        let mut context = ScanContext {
            stop: Some(Arc::clone(&stop)),
            ..ScanContext::default()
        };
        for (source, _) in &sources {
            mark_observed(&mut context, source);
        }
        let (snapshot, elapsed) = thread::scope(|scope| {
            let scan = scope.spawn(|| {
                scan_once(
                    directory.path(),
                    &probe,
                    &MediaPolicy::default(),
                    &mut context,
                )
            });
            wait_for_batch_start(directory.path(), Duration::from_secs(5));
            let at = Instant::now();
            stop.store(true, Ordering::Release);
            (scan.join().unwrap(), at.elapsed())
        });
        assert!(
            elapsed < Duration::from_secs(2),
            "Stopped scan waited {elapsed:?}"
        );
        assert_eq!(snapshot.status, Status::Checking);
        assert_eq!(snapshot.message, "Folder scan stopped");
        assert!(snapshot.clips.is_empty());
        assert!(snapshot.plan.is_none());
        assert!(context.cached.is_empty());
        let launches = assert_cancelled_batch_preserved(directory.path(), &sources, workers);
        println!(
            "FILLR_CANCEL_PERF {}",
            serde_json::json!({
                "mode":"busy_batch_scan_cancel", "elapsed_ms":elapsed.as_secs_f64()*1000.0,
                "probe_launches":launches, "worker_bound":workers, "total_sources":sources.len(),
                "conditions":"actual exec-sleep probe children; after-start cancellation; queued chunk work skipped; source bytes preserved; not real-media throughput",
            })
        );
    }

    #[cfg(unix)]
    #[test]
    fn pre_cancelled_scan_skips_all_probe_and_hash_work() {
        let directory = tempfile::tempdir().unwrap();
        let (probe, sources, _) = cancellable_batch_fixture(directory.path());
        let mut context = ScanContext {
            stop: Some(Arc::new(AtomicBool::new(true))),
            ..ScanContext::default()
        };
        for (source, _) in &sources {
            mark_observed(&mut context, source);
        }
        let snapshot = scan_once(
            directory.path(),
            &probe,
            &MediaPolicy::default(),
            &mut context,
        );
        assert_eq!(snapshot.status, Status::Checking);
        assert_eq!(snapshot.message, "Folder scan stopped");
        assert!(snapshot.clips.is_empty());
        assert!(snapshot.plan.is_none());
        assert!(context.cached.is_empty());
        assert_eq!(context.metrics.probe_requests, 0);
        assert_eq!(context.metrics.hash_operations, 0);
        assert_eq!(
            fs::read_dir(directory.path().join("started"))
                .unwrap()
                .count(),
            0
        );
        for (path, contents) in sources {
            assert_eq!(fs::read(path).unwrap(), contents);
        }
    }

    #[cfg(unix)]
    #[test]
    fn engine_drop_cancels_busy_background_batch_after_real_settling_deadline() {
        let directory = tempfile::tempdir().unwrap();
        let (probe, sources, workers) = cancellable_batch_fixture(directory.path());
        // This uses the real worker and original10s stability rule. The script
        // path is private in VideoProbe, so use the known temporary executable.
        drop(probe);
        let engine = Engine::new_with_policy(
            directory.path(),
            directory.path().join("cancellable-batch-probe"),
            MediaPolicy {
                enabled: false,
                ..MediaPolicy::default()
            },
        )
        .unwrap();
        wait_for_batch_start(directory.path(), Duration::from_secs(20));
        let at = Instant::now();
        drop(engine);
        let elapsed = at.elapsed();
        assert!(
            elapsed < Duration::from_secs(2),
            "Busy Engine::drop waited {elapsed:?}"
        );
        let launches = assert_cancelled_batch_preserved(directory.path(), &sources, workers);
        println!(
            "FILLR_CANCEL_PERF {}",
            serde_json::json!({
                "mode":"busy_engine_drop", "elapsed_ms":elapsed.as_secs_f64()*1000.0,
                "probe_launches":launches, "worker_bound":workers, "total_sources":sources.len(),
                "conditions":"real background worker after real10s settling; actual exec-sleep mock probes; Drop stop wiring; no media bytes changed",
            })
        );
    }

    #[cfg(unix)]
    fn duration_profile_probe(folder: &Path, duration: Option<&str>) -> VideoProbe {
        use std::os::unix::fs::PermissionsExt;
        write_duration_profile(folder, duration);
        let executable = folder.join("ffprobe-duration-profile");
        fs::write(
            &executable,
            r#"#!/bin/sh
probe_dir=${0%/*}
for input do :; done
printf '%s\n' "${input##*/}" >> "$probe_dir/probe-calls"
/bin/cat "$probe_dir/profile.json"
"#,
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        VideoProbe::new(executable)
    }

    #[cfg(unix)]
    fn write_duration_profile(folder: &Path, duration: Option<&str>) {
        let mut profile = serde_json::json!({
            "streams":[{"codec_type":"video","codec_name":"mpeg2video","width":1920,"height":1080,
                "sample_aspect_ratio":"1:1","display_aspect_ratio":"16:9","field_order":"tt","avg_frame_rate":"30000/1001"}],
            "format":{"format_name":"mpeg"},
        });
        if let Some(duration) = duration {
            profile["streams"][0]["duration"] = duration.into();
            profile["format"]["duration"] = duration.into();
        }
        fs::write(
            folder.join("profile.json"),
            serde_json::to_vec(&profile).unwrap(),
        )
        .unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn missing_duration_blocks_policy_deletion_and_remains_uncached() {
        for duration in [None, Some("N/A")] {
            let directory = tempfile::tempdir().unwrap();
            let probe = duration_profile_probe(directory.path(), duration);
            let path = directory.path().join("incomplete.mp4");
            let contents = b"temporary source must survive incomplete duration";
            fs::write(&path, contents).unwrap();
            age(&path);
            let mut context = ScanContext::default();
            mark_observed(&mut context, &path);
            for expected_requests in 1..=2 {
                let snapshot = scan_once(
                    directory.path(),
                    &probe,
                    &MediaPolicy::default(),
                    &mut context,
                );
                assert_eq!(fs::read(&path).unwrap(), contents);
                assert!(snapshot.clips.is_empty());
                assert!(snapshot.plan.is_none());
                assert_ne!(snapshot.status, Status::Ready);
                assert!(snapshot.rejection_log.is_empty());
                assert_eq!(snapshot.excluded.len(), 1);
                assert_eq!(snapshot.excluded[0].reason, "No usable video duration");
                assert!(context.cached.values().all(|cached| cached.media.is_none()));
                assert_eq!(context.metrics.probe_requests, expected_requests);
            }
            assert!(!directory.path().join(".fillr-rejections.log").exists());
            assert_eq!(
                fs::read_to_string(directory.path().join("probe-calls"))
                    .unwrap()
                    .lines()
                    .count(),
                2
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn missing_duration_retries_unchanged_sources_and_caches_healthy_recovery() {
        for count in [1, 2] {
            let directory = tempfile::tempdir().unwrap();
            let probe = duration_profile_probe(directory.path(), Some("N/A"));
            let mut context = ScanContext::default();
            let mut before = Vec::new();
            for index in 0..count {
                let path = directory.path().join(format!("source-{index}.mpg"));
                fs::write(&path, vec![b'x'; 32 + index]).unwrap();
                age(&path);
                mark_observed(&mut context, &path);
                before.push((path.clone(), current_stamp(&path).unwrap()));
            }
            let incomplete = scan_once(
                directory.path(),
                &probe,
                &MediaPolicy::default(),
                &mut context,
            );
            assert!(incomplete.clips.is_empty());
            assert_eq!(incomplete.excluded.len(), count);
            assert!(context.cached.values().all(|cached| cached.media.is_none()));
            write_duration_profile(directory.path(), Some("20.0"));
            for (path, expected) in &before {
                assert!(current_stamp(path) == Some(*expected));
            }
            let recovered = scan_once(
                directory.path(),
                &probe,
                &MediaPolicy::default(),
                &mut context,
            );
            assert_eq!(recovered.clips.len(), count);
            assert_eq!(recovered.available_ms, count as u64 * 20_000);
            assert!(recovered.excluded.is_empty());
            assert_eq!(context.metrics.probe_requests, count as u64 * 2);
            assert!(context.cached.values().all(|cached| matches!(&cached.media,
                Some(Ok(info)) if info.duration_ms == Some(20_000))));
            let calls = fs::read_to_string(directory.path().join("probe-calls")).unwrap();
            let warm = scan_once(
                directory.path(),
                &probe,
                &MediaPolicy::default(),
                &mut context,
            );
            assert_eq!(warm.clips.len(), count);
            assert_eq!(context.metrics.probe_requests, count as u64 * 2);
            assert_eq!(
                fs::read_to_string(directory.path().join("probe-calls")).unwrap(),
                calls
            );
        }
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

#[cfg(test)]
mod scheduler_tests {
    use super::*;
    use std::sync::Barrier;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn notification_filter_keeps_mutations_write_close_and_unknown_events() {
        use notify::EventKind;
        use notify::event::{AccessKind, AccessMode, CreateKind, ModifyKind, RemoveKind};
        for kind in [
            EventKind::Access(AccessKind::Read),
            EventKind::Access(AccessKind::Open(AccessMode::Any)),
            EventKind::Access(AccessKind::Open(AccessMode::Read)),
            EventKind::Access(AccessKind::Open(AccessMode::Write)),
            EventKind::Access(AccessKind::Close(AccessMode::Read)),
        ] {
            assert!(!notification_requires_scan(&notify::Event::new(kind)));
        }
        for kind in [
            EventKind::Any,
            EventKind::Other,
            EventKind::Access(AccessKind::Any),
            EventKind::Access(AccessKind::Other),
            EventKind::Access(AccessKind::Close(AccessMode::Write)),
            EventKind::Create(CreateKind::Any),
            EventKind::Modify(ModifyKind::Any),
            EventKind::Remove(RemoveKind::Any),
        ] {
            assert!(notification_requires_scan(&notify::Event::new(kind)));
        }
    }

    #[test]
    fn rescan_request_overrides_ignored_access_kind() {
        let event = notify::Event::new(notify::EventKind::Access(notify::event::AccessKind::Open(
            notify::event::AccessMode::Any,
        )))
        .set_flag(notify::event::Flag::Rescan);
        assert!(notification_requires_scan(&event));
    }

    #[test]
    fn wake_storm_retains_one_nonblocking_follow_up() {
        let (wake, receiver) = mpsc::sync_channel(1);
        for _ in 0..100_000 {
            signal_wake(&wake);
        }
        assert!(wait_for_work(&receiver, Instant::now()).is_ok());
        assert_eq!(receiver.try_recv(), Err(mpsc::TryRecvError::Empty));
        signal_wake(&wake);
        assert!(wait_for_work(&receiver, Instant::now()).is_ok());
    }

    #[test]
    fn change_during_scan_survives_until_follow_up() {
        let (wake, receiver) = mpsc::sync_channel(1);
        let entered = Arc::new(Barrier::new(2));
        let leave = Arc::new(Barrier::new(2));
        let worker_entered = Arc::clone(&entered);
        let worker_leave = Arc::clone(&leave);
        let worker = thread::spawn(move || {
            worker_entered.wait();
            // Represents processing which may span many notification callbacks.
            worker_leave.wait();
            wait_for_work(&receiver, Instant::now())
        });
        entered.wait();
        for _ in 0..10_000 {
            signal_wake(&wake);
        }
        leave.wait();
        assert!(worker.join().unwrap().is_ok());
    }

    #[test]
    fn final_change_before_wait_is_not_drained_away() {
        let (wake, receiver) = mpsc::sync_channel(1);
        let before_wait = Arc::new(Barrier::new(2));
        let continue_to_wait = Arc::new(Barrier::new(2));
        let worker_before = Arc::clone(&before_wait);
        let worker_continue = Arc::clone(&continue_to_wait);
        let worker = thread::spawn(move || {
            worker_before.wait();
            worker_continue.wait();
            wait_for_work(&receiver, Instant::now())
        });
        before_wait.wait();
        signal_wake(&wake);
        continue_to_wait.wait();
        assert!(worker.join().unwrap().is_ok());
    }

    #[test]
    fn continuous_events_allow_processing_and_stop_wake() {
        let (wake, receiver) = mpsc::sync_channel(1);
        let stop = Arc::new(AtomicBool::new(false));
        let producer_stop = Arc::clone(&stop);
        let producer_wake = wake.clone();
        let producer = thread::spawn(move || {
            while !producer_stop.load(Ordering::Acquire) {
                signal_wake(&producer_wake);
            }
        });
        for _ in 0..100 {
            assert!(wait_for_work(&receiver, Instant::now() + Duration::from_secs(5)).is_ok());
        }
        stop.store(true, Ordering::Release);
        signal_wake(&wake);
        producer.join().unwrap();
        assert!(wait_for_work(&receiver, Instant::now()).is_ok());
        assert!(stop.load(Ordering::Acquire));
    }

    #[test]
    fn settling_deadline_requires_both_observation_and_mtime() {
        let now = UNIX_EPOCH + Duration::from_secs(1000);
        let old = now - Duration::from_secs(30);
        assert_eq!(settling_delay(now, now, Some(old), false), Some(STABLE_FOR));
        assert_eq!(
            settling_delay(now, now - Duration::from_millis(9750), Some(old), false),
            Some(Duration::from_millis(250))
        );
        assert_eq!(
            settling_delay(now, old, Some(now - Duration::from_secs(2)), false),
            Some(Duration::from_secs(8))
        );
        assert_eq!(settling_delay(now, old, Some(old), false), None);
        assert_eq!(settling_delay(now, old, Some(old), true), None);
        assert_eq!(settling_delay(now, old, None, false), None);
        assert_eq!(
            settling_delay(now, old, Some(now + STABLE_FOR), false),
            None
        );
    }

    #[test]
    fn deadlines_include_sampling_settling_and_retry_without_adding_scan_time() {
        let start = Instant::now();
        assert_eq!(
            next_worker_deadline(start, false, None, None),
            start + RECONCILE_INTERVAL
        );
        assert_eq!(
            next_worker_deadline(start, true, None, None),
            start + DOWNLOAD_SAMPLE_INTERVAL
        );
        let settling = start + Duration::from_millis(250);
        assert_eq!(
            next_worker_deadline(start, false, Some(settling), None),
            settling
        );
        let retry = start + Duration::from_millis(125);
        assert_eq!(
            next_worker_deadline(start, true, Some(settling), Some(retry)),
            retry
        );
        let after_slow_scan = start + Duration::from_secs(20);
        assert_eq!(
            settling.saturating_duration_since(after_slow_scan),
            Duration::ZERO
        );
    }

    #[test]
    fn watcher_failure_is_visible_and_retry_is_independent_of_events() {
        let start = Instant::now();
        let mut state: FolderWatch<()> = FolderWatch::new(start);
        let mut attempts = 0;
        state.reconcile(Some(1), false, start, || {
            attempts += 1;
            Err("synthetic unsupported volume".into())
        });
        assert_eq!(attempts, 1);
        assert!(
            state
                .warning
                .as_ref()
                .unwrap()
                .contains("checking periodically")
        );
        assert_eq!(state.retry_deadline(), Some(start + WATCH_RETRY_INTERVAL));
        for offset in 1..500 {
            state.reconcile(
                Some(1),
                false,
                start + Duration::from_millis(offset),
                || panic!("events must not bypass retry backoff"),
            );
        }
        state.reconcile(Some(1), false, start + WATCH_RETRY_INTERVAL, || {
            attempts += 1;
            Ok(((), Some(1)))
        });
        assert_eq!(attempts, 2);
        assert!(state.warning.is_none());
        assert!(state.retry_deadline().is_none());
    }

    #[test]
    fn runtime_error_drops_registration_and_recovers_with_backoff() {
        struct Handle(Arc<AtomicUsize>);
        impl Drop for Handle {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::Relaxed);
            }
        }
        let drops = Arc::new(AtomicUsize::new(0));
        let start = Instant::now();
        let mut state = FolderWatch::new(start);
        state.reconcile(Some(1), false, start, || {
            Ok((Handle(Arc::clone(&drops)), Some(1)))
        });
        state.reconcile(Some(1), true, start + Duration::from_secs(1), || {
            panic!("runtime errors must retain retry backoff")
        });
        assert_eq!(drops.load(Ordering::Relaxed), 1);
        assert!(state.registered.is_none());
        assert!(
            state
                .warning
                .as_ref()
                .unwrap()
                .contains("watcher reported an error")
        );
        state.reconcile(Some(1), false, start + WATCH_RETRY_INTERVAL, || {
            Ok((Handle(Arc::clone(&drops)), Some(1)))
        });
        assert!(state.registered.is_some());
        assert!(state.warning.is_none());
    }

    #[test]
    fn missing_replaced_and_registration_racing_folders_keep_polling() {
        let start = Instant::now();
        let mut state: FolderWatch<()> = FolderWatch::new(start);
        state.reconcile(Some(1), false, start, || Ok(((), Some(1))));
        state.reconcile(None, false, start + Duration::from_secs(1), || {
            panic!("backoff applies to missing folder")
        });
        assert!(state.registered.is_none());
        assert!(state.warning.is_some());
        state.reconcile(None, false, start + WATCH_RETRY_INTERVAL, || {
            panic!("do not register a missing folder")
        });
        state.reconcile(Some(2), false, start + WATCH_RETRY_INTERVAL * 2, || {
            Ok(((), Some(3)))
        });
        assert!(state.registered.is_none());
        assert!(
            state
                .warning
                .as_ref()
                .unwrap()
                .contains("changed during registration")
        );
        state.reconcile(Some(3), false, start + WATCH_RETRY_INTERVAL * 3, || {
            Ok(((), Some(3)))
        });
        assert!(state.registered.is_some());
        assert!(state.warning.is_none());
    }

    #[test]
    fn warning_storage_is_bounded_and_does_not_create_log_lines() {
        let warning = notification_warning(&"x\n".repeat(10_000));
        assert!(warning.chars().count() < 400);
        assert!(!warning.contains('\n'));
    }

    #[cfg(unix)]
    #[test]
    fn folder_identity_observes_atomic_directory_replacement() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("ingest");
        fs::create_dir(&root).unwrap();
        let initial = folder_identity(&root).unwrap();
        fs::rename(&root, dir.path().join("old-ingest")).unwrap();
        assert_eq!(folder_identity(&root), None);
        fs::create_dir(&root).unwrap();
        assert_ne!(folder_identity(&root), Some(initial));
    }
}
