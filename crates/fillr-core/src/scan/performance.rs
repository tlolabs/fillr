//! Opt-in release measurements. All engine inputs are disposable fixtures.
//! Run with: cargo test -p fillr-core --release --locked performance_baseline
//! -- --ignored --nocapture --test-threads=1
/// Test counters cover reconciliation and entry metadata, not OS syscalls or
/// destructive-operation safety rechecks. Hash bytes exclude FFprobe I/O.
#[derive(Clone, Copy, Debug, Default, serde::Serialize)]
pub(super) struct ScanMetrics {
    pub(super) directory_scans: u64,
    pub(super) metadata_calls: u64,
    pub(super) probe_requests: u64,
    pub(super) hash_operations: u64,
    pub(super) hash_bytes: u64,
}

#[cfg(unix)]
impl ScanMetrics {
    fn since(self, before: Self) -> Self {
        Self {
            directory_scans: self.directory_scans - before.directory_scans,
            metadata_calls: self.metadata_calls - before.metadata_calls,
            probe_requests: self.probe_requests - before.probe_requests,
            hash_operations: self.hash_operations - before.hash_operations,
            hash_bytes: self.hash_bytes - before.hash_bytes,
        }
    }
}

#[cfg(unix)]
mod experiment {
    use super::super::*;
    use super::ScanMetrics;
    use std::fs::FileTimes;
    use std::os::unix::fs::PermissionsExt;

    #[derive(Default, serde::Serialize)]
    struct Measurements {
        label: String,
        conditions: String,
        raw_ms: Vec<f64>,
        cpu_self_and_reaped_children_ms: Vec<Option<f64>>,
        process_peak_rss_kib: Vec<Option<u64>>,
        operations: Vec<ScanMetrics>,
    }

    impl Measurements {
        fn new(label: String, conditions: &str) -> Self {
            Self {
                label,
                conditions: conditions.into(),
                ..Self::default()
            }
        }

        fn measure<T>(&mut self, f: impl FnOnce() -> T) -> T {
            let before = resources();
            let start = Instant::now();
            let result = f();
            self.raw_ms.push(start.elapsed().as_secs_f64() * 1000.0);
            let after = resources();
            self.cpu_self_and_reaped_children_ms
                .push(before.zip(after).map(|(a, b)| (b.0 - a.0).max(0.0)));
            self.process_peak_rss_kib.push(after.map(|usage| usage.1));
            result
        }

        fn scan(
            &mut self,
            folder: &Path,
            probe: &VideoProbe,
            policy: &MediaPolicy,
            settings: &SortSettings,
            context: &mut ScanContext,
        ) -> Snapshot {
            let before = context.metrics;
            let snapshot =
                self.measure(|| scan_once_with(folder, probe, policy, settings, context));
            self.operations.push(context.metrics.since(before));
            snapshot
        }

        fn print(&self) {
            let mut sorted = self.raw_ms.clone();
            sorted.sort_by(f64::total_cmp);
            let median = if sorted.len().is_multiple_of(2) {
                (sorted[sorted.len() / 2 - 1] + sorted[sorted.len() / 2]) / 2.0
            } else {
                sorted[sorted.len() / 2]
            };
            let mean = sorted.iter().sum::<f64>() / sorted.len() as f64;
            let stddev = (sorted.iter().map(|v| (v - mean).powi(2)).sum::<f64>()
                / sorted.len() as f64)
                .sqrt();
            let output = serde_json::json!({
                "measurements": self,
                "samples": sorted.len(),
                "median_ms": median,
                "p95_ms": sorted[(sorted.len() * 95).div_ceil(100) - 1],
                "max_ms": sorted.last(),
                "stddev_ms": stddev,
            });
            println!("FILLR_PERF {output}");
        }
    }

    /// Cumulative child CPU includes subprocesses reaped by this process. Peak RSS
    /// is the whole test process lifetime high-water mark, not a per-stage delta.
    fn resources() -> Option<(f64, u64)> {
        fn usage(who: libc::c_int) -> Option<libc::rusage> {
            let mut result = std::mem::MaybeUninit::<libc::rusage>::uninit();
            // SAFETY: getrusage writes a complete rusage to this valid allocation on
            // success. The value is read only after a successful return.
            (unsafe { libc::getrusage(who, result.as_mut_ptr()) } == 0)
                .then(|| unsafe { result.assume_init() })
        }
        fn millis(value: libc::timeval) -> f64 {
            value.tv_sec as f64 * 1000.0 + value.tv_usec as f64 / 1000.0
        }
        let own = usage(libc::RUSAGE_SELF)?;
        let children = usage(libc::RUSAGE_CHILDREN)?;
        let cpu = millis(own.ru_utime)
            + millis(own.ru_stime)
            + millis(children.ru_utime)
            + millis(children.ru_stime);
        #[cfg(target_os = "macos")]
        let rss_kib = own.ru_maxrss.max(0) as u64 / 1024;
        #[cfg(not(target_os = "macos"))]
        let rss_kib = own.ru_maxrss.max(0) as u64;
        Some((cpu, rss_kib))
    }

