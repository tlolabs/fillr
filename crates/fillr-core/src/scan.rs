use crate::allocation::{Plan, TARGET_MS, make_plan};
use crate::export::{BuildResult, build_export, recover_interrupted_builds};
use crate::probe::VideoProbe;
use notify::{RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
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
    pub plan: Option<Plan>,
    pub message: String,
}

impl Snapshot {
    fn empty(folder: &Path) -> Self {
        Self {
            api_version: 1,
            folder: folder.to_string_lossy().into_owned(),
            status: Status::Checking,
            available_ms: 0,
            remaining_ms: TARGET_MS * 14,
            clips: vec![],
            pending: vec![],
            excluded: vec![],
            duplicate_log: vec![],
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
}

struct Cached {
    stamp: Stamp,
    duration: Option<Result<u64, String>>,
    hash: Option<[u8; 32]>,
}

#[derive(Default)]
struct ScanContext {
    seen: HashMap<String, (Stamp, SystemTime)>,
    cached: HashMap<String, Cached>,
    duplicate_log: Vec<String>,
}

pub struct Engine {
    folder: PathBuf,
    probe: VideoProbe,
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
        let folder = folder.into();
        if !folder.is_dir() {
            return Err(EngineError("Choose an existing download folder".into()));
        }
        recover_interrupted_builds(&folder).map_err(|e| EngineError(e.to_string()))?;
        let probe = VideoProbe::new(ffprobe);
        let snapshot = Arc::new(Mutex::new(Snapshot::empty(&folder)));
        let gate = Arc::new(Mutex::new(()));
        let stop = Arc::new(AtomicBool::new(false));
        let (wake, receiver) = mpsc::channel();
        let worker_folder = folder.clone();
        let worker_probe = probe.clone();
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
                let next = scan_once(&worker_folder, &worker_probe, &mut context);
                *worker_snapshot.lock().unwrap() = next;
                drop(_guard);
                let _ = receiver.recv_timeout(Duration::from_secs(5));
                while receiver.try_recv().is_ok() {}
            }
        });
        Ok(Self {
            folder,
            probe,
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

    pub fn build(&self) -> Result<BuildResult, EngineError> {
        let _guard = self.gate.lock().unwrap();
        let current = self.snapshot();
        if current.status != Status::Ready {
            return Err(EngineError("A verified 14-Comp layout is not ready".into()));
        }
        let plan = current.plan.as_ref().unwrap();
        self.snapshot.lock().unwrap().status = Status::Building;
        let result = build_export(&self.folder, &self.probe, &current.clips, plan)
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

fn scan_once(folder: &Path, probe: &VideoProbe, context: &mut ScanContext) -> Snapshot {
    let mut snapshot = Snapshot::empty(folder);
    let entries = match fs::read_dir(folder) {
        Ok(e) => e,
        Err(e) => {
            snapshot.status = Status::Error;
            snapshot.message = format!("Unable to read folder: {e}");
            return snapshot;
        }
    };
    let now = SystemTime::now();
    let mut stable: BTreeMap<String, (PathBuf, Stamp)> = BTreeMap::new();
    let mut present = HashSet::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let filename = entry.file_name().to_string_lossy().into_owned();
        if filename.starts_with('.')
            || filename.to_ascii_uppercase().starts_with("#WORK")
            || !entry.file_type().is_ok_and(|kind| kind.is_file())
            || !path
                .extension()
                .is_some_and(|x| x.eq_ignore_ascii_case("mpg"))
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
        if !old_enough
            || (!unchanged
                && context
                    .cached
                    .get(&filename)
                    .is_some_and(|c| c.stamp != stamp))
        {
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
        let duration = match context
            .cached
            .get(&name)
            .filter(|cached| cached.stamp == stamp)
            .and_then(|cached| cached.duration.clone())
        {
            Some(duration) => duration,
            None => {
                let duration = probe.duration_ms(&path).map_err(|e| e.to_string());
                context
                    .cached
                    .entry(name.clone())
                    .and_modify(|cached| {
                        cached.stamp = stamp;
                        cached.duration = Some(duration.clone());
                    })
                    .or_insert(Cached {
                        stamp,
                        duration: Some(duration.clone()),
                        hash: None,
                    });
                duration
            }
        };
        match duration {
            Ok(duration_ms) => snapshot.clips.push(Clip {
                filename: name,
                duration_ms,
                size_bytes: stamp.size,
                modified_ms: stamp.modified_ms,
            }),
            Err(reason) => snapshot.excluded.push(ExcludedFile {
                filename: name,
                reason,
            }),
        }
    }
    snapshot.available_ms = snapshot.clips.iter().map(|c| c.duration_ms).sum();
    snapshot.remaining_ms = (TARGET_MS * 14).saturating_sub(snapshot.available_ms);
    snapshot.duplicate_log = context
        .duplicate_log
        .iter()
        .rev()
        .take(100)
        .cloned()
        .collect();
    if snapshot.available_ms < TARGET_MS * 14 {
        snapshot.status = Status::Collecting;
        snapshot.message = "Keep downloading CNN footage".into();
    } else {
        snapshot.status = Status::Checking;
        snapshot.message = "Checking 14-Comp layout…".into();
        let durations: Vec<_> = snapshot
            .clips
            .iter()
            .map(|c| (c.filename.clone(), c.duration_ms))
            .collect();
        snapshot.plan = make_plan(&durations);
        if snapshot.plan.is_some() {
            snapshot.status = Status::Ready;
            snapshot.message = "Ready — no more downloads needed".into();
        } else {
            snapshot.message = "More usable clips are needed for 14 complete Comps".into();
        }
    }
    snapshot
}

fn stamp(metadata: &Metadata) -> Stamp {
    Stamp {
        size: metadata.len(),
        modified_ms: metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .unwrap_or_default()
            .as_millis() as u64,
    }
}

fn append_duplicate_log(folder: &Path, action: &str) -> std::io::Result<()> {
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(folder.join(".backgrounder-duplicates.log"))?;
    writeln!(file, "{} {action}", chrono::Local::now().to_rfc3339())?;
    file.flush()
}

fn current_stamp(path: &Path) -> Option<Stamp> {
    fs::metadata(path).ok().map(|m| stamp(&m))
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
            c.stamp = stamp;
            c.hash = Some(hash);
        })
        .or_insert(Cached {
            stamp,
            duration: None,
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
        File::open(path)
            .unwrap()
            .set_times(FileTimes::new().set_modified(old))
            .unwrap();
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
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new("missing-ffprobe"),
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
        let snapshot = scan_once(
            dir.path(),
            &VideoProbe::new("missing-ffprobe"),
            &mut ScanContext::default(),
        );
        assert_eq!(snapshot.excluded.len(), 1);
        assert_eq!(snapshot.available_ms, 0);
    }
}
