use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

/// An estimate of bytes written while FILLR observed a media download.
/// Bytes already present at the first observation are never counted.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DownloadProgress {
    pub filename: String,
    pub size_bytes: u64,
    pub observed_bytes: u64,
    pub elapsed_ms: u64,
    pub average_bytes_per_second: f64,
    pub completed: bool,
}

pub(crate) struct DownloadObservation {
    pub filename: String,
    pub size_bytes: u64,
    pub identity: u128,
    pub temporary: bool,
}

struct Transfer {
    identity: u128,
    initial_size: u64,
    size: u64,
    started: Instant,
    observed: Instant,
    last_growth: Instant,
    ended: Option<Instant>,
    temporary: bool,
}

impl Transfer {
    fn new(sample: &DownloadObservation, now: Instant) -> Self {
        Self {
            identity: sample.identity,
            initial_size: sample.size_bytes,
            size: sample.size_bytes,
            started: now,
            observed: now,
            last_growth: now,
            ended: None,
            temporary: sample.temporary,
        }
    }

    fn active(&self) -> bool {
        self.ended.is_none() && (self.temporary || self.size > self.initial_size)
    }

    fn progress(&self, filename: &str, now: Instant) -> Option<DownloadProgress> {
        let observed_bytes = self.size.checked_sub(self.initial_size)?;
        let elapsed = self.ended.unwrap_or(now).duration_since(self.started);
        // Filesystem events can arrive in bursts. Avoid presenting a rate from
        // a tiny interval, or treating existing/preallocated bytes as a transfer.
        let minimum = if self.ended.is_some() {
            Duration::from_millis(100)
        } else {
            Duration::from_secs(1)
        };
        if observed_bytes == 0 || elapsed < minimum {
            return None;
        }
        Some(DownloadProgress {
            filename: filename.to_owned(),
            size_bytes: self.size,
            observed_bytes,
            elapsed_ms: elapsed.as_millis().min(u64::MAX as u128) as u64,
            average_bytes_per_second: observed_bytes as f64 / elapsed.as_secs_f64(),
            completed: self.ended.is_some(),
        })
    }
}

#[derive(Default)]
pub(crate) struct DownloadTracker {
    transfers: HashMap<String, Transfer>,
    last_completed: Option<(Instant, DownloadProgress)>,
}

impl DownloadTracker {
    pub fn is_active(&self) -> bool {
        self.transfers.values().any(Transfer::active)
    }

    pub fn sample(
        &mut self,
        samples: BTreeMap<String, DownloadObservation>,
        now: Instant,
        settle_for: Duration,
        complete_scan: bool,
    ) -> Vec<DownloadProgress> {
        if complete_scan {
            self.transfers.retain(|name, _| samples.contains_key(name));
        }
        for (name, sample) in &samples {
            let transfer = self
                .transfers
                .entry(name.clone())
                .or_insert_with(|| Transfer::new(sample, now));
            if transfer.identity != sample.identity || sample.size_bytes < transfer.size {
                // A replacement or restarted download needs its own baseline.
                *transfer = Transfer::new(sample, now);
            }
            if sample.size_bytes > transfer.size {
                if transfer.ended.is_some() {
                    // The same final file started growing again. Use the last
                    // sample as the baseline rather than including its idle time.
                    transfer.initial_size = transfer.size;
                    transfer.started = transfer.observed;
                    transfer.ended = None;
                }
                transfer.size = sample.size_bytes;
                transfer.last_growth = now;
            }
            if transfer.temporary && !sample.temporary {
                // The work file became its final name with the same identity.
                // This only ends speed measurement; media safety checks remain
                // responsible for deciding when the file can be used.
                transfer.ended = Some(now);
            } else if sample.temporary {
                transfer.ended = None;
            } else if transfer.ended.is_none()
                && now.duration_since(transfer.last_growth) >= settle_for
            {
                // Do not dilute the final average with the settling wait.
                transfer.ended = Some(transfer.last_growth);
            }
            transfer.temporary = sample.temporary;
            transfer.observed = now;

            if let Some(ended) = transfer.ended
                && let Some(progress) = transfer.progress(&sample.filename, now)
                && self
                    .last_completed
                    .as_ref()
                    .is_none_or(|(previous, _)| ended >= *previous)
            {
                self.last_completed = Some((ended, progress));
            }
        }
        if self.is_active() {
            samples
                .iter()
                .filter_map(|(name, sample)| {
                    let transfer = &self.transfers[name];
                    transfer
                        .active()
                        .then(|| transfer.progress(&sample.filename, now))
                        .flatten()
                })
                .collect()
        } else {
            self.last_completed
                .as_ref()
                .map(|(_, progress)| vec![progress.clone()])
                .unwrap_or_default()
        }
    }
}

