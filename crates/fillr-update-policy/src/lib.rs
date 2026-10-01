//! Shared policy and verification. Only VerifiedUpdate can download/install an artifact.
//! Private keys, application-specific engines, UI, and telemetry do not belong here.
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use semver::Version;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    error::Error,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
pub const MAX_METADATA: u64 = tlo_updater::MANIFEST_LIMIT;
pub const CHECK_INTERVAL: u64 = tlo_updater::CHECK_INTERVAL;
pub const RETRY_INTERVAL: u64 = tlo_updater::RETRY_INTERVAL;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(rename = "application_id")]
    pub app_id: String,
    pub repository: String,
    pub version: String,
    pub platform: String,
    pub architecture: String,
    /// OS version supplied by the native adapter (not by downloaded metadata).
    pub os_version: String,
    /// Actual glibc version on Linux, independent of the kernel version.
    #[serde(default)]
    pub glibc_version: Option<String>,
    pub keys: BTreeMap<String, String>,
    /// Per-application platform identity pinned in the installed, signed build.
    pub identity: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Asset {
    pub platform: String,
    pub architecture: String,
    pub minimum_os: String,
    pub minimum_glibc: Option<String>,
    pub filename: String,
    pub url: String,
    pub size: u64,
    pub sha256: String,
    pub format: String,
    pub identity: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema: u32,
    #[serde(rename = "application_id")]
    pub app_id: String,
    pub repository: String,
    pub version: String,
    pub tag: String,
    pub channel: String,
    pub draft: bool,
    pub prerelease: bool,
    pub published_at: String,
    pub expires_at: String,
    /// Binds Sparkle metadata to the same authenticated release artifact set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub appcast_sha256: Option<String>,
    pub release_notes_url: String,
    pub restart_required: bool,
    /// Only "none" is currently installable; unknown migrations fail closed.
    pub migration: String,
    #[serde(with = "asset_map")]
    pub assets: Vec<Asset>,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub key_id: String,
    pub payload: String,
    pub signature: String,
}
#[derive(Debug)]
pub struct VerifiedUpdate {
    manifest: Manifest,
    asset: Asset,
}
impl VerifiedUpdate {
    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }
    pub fn asset(&self) -> &Asset {
        &self.asset
    }
    /// Staging stays private, non-executable, and temporary until complete verification.
    pub fn stage(&self, source: impl Read, parent: &Path) -> Result<StagedUpdate> {
        let mut file = tempfile::NamedTempFile::new_in(parent)?;
        verify_download(source, &mut file, &self.asset)?;
        file.as_file().sync_all()?;
        Ok(StagedUpdate {
            file,
            asset: self.asset.clone(),
            version: self.manifest.version.clone(),
        })
    }
}
pub struct StagedUpdate {
    file: tempfile::NamedTempFile,
    asset: Asset,
    version: String,
}
impl StagedUpdate {
    pub fn path(&self) -> &Path {
        self.file.path()
    }
    pub fn version(&self) -> &str {
        &self.version
    }
    /// Recheck immediately before native installation; never accept a caller-supplied digest.
    pub fn reverify(&self) -> Result<()> {
        verify_download(fs::File::open(self.path())?, std::io::sink(), &self.asset)
    }
    pub fn save(self, destination: &Path) -> Result<PathBuf> {
        self.reverify()?;
        self.file.persist_noclobber(destination)?;
        Ok(destination.to_owned())
    }
}

pub fn stable_version(raw: &str) -> Result<Version> {
    tlo_updater::stable_version(raw).map_err(|e| e.to_string().into())
}

