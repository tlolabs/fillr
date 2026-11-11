use fillr_core::{
    Clip, Engine, ExcludedFile, Snapshot, Status, VideoProbe, make_plan, staged_ffprobe_path,
};
use sha2::{Digest, Sha256};
use std::ffi::{CStr, c_char, c_void};
use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::time::Instant;

unsafe extern "C" {
    fn fillr_snapshot(engine: *mut c_void) -> *mut c_char;
    fn fillr_free_string(value: *mut c_char);
}

struct Stats {
    runs: Vec<f64>,
}

impl Stats {
    fn new(runs: Vec<f64>) -> Self {
        Self { runs }
    }

    fn median(&self) -> f64 {
        let mut sorted = self.runs.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let mid = sorted.len() / 2;
        if sorted.len().is_multiple_of(2) {
            (sorted[mid - 1] + sorted[mid]) / 2.0
        } else {
            sorted[mid]
        }
    }

    fn mean(&self) -> f64 {
        self.runs.iter().sum::<f64>() / self.runs.len() as f64
    }

    fn p95(&self) -> f64 {
        let mut sorted = self.runs.clone();
        sorted.sort_by(f64::total_cmp);
        sorted[(sorted.len() * 95).div_ceil(100) - 1]
    }

    fn min(&self) -> f64 {
        self.runs.iter().cloned().fold(f64::INFINITY, f64::min)
    }

    fn max(&self) -> f64 {
        self.runs.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
    }

    fn std_dev(&self) -> f64 {
        let mean = self.mean();
        let variance =
            self.runs.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / self.runs.len() as f64;
        variance.sqrt()
    }
}

fn bench_fn<F>(name: &str, warmup: usize, iterations: usize, mut f: F) -> Stats
where
    F: FnMut(),
{
    for _ in 0..warmup {
        f();
    }
    let mut times = Vec::with_capacity(iterations);
    for _ in 0..iterations {
        let start = Instant::now();
        f();
        let elapsed = start.elapsed().as_secs_f64() * 1000.0; // ms
        times.push(elapsed);
    }
    let stats = Stats::new(times);
    println!(
        "{:<35} | Warmup: {:2} | N: {:3} | Median: {:10.6} ms | P95: {:10.6} ms | Mean: {:10.6} ms | Min: {:10.6} ms | Max: {:10.6} ms | StdDev: {:10.6} ms",
        name,
        warmup,
        stats.runs.len(),
        stats.median(),
        stats.p95(),
        stats.mean(),
        stats.min(),
        stats.max(),
        stats.std_dev()
    );
    println!("samples_ms {name}: {:?}", stats.runs);
    stats
}

fn generate_synthetic_clips(count: usize, min_ms: u64, max_ms: u64) -> Vec<(String, u64)> {
    let mut clips = Vec::with_capacity(count);
    let mut state = 123456789u64;
    let range = max_ms.saturating_sub(min_ms).max(1);
    for i in 0..count {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        let duration = min_ms + (state % range);
        clips.push((format!("clip_{i:04}.mpg"), duration));
    }
    clips
}

fn probe_benchmarks() {
    println!("--- 3. Video Probing Latency (new subprocess per sample, warm OS cache) ---");
    let ffprobe = match staged_ffprobe_path() {
        Ok(path) => path,
        Err(error) => {
            println!("SKIP probe benchmarks: {error}");
            return;
        }
    };
    println!("Packaged probe: {}", ffprobe.display());
    match std::process::Command::new(&ffprobe)
        .arg("-version")
        .output()
    {
        Ok(output) if output.status.success() => println!(
            "Probe version: {}",
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .next()
                .unwrap_or("version output empty")
        ),
        Ok(output) => {
            println!(
                "SKIP probe benchmarks: probe -version exited {}",
                output.status
            );
            return;
        }
        Err(error) => {
            println!("SKIP probe benchmarks: cannot execute packaged probe: {error}");
            return;
        }
    }
    let fixtures: Vec<(String, PathBuf)> = match std::env::var_os("FILLR_BENCH_MEDIA") {
        Some(path) => vec![("explicit_media".into(), PathBuf::from(path))],
        None => {
            println!(
                "Media provenance: repository tiny encoded synthetic fixtures; these measure launch/metadata latency, not real media throughput. Set FILLR_BENCH_MEDIA to an explicitly authorized media file for representative probing."
            );
            ["mpg", "mp4"]
                .into_iter()
                .map(|extension| {
                    (
                        format!("synthetic_fixture_{extension}"),
                        Path::new(env!("CARGO_MANIFEST_DIR"))
                            .join(format!("../../tests/fixtures/probe.{extension}")),
                    )
                })
                .collect()
        }
    };
    let probe = VideoProbe::new(ffprobe);
    for (label, path) in fixtures {
        match std::fs::metadata(&path) {
            Ok(metadata) if metadata.is_file() => println!(
                "Probe media {label}: {} ({} bytes, modified {:?})",
                path.display(),
                metadata.len(),
                metadata.modified().ok()
            ),
            Ok(_) => {
                println!(
                    "SKIP probe_{label}: {} is not a regular file",
                    path.display()
                );
                continue;
            }
            Err(error) => {
                println!("SKIP probe_{label}: {}: {error}", path.display());
                continue;
            }
        }
        if let Err(error) = probe.media_info(&path) {
            println!("SKIP probe_{label}: fixture preflight failed: {error}");
            continue;
        }
        bench_fn(&format!("probe_{label}_media_info"), 2, 10, || {
            let info = probe.media_info(black_box(&path)).unwrap();
            black_box(info);
        });
    }
}

