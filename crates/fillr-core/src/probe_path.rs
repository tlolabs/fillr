use std::path::{Path, PathBuf};

/// Locate the probe installed in the same application package as FILLR.
pub fn owned_ffprobe_path() -> Result<PathBuf, String> {
    let executable = std::env::current_exe()
        .map_err(|error| format!("Unable to locate FILLR executable: {error}"))?;
    owned_ffprobe_for(&executable)
}

/// The same lookup with an explicit app executable, for package verification.
pub fn owned_ffprobe_for(executable: &Path) -> Result<PathBuf, String> {
    let directory = executable
        .parent()
        .ok_or("FILLR executable has no parent directory")?;
    #[cfg(target_os = "macos")]
    let probe = {
        let contents = directory
            .parent()
            .ok_or("FILLR app bundle has no Contents directory")?;
        if directory.file_name().is_none_or(|name| name != "MacOS")
            || contents.file_name().is_none_or(|name| name != "Contents")
        {
            return Err("FILLR must run from its .app bundle to locate its owned FFprobe".into());
        }
        contents.join("Resources/ffprobe")
    };
    #[cfg(target_os = "windows")]
    let probe = directory.join("ffprobe.exe");
    #[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
    let probe = directory.join("ffprobe");

    if !probe.is_file() {
        return Err(format!(
            "FILLR-owned FFprobe is missing at {}. Rebuild or reinstall FILLR; no system FFprobe will be used.",
            probe.display()
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if probe
            .metadata()
            .map_err(|error| error.to_string())?
            .permissions()
            .mode()
            & 0o111
            == 0
        {
            return Err(format!(
                "FILLR-owned FFprobe is not executable at {}",
                probe.display()
            ));
        }
    }
    Ok(probe)
}

/// The inspection CLI uses a build artifact created by this repository.
pub fn staged_ffprobe_path() -> Result<PathBuf, String> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    #[cfg(target_os = "macos")]
    let probe = root.join("dist/ffprobe-universal");
    #[cfg(target_os = "windows")]
    let probe = root.join("dist/ffprobe-windows/ffprobe.exe");
    #[cfg(target_os = "linux")]
    let probe = root.join(format!(
        "dist/ffprobe-linux-{}/ffprobe",
        std::env::consts::ARCH
    ));
    if probe.is_file() {
        Ok(probe)
    } else {
        Err(format!(
            "FILLR-owned FFprobe is missing at {}. Run the platform build_ffprobe script first.",
            probe.display()
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_owned_probe_never_falls_back_to_path() {
        let missing = std::env::temp_dir().join("fillr-probe-location-test");
        #[cfg(target_os = "macos")]
        let executable = missing.join("FILLR.app/Contents/MacOS/FILLR");
        #[cfg(not(target_os = "macos"))]
        let executable = missing.join("FILLR");
        let error = owned_ffprobe_for(&executable).unwrap_err();
        assert!(error.contains("FILLR-owned FFprobe is missing"));
        assert!(error.contains("no system FFprobe will be used"));
    }
}