fn safe_component(raw: &str) -> bool {
    !raw.is_empty()
        && raw != "."
        && raw != ".."
        && raw
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}
impl Config {
    pub fn validate(&self) -> Result<()> {
        stable_version(&self.version)?;
        stable_version(&self.os_version)?;
        if let Some(glibc) = &self.glibc_version {
            stable_version(glibc)?;
        }
        let parts: Vec<_> = self.repository.split('/').collect();
        if parts.len() != 2
            || !parts.iter().all(|s| safe_component(s))
            || !safe_component(&self.app_id)
            || !["macos", "windows", "linux"].contains(&self.platform.as_str())
            || !["x86_64", "aarch64"].contains(&self.architecture.as_str())
            || self.identity.is_empty()
        {
            return Err("Invalid installed updater configuration".into());
        }
        if self.keys.is_empty() {
            return Err("Updates are not configured in this build (no trusted public key)".into());
        }
        for (id, key) in &self.keys {
            if !safe_component(id) || B64.decode(key)?.len() != 32 {
                return Err("Invalid trusted update key".into());
            }
        }
        Ok(())
    }
    pub fn feed_url(&self) -> String {
        format!(
            "https://github.com/{}/releases/latest/download/update-manifest.json",
            self.repository
        )
    }
}
/// Authenticate exact payload bytes BEFORE deserialization or interpreting any metadata.
/// Return None for old/same/incompatible releases. Invalid channels and drafts fail closed.
pub fn discover(
    bytes: &[u8],
    config: &Config,
    now: i64,
    highest_seen: Option<&str>,
) -> Result<Option<VerifiedUpdate>> {
    config.validate()?;
    if bytes.len() as u64 > MAX_METADATA {
        return Err("Update metadata exceeds limit".into());
    }
    let envelope: Envelope = serde_json::from_slice(bytes)?;
    let key = config
        .keys
        .get(&envelope.key_id)
        .ok_or("Unknown update signing key")?;
    // The existing TLO schema-2 verifier owns authenticity, application identity,
    // stable policy, target/URL/size/digest validation, and semantic version parsing.
    let common_config = common_config(config, key.clone());
    let common = tlo_updater::verify(bytes, &common_config).map_err(|e| e.to_string())?;
    let manifest: Manifest = serde_json::from_slice(&B64.decode(&envelope.payload)?)?;
    let published = chrono::DateTime::parse_from_rfc3339(&manifest.published_at)?.timestamp();
    let expires = chrono::DateTime::parse_from_rfc3339(&manifest.expires_at)?.timestamp();
    if published > now + 300 || expires <= now || expires <= published {
        return Err("Expired or future-dated update metadata".into());
    }
    let selected = tlo_updater::select(
        &common,
        &common_config,
        highest_seen,
        &config.os_version,
        config.glibc_version.as_deref(),
    )
    .map_err(|e| e.to_string())?;
    let Some(selected) = selected else {
        return Ok(None);
    };
    if manifest.migration != "none" {
        return Err("This update requires a manual migration; see the release notes".into());
    }
    let asset = manifest
        .assets
        .iter()
        .find(|a| {
            a.filename == selected.filename
                && a.platform == selected.platform
                && a.architecture == selected.architecture
        })
        .ok_or("Selected artifact extension is missing")?;
    if asset.identity != config.identity {
        return Err("Unexpected platform signing/application identity".into());
    }
    Ok(Some(VerifiedUpdate {
        asset: asset.clone(),
        manifest,
    }))
}

fn common_asset(asset: &Asset) -> tlo_updater::Asset {
    tlo_updater::Asset {
        url: asset.url.clone(),
        filename: asset.filename.clone(),
        size: asset.size,
        sha256: asset.sha256.clone(),
        platform: asset.platform.clone(),
        architecture: asset.architecture.clone(),
        minimum_os: asset.minimum_os.clone(),
        minimum_glibc: asset.minimum_glibc.clone(),
        format: asset.format.clone(),
    }
}
fn verify_download(source: impl Read, output: impl Write, asset: &Asset) -> Result<()> {
    tlo_updater::download(source, output, &common_asset(asset)).map_err(|e| e.to_string().into())
}

/// No cookies, credentials, identifiers, or system profile. Redirects are HTTPS GitHub CDN only.
pub struct GitHub {
    client: reqwest::blocking::Client,
}
impl GitHub {
    pub fn new() -> Result<Self> {
        let client = tlo_updater::client::http_client().map_err(|e| e.to_string())?;
        Ok(Self { client })
    }
    pub fn metadata(&self, config: &Config) -> Result<Vec<u8>> {
        config.validate()?;
        let key = config
            .keys
            .values()
            .next()
            .ok_or("No trusted update key")?
            .clone();
        tlo_updater::client::metadata(&self.client, &common_config(config, key))
            .map_err(|e| e.to_string().into())
    }