    fn policy() -> MediaPolicy {
        MediaPolicy {
            enabled: false,
            delete_rejected: false,
            ..MediaPolicy::default()
        }
    }

    fn mock_probe(root: &Path, failing: bool) -> VideoProbe {
        let path = root.join(if failing {
            "failed-probe"
        } else {
            "mock-probe"
        });
        let script = if failing {
            "#!/bin/sh\nprintf '%s\\n' 'synthetic malformed media' >&2\nexit 1\n"
        } else {
            "#!/bin/sh\nprintf '%s\\n' '{\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"mpeg2video\",\"width\":1920,\"height\":1080}],\"format\":{\"format_name\":\"mpeg\",\"duration\":\"605.0\"}}'\n"
        };
        fs::write(&path, script).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        VideoProbe::new(path)
    }

    fn fixtures(folder: &Path, count: usize, identical: bool) {
        fs::create_dir(folder).unwrap();
        let aged = SystemTime::now() - Duration::from_secs(30);
        for index in 0..count {
            let path = folder.join(format!("clip_{index:04}.mpg"));
            // Small real writes exercise reconciliation. These are not encoded
            // media and make no claim about disk or real-media throughput.
            fs::write(&path, vec![0x5a; if identical { 1024 } else { 32 + index }]).unwrap();
            File::open(&path)
                .unwrap()
                .set_times(FileTimes::new().set_modified(aged))
                .unwrap();
        }
    }

    fn aged_context(folder: &Path) -> ScanContext {
        let mut context = ScanContext::default();
        let observed = SystemTime::now() - Duration::from_secs(11);
        for entry in fs::read_dir(folder).unwrap() {
            let entry = entry.unwrap();
            context.seen.insert(
                entry.file_name().to_string_lossy().into_owned(),
                (stamp(&entry.metadata().unwrap()), observed),
            );
        }
        context
    }

