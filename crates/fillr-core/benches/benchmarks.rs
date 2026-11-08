use fillr_core::{
    Clip, ExcludedFile, Snapshot, Status, VideoProbe, make_plan, staged_ffprobe_path,
};
use sha2::{Digest, Sha256};
use std::hint::black_box;
use std::time::Instant;

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
        "{:<35} | Median: {:8.2} ms | Mean: {:8.2} ms | Min: {:8.2} ms | Max: {:8.2} ms | StdDev: {:6.2} ms",
        name,
        stats.median(),
        stats.mean(),
        stats.min(),
        stats.max(),
        stats.std_dev()
    );
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

fn main() {
    println!("=== FILLR Comprehensive Performance Benchmarks ===");
    println!("OS: {} {}", std::env::consts::OS, std::env::consts::ARCH);
    println!();

    // 1. Allocation Solver Benchmarks
    println!("--- 1. Allocation Solver (make_plan) ---");
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

    // 2. Snapshot Serialization & FFI Cloning Simulation (1Hz UI poll)
    println!();
    println!("--- 2. Snapshot Serialization & Clone (UI 1Hz poll overhead) ---");
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

    // 3. Probing Latency (if real files and probe are available)
    println!();
    println!("--- 3. Video Probing Latency ---");
    if let Ok(ffprobe) = staged_ffprobe_path() {
        let probe = VideoProbe::new(ffprobe);
        let cnn_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../CNN VIdeos");
        if cnn_dir.is_dir() {
            // Find first real mpg file
            let mut test_clip = None;
            if let Ok(entries) = std::fs::read_dir(&cnn_dir) {
                for entry in entries.flatten() {
                    if entry
                        .path()
                        .extension()
                        .is_some_and(|e| e.eq_ignore_ascii_case("mpg"))
                    {
                        test_clip = Some(entry.path());
                        break;
                    }
                }
            }
            if let Some(clip_path) = test_clip {
                bench_fn("probe_single_clip_media_info", 2, 10, || {
                    let info = probe.media_info(black_box(&clip_path)).unwrap();
                    black_box(info);
                });
            }
        }
    }

    // 4. SHA-256 Duplicate Check Stream Hashing Throughput
    println!();
    println!("--- 4. Data Hashing Throughput (SHA-256 for duplicate checking) ---");
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
