mod allocation;
mod export;
mod ffi;
mod media;
mod probe;
mod probe_path;
mod scan;
mod settings;

pub use allocation::{Assignment, COMP_NUMBERS, Plan, TARGET_MS, make_plan};
pub use export::{BuildResult, ExportError, build_export, recover_interrupted_builds};
pub use media::{MediaPolicy, Orientation, ScanType, TelevisionStandard};
pub use probe::{MediaInfo, ProbeError, VideoProbe};
pub use probe_path::{owned_ffprobe_for, owned_ffprobe_path, staged_ffprobe_path};
pub use scan::{Clip, Engine, EngineError, Snapshot, Status};
pub use settings::SortSettings;

/// Authoritative application version, inherited from the Cargo workspace.
pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");
