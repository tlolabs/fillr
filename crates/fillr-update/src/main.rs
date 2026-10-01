//! Thin FILLR adapter. Trust and version are embedded; no runtime trust/URL overrides.
use fillr_update_policy::{CheckState, Config, GitHub, Result};
use std::{fs, path::PathBuf};
const TRUST: &str = include_str!("../../../updates/trust.json");
fn cache_directory() -> Result<PathBuf> {
    #[cfg(target_os = "windows")]
    let root = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(not(target_os = "windows"))]
    let root = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".cache")));
    validated_cache_directory(root.ok_or("No user cache directory")?)
}
fn validated_cache_directory(root: PathBuf) -> Result<PathBuf> {
    if !root.is_absolute() {
        return Err("Updater cache directory must be absolute".into());
    }
    Ok(root.join("fillr/updates"))
}
fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--version") {
        println!("{}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    let command = args.first().map(String::as_str).unwrap_or("check");
    if ![
        "check",
        "check-auto",
        "download",
        "install-appimage",
        "enable",
        "disable",
    ]
    .contains(&command)
    {
        return Err("Unknown updater command".into());
    }
    let directory = cache_directory()?;
    fs::create_dir_all(&directory)?;
    let state_path = directory.join("state.json");
    // Serialize operations with the shared client's OS-lock strategy; crash-safe release.
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(directory.join("operation.lock"))?;
    fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "Another update is running")?;
    let mut state = CheckState::load(&state_path)?;
    if command == "enable" || command == "disable" {
        state.disabled = command == "disable";
        state.save(&state_path)?;
        println!("{}", serde_json::json!({"disabled":state.disabled}));
        return Ok(());
    }
    let trust: serde_json::Value = serde_json::from_str(TRUST)?;
    let (os_version, glibc_version) = fillr_update_policy::host_versions()?;
    let config = Config {
        app_id: trust["app_id"]
            .as_str()
            .ok_or("Missing app identity")?
            .into(),
        repository: trust["repository"]
            .as_str()
            .ok_or("Missing repository")?
            .into(),
        version: env!("CARGO_PKG_VERSION").into(),
        platform: std::env::consts::OS.into(),
        architecture: std::env::consts::ARCH.into(),
        os_version,
        glibc_version,
        keys: serde_json::from_value(trust["keys"].clone())?,
        identity: trust["identities"][std::env::consts::OS]
            .as_str()
            .ok_or("Unsupported platform")?
            .into(),
    };
    config.validate()?;
    let now = chrono::Utc::now().timestamp();
    if !state.due(now as u64, command != "check-auto") {
        println!(
            "{}",
            serde_json::json!({"status":"deferred","available":false})
        );
        return Ok(());
    }
    state.last_attempt = now as u64;
    state.save(&state_path)?;
    let client = GitHub::new()?;
    let raw = client.metadata(&config)?;
    let update = fillr_update_policy::discover(&raw, &config, now, state.highest_seen.as_deref())?;
    state.last_success = now as u64;
    if let Some(update) = &update {
        state.highest_seen = Some(update.manifest().version.clone());
    }
    state.save(&state_path)?;
    let Some(update) = update else {
        println!(
            "{}",
            serde_json::json!({"status":"current","available":false})
        );
        return Ok(());
    };
    if command == "check" || command == "check-auto" {
        println!(
            "{}",
            serde_json::json!({"status":"available","available":true,"version":update.manifest().version,"notes_url":update.manifest().release_notes_url})
        );
        return Ok(());
    }
    if args.get(1) != Some(&update.manifest().version) {
        return Err("Update changed since confirmation; check again before installing".into());
    }
    if command == "install-appimage" {
        #[cfg(target_os = "linux")]
        {
            let target = PathBuf::from(std::env::var_os("APPIMAGE").ok_or(
                "Run the installed AppImage, or download and install manually from GitHub Releases",
            )?);
            let appdir = PathBuf::from(
                std::env::var_os("APPDIR").ok_or("Missing AppImage runtime directory")?,
            );
            if std::env::current_exe()?.canonicalize()?
                != appdir.join("usr/bin/fillr-update").canonicalize()?
            {
                return Err("Updater is not running from the current AppImage".into());
            }
            require_appimage(&target)?;
            let parent = target.parent().ok_or("Missing AppImage parent")?;
            let staged = client.download(&update, parent)?;
            require_appimage(staged.path())?;
            let backup = fillr_update_policy::install_appimage(staged, &target, &target)?;
            println!(
                "{}",
                serde_json::json!({"status":"installed","version":update.manifest().version,"backup":backup,"restart_required":true})
            );
            return Ok(());
        }
        #[cfg(not(target_os = "linux"))]
        return Err("AppImage installation is only supported on Linux".into());
    }
    let private = tempfile::Builder::new()
        .prefix("download-")
        .tempdir_in(&directory)?;
    let staged = client.download(&update, private.path())?;
    let path = staged.save(&private.path().join(&update.asset().filename))?;
    let _ = private.keep();
    // Native Windows adapter must also verify WinTrust and the expected MSIX identity.
    println!(
        "{}",
        serde_json::json!({"status":"downloaded","path":path,"version":update.manifest().version,"sha256":update.asset().sha256,"identity":update.asset().identity})
    );
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        println!(
            "{}",
            serde_json::json!({"status":"error","message":error.to_string()})
        );
        std::process::exit(1);
    }
}

#[cfg(any(target_os = "linux", test))]
fn require_appimage(path: &std::path::Path) -> Result<()> {
    use std::io::Read;
    let mut header = [0u8; 20];
    fs::File::open(path)?.read_exact(&mut header)?;
    let machine = if cfg!(target_arch = "aarch64") {
        183
    } else {
        62
    };
    if &header[..4] != b"\x7fELF"
        || &header[8..11] != b"AI\x02"
        || header[4] != 2
        || header[5] != 1
        || header[6] != 1
        || ![2, 3].contains(&u16::from_le_bytes([header[16], header[17]]))
        || u16::from_le_bytes([header[18], header[19]]) != machine
    {
        return Err("Expected a type-2 AppImage; installation was not changed".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cache_must_be_absolute() {
        for value in ["", "relative", "."] {
            assert!(validated_cache_directory(PathBuf::from(value)).is_err());
        }
        let temp = tempfile::tempdir().unwrap();
        assert_eq!(
            validated_cache_directory(temp.path().into()).unwrap(),
            temp.path().join("fillr/updates")
        );
    }
    #[test]
    fn actual_appimage_architecture_and_complete_header_are_required() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("image");
        let mut header = [0u8; 20];
        header[..7].copy_from_slice(b"\x7fELF\x02\x01\x01");
        header[8..11].copy_from_slice(b"AI\x02");
        header[16] = 2;
        header[18] = if cfg!(target_arch = "aarch64") {
            183
        } else {
            62
        };
        fs::write(&path, header).unwrap();
        assert!(require_appimage(&path).is_ok());
        for (offset, value) in [(4, 1), (5, 2), (6, 0), (18, 0)] {
            let mut wrong = header;
            wrong[offset] = value;
            fs::write(&path, wrong).unwrap();
            assert!(require_appimage(&path).is_err());
        }
        fs::write(&path, &header[..19]).unwrap();
        assert!(require_appimage(&path).is_err());
    }
}