    #[test]
    #[ignore = "opt-in release performance experiment; uses only temporary fixtures"]
    // Fail when explicitly run in debug, while allowing normal debug test builds.
    #[allow(clippy::assertions_on_constants)]
    fn performance_baseline() {
        assert!(
            !cfg!(debug_assertions),
            "Run this experiment with --release"
        );
        println!(
            "FILLR_PERF_SCOPE warm OS cache; cold means empty FILLR caches, not flushed disk caches; mocked files/probes are synthetic; setup, ten-second settling wait, worker scheduling and UI excluded; single test thread required"
        );
        let root = tempfile::tempdir().unwrap();
        let probe = mock_probe(root.path(), false);
        let settings = SortSettings::default();
        let policy = policy();
        for count in [20, 200, 2000] {
            let folder = root.path().join(format!("distinct_{count}"));
            fixtures(&folder, count, false);
            let mut cold = Measurements::new(
                format!("mock_eligibility_to_ready_{count}"),
                "5 empty FILLR-cache scans; synthetic distinct-size media and shell probe; aged observed stamps; warm OS cache; includes probing and allocation",
            );
            for _ in 0..5 {
                let mut context = aged_context(&folder);
                let snapshot = cold.scan(&folder, &probe, &policy, &settings, &mut context);
                assert_eq!(snapshot.status, Status::Ready);
                assert_eq!(snapshot.clips.len(), count);
                let durations: Vec<_> = snapshot
                    .clips
                    .iter()
                    .map(|clip| (clip.filename.clone(), clip.duration_ms))
                    .collect();
                assert!(snapshot.plan.unwrap().validate_with(&durations, &settings));
            }
            cold.print();

            let mut context = aged_context(&folder);
            assert_eq!(
                scan_once_with(&folder, &probe, &policy, &settings, &mut context).status,
                Status::Ready
            );
            let mut warm = Measurements::new(
                format!("mock_warm_reconcile_{count}"),
                "25 unchanged settled scans after priming successful probe/hash/plan caches; warm OS cache; synthetic distinct-size media",
            );
            for _ in 0..25 {
                let snapshot = warm.scan(&folder, &probe, &policy, &settings, &mut context);
                assert_eq!(snapshot.status, Status::Ready);
                assert_eq!(snapshot.clips.len(), count);
            }
            warm.print();
        }

        let duplicate_settings = SortSettings {
            folder_count: 1,
            total_ms: 605_000,
            ..settings.clone()
        };
        let mut duplicate = Measurements::new(
            "synthetic_duplicate_heavy_40".into(),
            "5 fresh temporary directories with 40 identical 1KiB synthetic files; includes hash, exact byte comparison and available open-file safety checks; deletion may defer when open-file checking is unavailable",
        );
        for sample in 0..5 {
            let folder = root.path().join(format!("duplicates_{sample}"));
            fixtures(&folder, 40, true);
            let mut context = aged_context(&folder);
            let snapshot =
                duplicate.scan(&folder, &probe, &policy, &duplicate_settings, &mut context);
            assert_eq!(snapshot.clips.len(), 1);
            assert_eq!(snapshot.status, Status::Ready);
            println!(
                "FILLR_PERF_DUPLICATES sample={sample} deleted={} deferred={}",
                snapshot.duplicate_log.len(),
                snapshot.excluded.len() + snapshot.pending.len()
            );
        }
        duplicate.print();

        let failing = mock_probe(root.path(), true);
        let folder = root.path().join("malformed");
        fixtures(&folder, 20, false);
        let mut context = aged_context(&folder);
        let mut malformed = Measurements::new(
            "mock_malformed_retry_20".into(),
            "5 scans of 20 synthetic malformed files with shell probe failure; failures must retry and preserve every file",
        );
        for _ in 0..5 {
            let snapshot = malformed.scan(&folder, &failing, &policy, &settings, &mut context);
            assert!(snapshot.clips.is_empty());
            assert_eq!(snapshot.excluded.len(), 20);
            assert_eq!(fs::read_dir(&folder).unwrap().count(), 20);
        }
        malformed.print();

        match crate::staged_ffprobe_path() {
            Ok(path) => {
                println!("FILLR_PERF_PROBE executable={}", path.display());
                let real_probe = VideoProbe::new(path);
                for extension in ["mpg", "mp4"] {
                    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
                        .join(format!("../../tests/fixtures/probe.{extension}"));
                    assert!(fixture.is_file(), "Missing encoded smoke fixture");
                    for _ in 0..2 {
                        assert!(
                            real_probe
                                .media_info(&fixture)
                                .unwrap()
                                .duration_ms
                                .is_some()
                        );
                    }
                    let mut encoded = Measurements::new(
                        format!("encoded_smoke_probe_{extension}"),
                        "10 packaged FFprobe executions after 2 warmups; repository tiny encoded synthetic smoke fixture; not representative collection throughput",
                    );
                    for _ in 0..10 {
                        let info = encoded.measure(|| real_probe.media_info(&fixture).unwrap());
                        assert!(info.duration_ms.is_some());
                    }
                    encoded.print();
                }
            }
            Err(error) => println!("FILLR_PERF_SKIP packaged_probe: {error}"),
        }
    }
}

#[test]
#[ignore = "opt-in synthetic unchanged-state publication measurement"]
fn snapshot_publication_performance() {
    use super::*;
    let mut next = Snapshot::empty(Path::new("/temporary-fixture"), &SortSettings::default());
    next.clips = (0..2000)
        .map(|i| Clip {
            filename: format!("clip_{i:04}.mpg"),
            duration_ms: 605_000,
            size_bytes: 100_000_000,
            modified_ms: 1_000,
        })
        .collect();
    for legacy in [true, false] {
        let shared = Mutex::new((
            next.clone(),
            Arc::new(serde_json::to_string(&next).unwrap()),
        ));
        let mut raw_ms = Vec::new();
        for sample in 0..110 {
            let candidate = next.clone(); // identical producer cost excluded in both paths
            let start = Instant::now();
            if legacy {
                let json = Arc::new(serde_json::to_string(&candidate).unwrap());
                *shared.lock().unwrap() = (candidate, json);
            } else {
                assert!(!publish_snapshot(&shared, candidate));
            }
            if sample >= 10 {
                raw_ms.push(start.elapsed().as_secs_f64() * 1000.0);
            }
        }
        let mut sorted = raw_ms.clone();
        sorted.sort_by(f64::total_cmp);
        let mean = sorted.iter().sum::<f64>() / sorted.len() as f64;
        let sd =
            (sorted.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / sorted.len() as f64).sqrt();
        println!(
            "FILLR_SNAPSHOT_PERF {}",
            serde_json::json!({
                "mode": if legacy { "serialize_every_scan" } else { "compare_unchanged_snapshot" },
                "conditions": "2000 synthetic clips; 10 warmups/100 samples; producer clone excluded equally; publication only, not UI presentation or FFI transfer",
                "raw_ms": raw_ms, "median_ms": (sorted[49]+sorted[50])/2.0,
                "p95_ms": sorted[94], "max_ms": sorted[99], "stddev_ms": sd,
            })
        );
    }
}