    pub fn download(&self, update: &VerifiedUpdate, parent: &Path) -> Result<StagedUpdate> {
        let response = self
            .client
            .get(&update.asset.url)
            .send()?
            .error_for_status()?;
        update.stage(response, parent)
    }
}
pub fn bounded_read(source: impl Read, limit: u64) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    source.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("Response exceeds limit".into());
    }
    Ok(bytes)
}
#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct CheckState {
    pub disabled: bool,
    pub last_attempt: u64,
    pub last_success: u64,
    pub highest_seen: Option<String>,
}
impl CheckState {
    pub fn due(&self, now: u64, manual: bool) -> bool {
        manual
            || (!self.disabled
                && ((self.last_attempt == 0 && self.last_success == 0)
                    || tlo_updater::State {
                        last_attempt: self.last_attempt,
                        last_success: self.last_success,
                        highest_version: self.highest_seen.clone(),
                    }
                    .due(now)))
    }

    pub fn load(path: &Path) -> Result<Self> {
        match fs::File::open(path) {
            Ok(f) => Ok(serde_json::from_slice(&bounded_read(f, MAX_METADATA)?)?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e.into()),
        }
    }
    pub fn save(&self, path: &Path) -> Result<()> {
        let parent = path.parent().ok_or("Missing cache parent")?;
        fs::create_dir_all(parent)?;
        let mut file = tempfile::NamedTempFile::new_in(parent)?;
        serde_json::to_writer(&mut file, self)?;
        file.as_file().sync_all()?;
        file.persist(path)?;
        Ok(())
    }
}

/// AppImage replacement is a single same-filesystem atomic rename, with a durable backup.
/// No downloaded code is executed. The GUI must require explicit consent and hold its work gate.
#[cfg(unix)]
pub fn install_appimage(
    staged: StagedUpdate,
    target: &Path,
    running_image: &Path,
) -> Result<PathBuf> {
    if staged.asset.platform != "linux" || target != running_image {
        return Err("Not the running AppImage".into());
    }
    staged.reverify()?;
    tlo_updater::client::install_appimage(
        fs::File::open(staged.path())?,
        &common_asset(&staged.asset),
        target,
    )
    .map_err(|e| e.to_string().into())
}

fn common_config(config: &Config, public_key: String) -> tlo_updater::Config {
    let arch = if config.architecture == "aarch64" {
        "arm64"
    } else {
        "x64"
    };
    let target = match config.platform.as_str() {
        "macos" => "macos-universal".into(),
        "windows" => format!("windows-{arch}-msix"),
        _ => format!("linux-{arch}-appimage"),
    };
    tlo_updater::Config {
        application_id: config.app_id.clone(),
        repository: config.repository.clone(),
        version: config.version.clone(),
        channel: "stable".into(),
        target,
        public_key,
    }
}
mod asset_map {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        assets: &[Asset],
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        let values: BTreeMap<String, &Asset> = assets
            .iter()
            .map(|a| {
                let arch = if a.architecture == "aarch64" {
                    "arm64"
                } else {
                    "x64"
                };
                let target = match a.platform.as_str() {
                    "macos" => "macos-universal".into(),
                    "windows" => format!("windows-{arch}-msix"),
                    _ => format!("linux-{arch}-appimage"),
                };
                (target, a)
            })
            .collect();
        values.serialize(serializer)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Vec<Asset>, D::Error> {
        Ok(BTreeMap::<String, Asset>::deserialize(deserializer)?
            .into_values()
            .collect())
    }
}

/// Use the shared native OS query; unknown versions fail closed in the adapter.
pub fn host_versions() -> Result<(String, Option<String>)> {
    tlo_updater::client::platform_versions().map_err(|e| e.to_string().into())
}