fn cached_snapshot_benchmarks() {
    println!("--- Actual cached engine snapshots (isolated empty temporary folder) ---");
    let folder = tempfile::tempdir().unwrap();
    // An empty folder never probes or performs duplicate/rejection work. The
    // deliberately nonexistent executable also makes unexpected probes fail.
    let mut engine = Engine::new(folder.path(), folder.path().join("unused-ffprobe")).unwrap();
    let wait_started = Instant::now();
    while engine.snapshot().status == Status::Checking {
        assert!(
            wait_started.elapsed().as_secs() < 5,
            "empty scan did not finish"
        );
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    println!(
        "Cached snapshot provenance: empty temporary folder, {} JSON bytes; excludes decoding and UI presentation",
        engine.snapshot_json().len()
    );
    bench_fn("engine_cached_snapshot_json", 10, 100, || {
        black_box(engine.snapshot_json());
    });
    bench_fn("engine_ffi_snapshot_transfer", 10, 100, || {
        // SAFETY: this engine remains alive for the complete call; the exported
        // API synchronizes snapshot access. Each returned allocation is read
        // before being released once through its matching free function.
        unsafe {
            let json = fillr_snapshot((&mut engine as *mut Engine).cast());
            assert!(!json.is_null());
            black_box(CStr::from_ptr(json).to_bytes());
            fillr_free_string(json);
        }
    });
}

fn main() {
    println!("=== FILLR Comprehensive Performance Benchmarks ===");
    println!("OS: {} {}", std::env::consts::OS, std::env::consts::ARCH);
    println!(
        "Times: milliseconds; p95 uses nearest rank; StdDev is population standard deviation."
    );
    println!(
        "Warm-cache measurements after the listed warmups; no OS cache purge. Raw samples follow each result."
    );
    println!();

    // 1. Allocation Solver Benchmarks
    println!("--- 1. Allocation Solver (synthetic names/durations, make_plan) ---");
    let clips_14: Vec<_> = (0..14).map(|i| (format!("{i}.mpg"), 605_000)).collect();
    bench_fn("allocation_14_clips", 3, 20, || {
        let plan = make_plan(black_box(&clips_14));
        assert!(plan.is_some());
    });

    let clips_60 = generate_synthetic_clips(60, 150_000, 220_000);
    bench_fn("allocation_60_clips", 3, 20, || {
        let plan = make_plan(black_box(&clips_60));
        assert!(plan.is_some());
    });

    let clips_185 = generate_synthetic_clips(185, 60_000, 120_000);
    bench_fn("allocation_185_clips", 3, 20, || {
        let plan = make_plan(black_box(&clips_185));
        assert!(plan.is_some());
    });

    let clips_500 = generate_synthetic_clips(500, 40_000, 90_000);
    bench_fn("allocation_500_clips", 2, 10, || {
        let plan = make_plan(black_box(&clips_500));
        assert!(plan.is_some());
    });

    let clips_2000 = generate_synthetic_clips(2000, 40_000, 90_000);
    bench_fn("allocation_2000_clips", 2, 10, || {
        let plan = make_plan(black_box(&clips_2000)).unwrap();
        assert!(plan.validate(&clips_2000));
    });

    // 2. Snapshot Serialization & FFI Cloning Simulation (1Hz UI poll)
    println!();
    println!("--- 2. Synthetic Snapshot Serialization & Clone (not the cached UI poll path) ---");
    let sample_clips: Vec<_> = (0..185)
        .map(|i| Clip {
            filename: format!("{:08}.mpg", 10000000 + i),
            duration_ms: 72_000,
            size_bytes: 150_000_000,
            modified_ms: 1728000000000,
        })
        .collect();
    let plan = make_plan(&clips_185);
    let sample_snapshot = Snapshot {
        api_version: 1,
        folder: "/Users/tlothian/Documents/Projects/FILLR/CNN VIdeos".into(),
        status: Status::Ready,
        available_ms: 13_320_000,
        remaining_ms: 0,
        clips: sample_clips,
        pending: vec![],
        downloads: vec![],
        excluded: (0..10)
            .map(|i| ExcludedFile {
                filename: format!("corrupt_{i}.mpg"),
                reason: "Oversized frame".into(),
            })
            .collect(),
        duplicate_log: (0..50).map(|i| format!("Duplicate entry {i}")).collect(),
        rejection_log: (0..50).map(|i| format!("Rejection entry {i}")).collect(),
        plan,
        message: "Ready — no more downloads needed".into(),
    };

    bench_fn("snapshot_clone_and_serialize", 10, 100, || {
        let cloned = black_box(&sample_snapshot).clone();
        let json = serde_json::to_string(&cloned).unwrap();
        black_box(json);
    });

    let mut large_snapshot = sample_snapshot.clone();
    large_snapshot.clips = (0..2000)
        .map(|i| Clip {
            filename: format!("{:08}.mpg", 10000000 + i),
            duration_ms: 72_000,
            size_bytes: 150_000_000,
            modified_ms: 1728000000000,
        })
        .collect();
    bench_fn("snapshot_clone_serialize_2000", 10, 100, || {
        let cloned = black_box(&large_snapshot).clone();
        black_box(serde_json::to_string(&cloned).unwrap());
    });
    cached_snapshot_benchmarks();

    // 3. Probe only repository fixtures or a file explicitly selected by the caller.
    println!();
    probe_benchmarks();

    // 4. SHA-256 Duplicate Check Stream Hashing Throughput
    println!();
    println!("--- 4. Synthetic SHA-256 (repeated in-memory bytes, not disk/media throughput) ---");
    let test_data = vec![0x5a; 10 * 1024 * 1024]; // 10MB
    bench_fn("sha256_10mb_block", 2, 20, || {
        let mut hasher = Sha256::new();
        hasher.update(black_box(&test_data));
        let hash = hasher.finalize();
        black_box(hash);
    });

    println!();
    println!("=== Benchmarks Complete ===");
}