/// Map known download names to the media filename, without counting checkpoint
/// sidecars. A work-to-final rename keeps the same key and byte baseline.
pub(crate) fn download_name(filename: &str) -> Option<(String, bool)> {
    let lower_filename = filename.to_ascii_lowercase();
    if filename.starts_with('.') || lower_filename.starts_with("#chkpt_file#") {
        return None;
    }
    let (name, mut temporary) = if lower_filename.starts_with("#work_file#") {
        (&filename["#work_file#".len()..], true)
    } else {
        (filename, false)
    };
    if name.starts_with('#') || name.starts_with('.') {
        return None;
    }
    let lower = name.to_ascii_lowercase();
    let name = [".crdownload", ".part", ".download"]
        .iter()
        .find_map(|suffix| {
            lower
                .ends_with(suffix)
                .then(|| &name[..name.len() - suffix.len()])
        })
        .inspect(|_| temporary = true)
        .unwrap_or(name);
    let extension = name.rsplit_once('.')?.1;
    [
        "mpg", "mpeg", "mp4", "mov", "mxf", "ts", "m2ts", "avi", "mkv",
    ]
    .iter()
    .any(|allowed| extension.eq_ignore_ascii_case(allowed))
    .then(|| (name.to_owned(), temporary))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(name: &str, size: u64, identity: u128) -> DownloadObservation {
        let (filename, temporary) = download_name(name).unwrap();
        DownloadObservation {
            filename,
            size_bytes: size,
            identity,
            temporary,
        }
    }

    fn observe(
        tracker: &mut DownloadTracker,
        now: Instant,
        samples: Vec<DownloadObservation>,
    ) -> Vec<DownloadProgress> {
        tracker.sample(
            samples
                .into_iter()
                .map(|s| (s.filename.clone(), s))
                .collect(),
            now,
            Duration::from_secs(10),
            true,
        )
    }

    #[test]
    fn mid_transfer_baseline_pauses_and_final_rename() {
        let start = Instant::now();
        let mut tracker = DownloadTracker::default();
        assert!(
            observe(
                &mut tracker,
                start,
                vec![sample("#work_file#clip.mpg", 1_000_000, 1)]
            )
            .is_empty()
        );
        let growing = observe(
            &mut tracker,
            start + Duration::from_secs(2),
            vec![sample("#work_file#clip.mpg", 5_000_000, 1)],
        );
        assert_eq!(growing[0].observed_bytes, 4_000_000);
        assert_eq!(growing[0].average_bytes_per_second, 2_000_000.0);
        let paused = observe(
            &mut tracker,
            start + Duration::from_secs(4),
            vec![sample("#work_file#clip.mpg", 5_000_000, 1)],
        );
        assert_eq!(paused[0].average_bytes_per_second, 1_000_000.0);
        assert!(!paused[0].completed);
        let finished = observe(
            &mut tracker,
            start + Duration::from_secs(5),
            vec![sample("clip.mpg", 6_000_000, 1)],
        );
        assert_eq!(finished[0].filename, "clip.mpg");
        assert_eq!(finished[0].observed_bytes, 5_000_000);
        assert_eq!(finished[0].average_bytes_per_second, 1_000_000.0);
        assert!(finished[0].completed);
        let removed = observe(&mut tracker, start + Duration::from_secs(20), vec![]);
        assert_eq!(removed[0].average_bytes_per_second, 1_000_000.0);
    }

    #[test]
    fn simultaneous_transfers_have_independent_averages() {
        let start = Instant::now();
        let mut tracker = DownloadTracker::default();
        observe(
            &mut tracker,
            start,
            vec![
                sample("a.mpg.part", 100, 1),
                sample("#work_file#b.mp4", 200, 2),
            ],
        );
        let rates = observe(
            &mut tracker,
            start + Duration::from_secs(2),
            vec![
                sample("a.mpg.part", 500, 1),
                sample("#work_file#b.mp4", 1_000, 2),
            ],
        );
        assert_eq!(rates.len(), 2);
        assert_eq!(rates[0].average_bytes_per_second, 200.0);
        assert_eq!(rates[1].average_bytes_per_second, 400.0);
    }

    #[test]
    fn subsecond_completed_transfer_has_an_average() {
        let start = Instant::now();
        let mut tracker = DownloadTracker::default();
        observe(
            &mut tracker,
            start,
            vec![sample("#work_file#clip.mpg", 100, 1)],
        );
        assert!(
            observe(
                &mut tracker,
                start + Duration::from_millis(50),
                vec![sample("#work_file#clip.mpg", 200, 1)]
            )
            .is_empty()
        );
        let finished = observe(
            &mut tracker,
            start + Duration::from_millis(500),
            vec![sample("clip.mpg", 1_100, 1)],
        );
        assert!(finished[0].completed);
        assert_eq!(finished[0].average_bytes_per_second, 2_000.0);
    }

    #[test]
    fn replacement_and_truncation_reset_the_baseline() {
        let start = Instant::now();
        let mut tracker = DownloadTracker::default();
        observe(&mut tracker, start, vec![sample("clip.mpg.part", 1_000, 1)]);
        observe(
            &mut tracker,
            start + Duration::from_secs(2),
            vec![sample("clip.mpg.part", 2_000, 1)],
        );
        assert!(
            observe(
                &mut tracker,
                start + Duration::from_secs(3),
                vec![sample("clip.mpg.part", 3_000, 2)]
            )
            .is_empty()
        );
        let replacement = observe(
            &mut tracker,
            start + Duration::from_secs(5),
            vec![sample("clip.mpg.part", 4_000, 2)],
        );
        assert_eq!(replacement[0].average_bytes_per_second, 500.0);
        assert!(
            observe(
                &mut tracker,
                start + Duration::from_secs(6),
                vec![sample("clip.mpg.part", 100, 2)]
            )
            .is_empty()
        );
        let restarted = observe(
            &mut tracker,
            start + Duration::from_secs(8),
            vec![sample("clip.mpg.part", 300, 2)],
        );
        assert_eq!(restarted[0].average_bytes_per_second, 100.0);
    }

    #[test]
    fn final_file_growth_freezes_at_last_growth_after_settling() {
        let start = Instant::now();
        let mut tracker = DownloadTracker::default();
        observe(&mut tracker, start, vec![sample("clip.mpg", 100, 1)]);
        observe(
            &mut tracker,
            start + Duration::from_secs(2),
            vec![sample("clip.mpg", 500, 1)],
        );
        let finished = observe(
            &mut tracker,
            start + Duration::from_secs(12),
            vec![sample("clip.mpg", 500, 1)],
        );
        assert!(finished[0].completed);
        assert_eq!(finished[0].average_bytes_per_second, 200.0);
        let resumed = observe(
            &mut tracker,
            start + Duration::from_secs(14),
            vec![sample("clip.mpg", 900, 1)],
        );
        assert!(!resumed[0].completed);
        assert_eq!(resumed[0].observed_bytes, 400);
        assert_eq!(resumed[0].average_bytes_per_second, 200.0);
    }

    #[test]
    fn preexisting_and_preallocated_files_do_not_imply_speed() {
        let start = Instant::now();
        let mut tracker = DownloadTracker::default();
        observe(
            &mut tracker,
            start,
            vec![
                sample("existing.mpg", 1_000_000, 1),
                sample("#work_file#preallocated.mpg", 2_000_000, 2),
            ],
        );
        assert!(
            observe(
                &mut tracker,
                start + Duration::from_secs(20),
                vec![
                    sample("existing.mpg", 1_000_000, 1),
                    sample("#work_file#preallocated.mpg", 2_000_000, 2)
                ]
            )
            .is_empty()
        );
        assert_eq!(download_name("#chkpt_file#clip.mpg"), None);
        assert_eq!(download_name("#ChKpT_FiLe#clip.mpg"), None);
        assert_eq!(download_name("notes.txt.part"), None);
        assert_eq!(download_name(".hidden.mpg"), None);
        assert_eq!(
            download_name("#WORK_FILE#clip.MPG"),
            Some(("clip.MPG".into(), true))
        );
        assert_eq!(
            download_name("#WoRk_FiLe#clip.MPG"),
            Some(("clip.MPG".into(), true))
        );
        assert_eq!(
            download_name("clip.mp4.crdownload"),
            Some(("clip.mp4".into(), true))
        );
    }
}
