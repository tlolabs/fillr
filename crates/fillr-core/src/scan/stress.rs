//! End-to-end engine stress checks using disposable synthetic media and a
//! controlled absolute probe executable. Production settling/timeout constants
//! are unchanged; long-running checks exercise the real deadlines.
use super::*;
use std::fs::FileTimes;
use std::os::unix::fs::PermissionsExt;

const TEST_DEADLINE: Duration = Duration::from_secs(30);

fn policy() -> MediaPolicy {
    MediaPolicy {
        enabled: false,
        delete_rejected: false,
        ..MediaPolicy::default()
    }
}

fn settings(total_ms: u64) -> SortSettings {
    SortSettings {
        folder_count: 1,
        folder_prefix: "Comp".into(),
        total_ms,
    }
}

fn mock_probe(control: &Path, mode: &str) -> PathBuf {
    let executable = control.join("ffprobe-stress-mock");
    fs::write(control.join("probe-mode"), mode).unwrap();
    fs::write(
        &executable,
        r##"#!/bin/sh
control=${0%/*}
: > "$control/probe-entered"
mode=$(/bin/cat "$control/probe-mode")
case "$mode" in
    block)
        while [ ! -e "$control/probe-release" ]; do /bin/sleep 0.01; done
        ;;
    timeout)
        exec /bin/sleep 60
        ;;
    failure)
        printf '%s\n' 'synthetic transient probe failure' >&2
        exit 1
        ;;
    incomplete)
        printf '%s\n' '{"streams":[{"codec_type":"video","width":0,"height":0}],"format":{"duration":"20.0"}}'
        exit 0
        ;;
esac
printf '%s\n' '{"streams":[{"codec_type":"video","codec_name":"mpeg2video","width":1920,"height":1080,"sample_aspect_ratio":"1:1","display_aspect_ratio":"16:9","field_order":"tt","avg_frame_rate":"30000/1001"}],"format":{"format_name":"mpeg","duration":"20.0"}}'
"##,
    )
    .unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
    executable
}

fn wait_until(mut condition: impl FnMut() -> bool, description: &str) {
    let start = Instant::now();
    while !condition() {
        assert!(start.elapsed() < TEST_DEADLINE, "Timed out: {description}");
        thread::sleep(Duration::from_millis(5));
    }
}

fn wait_snapshot(engine: &Engine, condition: impl Fn(&Snapshot) -> bool) -> Snapshot {
    let start = Instant::now();
    loop {
        let snapshot = engine.snapshot();
        if condition(&snapshot) {
            return snapshot;
        }
        assert!(
            start.elapsed() < TEST_DEADLINE,
            "Timed out waiting for engine state: {:?}, {}, pending={:?}",
            snapshot.status,
            snapshot.message,
            snapshot.pending
        );
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn real_engine_silent_settling_observes_full_ten_seconds_then_ready() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("media");
    fs::create_dir(&folder).unwrap();
    let probe = mock_probe(root.path(), "valid");
    let started = Instant::now();
    let source = folder.join("clip.mpg");
    fs::write(&source, b"synthetic media; only a temporary fixture").unwrap();
    let modified = source.metadata().unwrap().modified().unwrap();
    let engine = Engine::new_with_settings(&folder, &probe, policy(), settings(1000));
    let engine = engine.unwrap();
    let first = wait_snapshot(&engine, |snapshot| snapshot.pending == ["clip.mpg"]);
    assert!(first.clips.is_empty());
    assert!(first.plan.is_none());
    // No file mutation or refresh follows the first pending observation. Only
    // scheduled reconciliation/settling wakes can make this input eligible.
    let ready = wait_snapshot(&engine, |snapshot| snapshot.status == Status::Ready);
    assert!(
        started.elapsed() >= STABLE_FOR,
        "Ready bypassed real settling"
    );
    let entered = root
        .path()
        .join("probe-entered")
        .metadata()
        .unwrap()
        .modified()
        .unwrap();
    assert!(
        entered.duration_since(modified).unwrap() >= STABLE_FOR,
        "Probe began before media was old enough"
    );
    assert_eq!(ready.clips.len(), 1);
    let durations = vec![("clip.mpg".into(), ready.clips[0].duration_ms)];
    assert!(
        ready
            .plan
            .unwrap()
            .validate_with(&durations, &settings(1000))
    );
    assert_eq!(
        fs::read(&source).unwrap(),
        b"synthetic media; only a temporary fixture"
    );
    println!(
        "REAL_ENGINE_SILENT_SETTLING elapsed_ms={:.3}",
        started.elapsed().as_secs_f64() * 1000.0
    );
}

#[test]
fn real_engine_refresh_configuration_and_idle_shutdown() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("media");
    fs::create_dir(&folder).unwrap();
    let probe = mock_probe(root.path(), "valid");
    let engine = Engine::new_with_settings(&folder, &probe, policy(), settings(1000)).unwrap();
    wait_snapshot(&engine, |snapshot| snapshot.status == Status::Collecting);
    // Refresh must publish a new actual scan instead of leaving an old Error
    // marker visible. The existing snapshot/gate locks safely serialize setup.
    {
        let _gate = engine.gate.lock().unwrap();
        let mut snapshot = engine.snapshot.lock().unwrap();
        snapshot.0.status = Status::Error;
        snapshot.0.message = "test requires a fresh reconciliation".into();
    }
    engine.refresh();
    wait_snapshot(&engine, |snapshot| snapshot.status == Status::Collecting);
    engine.set_configuration(policy(), settings(2000)).unwrap();
    let configured = wait_snapshot(&engine, |snapshot| {
        snapshot.status == Status::Collecting && snapshot.remaining_ms == 2000
    });
    assert_eq!(configured.folder, folder.to_string_lossy());
    assert!(
        !root.path().join("probe-entered").exists(),
        "Empty folder launched a media probe"
    );
    let stopped = Arc::clone(&engine.stop);
    let (done, result) = mpsc::channel();
    thread::spawn(move || {
        drop(engine);
        done.send(()).unwrap();
    });
    result
        .recv_timeout(TEST_DEADLINE)
        .expect("Idle engine did not shut down");
    assert!(stopped.load(Ordering::Acquire));
}

#[test]
fn real_engine_removed_root_recovers_by_polling_after_recreation() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("media");
    fs::create_dir(&folder).unwrap();
    let probe = mock_probe(root.path(), "valid");
    let engine = Engine::new_with_settings(&folder, &probe, policy(), settings(1000)).unwrap();
    wait_snapshot(&engine, |snapshot| snapshot.status == Status::Collecting);
    fs::remove_dir(&folder).unwrap();
    engine.refresh();
    let missing = wait_snapshot(&engine, |snapshot| snapshot.status == Status::Error);
    assert!(
        missing.message.contains("checking periodically"),
        "Missing root did not surface watcher fallback: {}",
        missing.message
    );
    // The removed root's registration has been dropped. Recreating it is not
    // followed by manual refresh; retry/polling must rediscover the new inode.
    fs::create_dir(&folder).unwrap();
    fs::write(folder.join("non-media.txt"), b"temporary sentinel").unwrap();
    let recovered = wait_snapshot(&engine, |snapshot| snapshot.status == Status::Collecting);
    assert!(!recovered.message.contains("Unable to read folder"));
    assert_eq!(
        fs::read(folder.join("non-media.txt")).unwrap(),
        b"temporary sentinel"
    );
    assert!(recovered.clips.is_empty());
}

#[test]
fn real_engine_busy_shutdown_waits_for_cooperative_probe_release() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("media");
    fs::create_dir(&folder).unwrap();
    let probe = mock_probe(root.path(), "block");
    fs::write(folder.join("clip.mpg"), b"synthetic blocked-probe media").unwrap();
    let engine = Engine::new_with_settings(&folder, &probe, policy(), settings(1000)).unwrap();
    wait_until(
        || root.path().join("probe-entered").exists(),
        "Probe did not enter blocking handshake after settling",
    );
    let stopped = Arc::clone(&engine.stop);
    let (done, result) = mpsc::channel();
    let dropper = thread::spawn(move || {
        drop(engine);
        done.send(()).unwrap();
    });
    wait_until(
        || stopped.load(Ordering::Acquire),
        "Drop did not record stop request",
    );
    // Background cancellation may already have killed/reaped the probe. A
    // cooperative release also lets this lifetime test cover implementations
    // that finish the current probe before joining.

    fs::write(root.path().join("probe-release"), b"cooperative release").unwrap();
    result
        .recv_timeout(TEST_DEADLINE)
        .expect("Busy engine did not join after probe release");
    dropper.join().unwrap();
    assert_eq!(
        fs::read(folder.join("clip.mpg")).unwrap(),
        b"synthetic blocked-probe media"
    );
}

#[test]
fn real_probe_timeout_failure_and_recovery_never_authorize_failed_deletion() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("media");
    fs::create_dir(&folder).unwrap();
    let probe = VideoProbe::new(mock_probe(root.path(), "timeout"));
    let source = folder.join("clip.mp4");
    let contents = b"synthetic incomplete/rejected-extension media";
    fs::write(&source, contents).unwrap();
    let old = SystemTime::now() - Duration::from_secs(30);
    File::open(&source)
        .unwrap()
        .set_times(FileTimes::new().set_modified(old))
        .unwrap();
    let mut context = ScanContext::default();
    context.seen.insert(
        "clip.mp4".into(),
        (
            stamp(&source.metadata().unwrap()),
            SystemTime::now() - STABLE_FOR - Duration::from_secs(1),
        ),
    );
    let reject_policy = MediaPolicy::default();
    let started = Instant::now();
    let failed = scan_once_with(
        &folder,
        &probe,
        &reject_policy,
        &settings(1000),
        &mut context,
    );
    assert!(
        started.elapsed() >= Duration::from_secs(15),
        "Real production probe timeout was shortened"
    );
    assert_eq!(failed.excluded.len(), 1);
    assert!(
        failed.excluded[0]
            .reason
            .contains("timed out after 15 seconds")
    );
    assert!(failed.rejection_log.is_empty());
    assert_eq!(fs::read(&source).unwrap(), contents);
    println!(
        "REAL_PROBE_TIMEOUT elapsed_ms={:.3}",
        started.elapsed().as_secs_f64() * 1000.0
    );
    for mode in ["failure", "incomplete"] {
        fs::write(root.path().join("probe-mode"), mode).unwrap();
        let failed = scan_once_with(
            &folder,
            &probe,
            &reject_policy,
            &settings(1000),
            &mut context,
        );
        assert!(failed.clips.is_empty());
        assert_eq!(failed.excluded.len(), 1);
        assert!(failed.rejection_log.is_empty());
        assert_eq!(fs::read(&source).unwrap(), contents);
        assert!(
            context
                .cached
                .get("clip.mp4")
                .is_none_or(|entry| entry.media.is_none())
        );
    }
    fs::write(root.path().join("probe-mode"), "valid").unwrap();
    let allow_policy = MediaPolicy {
        allowed_extensions: vec!["mp4".into()],
        ..MediaPolicy::default()
    };
    let recovered = scan_once_with(
        &folder,
        &probe,
        &allow_policy,
        &settings(1000),
        &mut context,
    );
    assert_eq!(recovered.status, Status::Ready);
    assert_eq!(recovered.clips.len(), 1);
    assert_eq!(recovered.clips[0].duration_ms, 20_000);
    assert!(recovered.rejection_log.is_empty());
    assert_eq!(fs::read(&source).unwrap(), contents);
}
