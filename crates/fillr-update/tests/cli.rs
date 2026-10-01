use std::{fs, process::Command};

fn helper(cache: &std::path::Path, command: &str) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_fillr-update"))
        .env("LOCALAPPDATA", cache)
        .env("XDG_CACHE_HOME", cache)
        .arg(command)
        .output()
        .unwrap()
}
#[test]
fn version_matches_packaged_version_without_creating_state() {
    let temp = tempfile::tempdir().unwrap();
    let result = helper(temp.path(), "--version");
    assert!(result.status.success());
    assert_eq!(
        String::from_utf8(result.stdout).unwrap().trim(),
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 0);
}
#[test]
fn unknown_command_does_not_create_state() {
    let temp = tempfile::tempdir().unwrap();
    assert!(!helper(temp.path(), "unknown-operation").status.success());
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 0);
}
#[test]
fn relative_cache_is_rejected_by_real_helper() {
    let result = helper(std::path::Path::new("relative-cache"), "check");
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("must be absolute"));
}
#[test]
fn concurrent_helper_operation_is_rejected_without_changing_state() {
    let temp = tempfile::tempdir().unwrap();
    let directory = temp.path().join("fillr/updates");
    fs::create_dir_all(&directory).unwrap();
    let lock = fs::File::create(directory.join("operation.lock")).unwrap();
    fs2::FileExt::lock_exclusive(&lock).unwrap();
    let result = helper(temp.path(), "check");
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("Another update"));
    assert!(!directory.join("state.json").exists());
}
