use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use fillr_update_policy::*;
use ring::signature::{Ed25519KeyPair, KeyPair};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    io::{self, Read},
};
const NOW: i64 = 1790812800;
fn fixture() -> (Config, Manifest) {
    let key = Ed25519KeyPair::from_seed_unchecked(&[7; 32]).unwrap();
    let config = Config {
        app_id: "org.tlo.test".into(),
        repository: "tlolabs/test".into(),
        version: "1.9.0".into(),
        platform: "linux".into(),
        architecture: "x86_64".into(),
        os_version: "6.8.0".into(),
        glibc_version: Some("2.39.0".into()),
        keys: BTreeMap::from([("test".into(), B64.encode(key.public_key()))]),
        identity: "org.tlo.test".into(),
    };
    let manifest = Manifest {
        schema: 2,
        app_id: config.app_id.clone(),
        repository: config.repository.clone(),
        version: "1.10.0".into(),
        tag: "v1.10.0".into(),
        channel: "stable".into(),
        draft: false,
        prerelease: false,
        published_at: "2026-09-30T00:00:00Z".into(),
        expires_at: "2026-12-30T00:00:00Z".into(),
        appcast_sha256: None,
        release_notes_url: "https://github.com/tlolabs/test/releases/tag/v1.10.0".into(),
        restart_required: true,
        migration: "none".into(),
        assets: vec![Asset {
            platform: "linux".into(),
            architecture: "x86_64".into(),
            minimum_os: "0.0.0".into(),
            minimum_glibc: Some("2.39.0".into()),
            filename: "test.AppImage".into(),
            url: "https://github.com/tlolabs/test/releases/download/v1.10.0/test.AppImage".into(),
            size: 4,
            sha256: format!("{:x}", Sha256::digest(b"good")),
            format: "AppImage".into(),
            identity: config.identity.clone(),
        }],
    };
    (config, manifest)
}
fn sign(m: &Manifest) -> Vec<u8> {
    let key = Ed25519KeyPair::from_seed_unchecked(&[7; 32]).unwrap();
    let payload = serde_json::to_vec(m).unwrap();
    serde_json::to_vec(&Envelope {
        key_id: "test".into(),
        payload: B64.encode(&payload),
        signature: B64.encode(key.sign(&payload)),
    })
    .unwrap()
}
#[test]
fn newer_uses_semver_not_lexical_comparison() {
    let (c, m) = fixture();
    assert!(discover(&sign(&m), &c, NOW, None).unwrap().is_some());
}
#[test]
fn same_and_older_never_update() {
    let (mut c, m) = fixture();
    for v in ["1.10.0", "2.0.0"] {
        c.version = v.into();
        assert!(discover(&sign(&m), &c, NOW, None).unwrap().is_none());
    }
}
#[test]
fn no_platform_update() {
    let (c, mut m) = fixture();
    m.assets[0].architecture = "aarch64".into();
    assert!(discover(&sign(&m), &c, NOW, None).unwrap().is_none());
}
#[test]
fn drafts_prereleases_and_nightlies_are_rejected() {
    let (c, m) = fixture();
    for mode in 0..4 {
        let mut m = m.clone();
        match mode {
            0 => m.draft = true,
            1 => m.prerelease = true,
            2 => m.version = "2.0.0-beta.1".into(),
            _ => m.channel = "nightly".into(),
        };
        assert!(discover(&sign(&m), &c, NOW, None).is_err());
    }
}
#[test]
fn malformed_versions_rejected() {
    let (c, m) = fixture();
    for v in ["01.2.3", "1.2", "hello", "1.2.3+build"] {
        let mut m = m.clone();
        m.version = v.into();
        assert!(discover(&sign(&m), &c, NOW, None).is_err());
    }
}
#[test]
fn wrong_platform_architecture_and_os_are_ineligible() {
    let (mut c, m) = fixture();
    c.platform = "windows".into();
    assert!(discover(&sign(&m), &c, NOW, None).unwrap().is_none());
    c.platform = "linux".into();
    c.architecture = "aarch64".into();
    assert!(discover(&sign(&m), &c, NOW, None).unwrap().is_none());
    c.architecture = "x86_64".into();
    c.glibc_version = Some("2.38.0".into());
    assert!(discover(&sign(&m), &c, NOW, None).unwrap().is_none());
}
#[test]
fn wrong_app_repository_identity_and_tag_rejected() {
    let (c, m) = fixture();
    for i in 0..4 {
        let mut m = m.clone();
        match i {
            0 => m.app_id = "other.app".into(),
            1 => m.repository = "other/repo".into(),
            2 => m.assets[0].identity = "other.publisher".into(),
            _ => m.tag = "v2.0.0".into(),
        };
        assert!(discover(&sign(&m), &c, NOW, None).is_err());
    }
}
#[test]
fn invalid_signature_and_unknown_key_rejected() {
    let (c, m) = fixture();
    let mut e: Envelope = serde_json::from_slice(&sign(&m)).unwrap();
    e.signature = B64.encode([0; 64]);
    assert!(discover(&serde_json::to_vec(&e).unwrap(), &c, NOW, None).is_err());
    e.key_id = "attacker".into();
    assert!(discover(&serde_json::to_vec(&e).unwrap(), &c, NOW, None).is_err());
}
#[test]
fn attacker_cannot_replace_payload_and_checksum() {
    let (c, m) = fixture();
    let mut e: Envelope = serde_json::from_slice(&sign(&m)).unwrap();
    let mut changed = m;
    changed.assets[0].sha256 = "0".repeat(64);
    e.payload = B64.encode(serde_json::to_vec(&changed).unwrap());
    assert!(discover(&serde_json::to_vec(&e).unwrap(), &c, NOW, None).is_err());
}
#[test]
fn missing_trust_fails_closed() {
    let (mut c, m) = fixture();
    c.keys.clear();
    assert!(discover(&sign(&m), &c, NOW, None).is_err());
}
#[test]
fn expiry_and_replay_rejected() {
    let (c, mut m) = fixture();
    assert!(discover(&sign(&m), &c, NOW, Some("1.11.0")).is_err());
    m.expires_at = m.published_at.clone();
    assert!(discover(&sign(&m), &c, NOW, None).is_err());
}
#[test]
fn invalid_assets_rejected() {
    let (c, m) = fixture();
    for i in 0..7 {
        let mut m = m.clone();
        match i {
            0 => m.assets[0].filename = "../test.AppImage".into(),
            1 => m.assets[0].url = "https://evil.test/test.AppImage".into(),
            2 => m.assets[0].size = 0,
            3 => m.assets[0].sha256 = "f".repeat(63),
            4 => m.assets[0].architecture = "universal".into(),
            5 => m.assets[0].format = "zip".into(),
            _ => m.migration = "destructive".into(),
        };
        assert!(discover(&sign(&m), &c, NOW, None).is_err());
    }
}
#[test]
fn corruption_truncation_overflow_and_checksum_mismatch_leave_no_staging_files() {
    let (c, m) = fixture();
    let update = discover(&sign(&m), &c, NOW, None).unwrap().unwrap();
    let dir = tempfile::tempdir().unwrap();
    for bytes in [b"bad!".as_slice(), b"goo", b"goodextra"] {
        assert!(update.stage(bytes, dir.path()).is_err());
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
    }
    let mut m = m;
    m.assets[0].sha256 = "0".repeat(64);
    let update = discover(&sign(&m), &c, NOW, None).unwrap().unwrap();
    assert!(update.stage(b"good".as_slice(), dir.path()).is_err());
}
struct Interrupted;
impl Read for Interrupted {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        Err(io::Error::new(
            io::ErrorKind::ConnectionReset,
            "interrupted",
        ))
    }
}
#[test]
fn interrupted_download_is_never_installable() {
    let (c, m) = fixture();
    let update = discover(&sign(&m), &c, NOW, None).unwrap().unwrap();
    let dir = tempfile::tempdir().unwrap();
    assert!(update.stage(Interrupted, dir.path()).is_err());
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
}
#[test]
fn scheduling_preserves_success_time_and_backs_off_failures() {
    let mut s = CheckState::default();
    assert!(s.due(10000, false));
    s.last_attempt = 10000;
    assert!(!s.due(10001, false));
    assert!(s.due(13600, false));
    s.last_success = 10000;
    assert!(!s.due(96399, false));
    assert!(s.due(96400, false));
    s.disabled = true;
    assert!(!s.due(200000, false));
    assert!(s.due(200000, true));
    assert!(!s.due(9999, false));
}
#[test]
fn cache_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("state.json");
    let mut s = CheckState::load(&p).unwrap();
    s.highest_seen = Some("1.10.0".into());
    s.save(&p).unwrap();
    assert_eq!(CheckState::load(&p).unwrap().highest_seen, s.highest_seen);
}
#[cfg(unix)]
#[test]
fn atomic_install_keeps_previous_and_handles_interruption_before_commit() {
    let (c, m) = fixture();
    let update = discover(&sign(&m), &c, NOW, None).unwrap().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("test.AppImage");
    fs::write(&target, b"previous").unwrap();
    {
        let _aborted = update.stage(b"good".as_slice(), dir.path()).unwrap();
    }
    assert_eq!(fs::read(&target).unwrap(), b"previous");
    let stage = update.stage(b"good".as_slice(), dir.path()).unwrap();
    let backup = install_appimage(stage, &target, &target).unwrap();
    assert_eq!(fs::read(&target).unwrap(), b"good");
    assert_eq!(fs::read(backup).unwrap(), b"previous");
}
#[cfg(unix)]
#[test]
fn tampered_stage_and_symlink_install_are_rejected() {
    let (c, m) = fixture();
    let update = discover(&sign(&m), &c, NOW, None).unwrap().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("test.AppImage");
    fs::write(&target, b"old").unwrap();
    let stage = update.stage(b"good".as_slice(), dir.path()).unwrap();
    fs::write(stage.path(), b"evil").unwrap();
    assert!(install_appimage(stage, &target, &target).is_err());
    assert_eq!(fs::read(&target).unwrap(), b"old");
    let link = dir.path().join("link.AppImage");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    let stage = update.stage(b"good".as_slice(), dir.path()).unwrap();
    assert!(install_appimage(stage, &link, &link).is_err());
}
#[test]
fn oversized_metadata_rejected() {
    let (c, _) = fixture();
    assert!(discover(&vec![b' '; MAX_METADATA as usize + 1], &c, NOW, None).is_err());
}

#[test]
fn local_mock_release_end_to_end_and_outage() {
    use std::{io::Write, net::TcpListener, thread};
    let (config, manifest) = fixture();
    let metadata = sign(&manifest);
    let server = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = server.local_addr().unwrap();
    let worker = thread::spawn(move || {
        for body in [metadata, b"good".to_vec()] {
            let (mut stream, _) = server.accept().unwrap();
            let mut request = [0; 4096];
            let _ = stream.read(&mut request).unwrap();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            )
            .unwrap();
            stream.write_all(&body).unwrap();
        }
    });
    // Only the test transport uses localhost. Production exposes no URL or key override.
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(3))
        .build()
        .unwrap();
    let raw = bounded_read(
        client
            .get(format!("http://{address}/manifest"))
            .send()
            .unwrap()
            .error_for_status()
            .unwrap(),
        MAX_METADATA,
    )
    .unwrap();
    let update = discover(&raw, &config, NOW, None).unwrap().unwrap();
    let directory = tempfile::tempdir().unwrap();
    let download = client
        .get(format!("http://{address}/artifact"))
        .send()
        .unwrap()
        .error_for_status()
        .unwrap();
    let staged = update.stage(download, directory.path()).unwrap();
    assert_eq!(fs::read(staged.path()).unwrap(), b"good");
    worker.join().unwrap();
    assert!(
        client
            .get(format!("http://{address}/unavailable"))
            .send()
            .is_err()
    );
}
#[test]
fn release_cli_sign_verify_and_manifest_artifact_mismatch() {
    use std::process::Command;
    let (config, manifest) = fixture();
    let directory = tempfile::tempdir().unwrap();
    let p = directory.path();
    fs::write(p.join("test.AppImage"), b"good").unwrap();
    fs::write(
        p.join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    fs::write(p.join("trust.json"),serde_json::to_vec(&serde_json::json!({"app_id":config.app_id,"repository":config.repository,"keys":config.keys,"identities":{"linux":config.identity}})).unwrap()).unwrap();
    let cli = env!("CARGO_BIN_EXE_tlo-update-release");
    // Extend fixture expiry only for release-side wall-clock validation; never weaken verification.
    let mut current = manifest;
    current.published_at = chrono::Utc::now().to_rfc3339();
    current.expires_at = (chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339();
    fs::write(
        p.join("manifest.json"),
        serde_json::to_vec(&current).unwrap(),
    )
    .unwrap();
    let signed = Command::new(cli)
        .arg("sign")
        .arg(p.join("manifest.json"))
        .arg(p)
        .arg(p.join("trust.json"))
        .arg("test")
        .env("TLO_UPDATE_PRIVATE_KEY", B64.encode([7; 32]))
        .output()
        .unwrap();
    assert!(
        signed.status.success(),
        "{}",
        String::from_utf8_lossy(&signed.stderr)
    );
    let verify = || {
        Command::new(cli)
            .arg("verify")
            .arg(p.join("update-manifest.json"))
            .arg(p)
            .arg(p.join("trust.json"))
            .output()
            .unwrap()
    };
    assert!(verify().status.success());
    fs::write(p.join("test.AppImage"), b"evil").unwrap();
    assert!(!verify().status.success());
}

#[test]
fn shared_target_extensions_support_universal_mac_and_msix() {
    for (platform, arch, format, os, filename) in [
        ("macos", "universal", "zip", "13.0.0", "test.zip"),
        ("windows", "x86_64", "msix", "10.0.19041", "test.msix"),
        ("windows", "aarch64", "msix", "10.0.19041", "test.msix"),
    ] {
        let (mut config, mut manifest) = fixture();
        config.platform = platform.into();
        config.architecture = if arch == "universal" {
            "aarch64".into()
        } else {
            arch.into()
        };
        config.os_version = os.into();
        let asset = &mut manifest.assets[0];
        asset.platform = platform.into();
        asset.architecture = arch.into();
        asset.format = format.into();
        asset.minimum_os = os.into();
        asset.minimum_glibc = None;
        asset.filename = filename.into();
        asset.url = format!("https://github.com/tlolabs/test/releases/download/v1.10.0/{filename}");
        assert!(
            discover(&sign(&manifest), &config, NOW, None)
                .unwrap()
                .is_some()
        );
        if arch == "universal" {
            config.architecture = "x86_64".into();
            assert!(
                discover(&sign(&manifest), &config, NOW, None)
                    .unwrap()
                    .is_some()
            );
        }
    }
}

#[test]
fn linux_kernel_and_glibc_floors_are_independent() {
    let (mut config, mut manifest) = fixture();
    manifest.assets[0].minimum_os = "6.9.0".into();
    assert!(
        discover(&sign(&manifest), &config, NOW, None)
            .unwrap()
            .is_none()
    );
    config.os_version = "6.9.0".into();
    assert!(
        discover(&sign(&manifest), &config, NOW, None)
            .unwrap()
            .is_some()
    );
    config.glibc_version = Some("2.38.0".into());
    assert!(
        discover(&sign(&manifest), &config, NOW, None)
            .unwrap()
            .is_none()
    );
    config.glibc_version = None;
    assert!(discover(&sign(&manifest), &config, NOW, None).is_err());
}
#[test]
fn partial_download_failure_is_cleaned_and_retry_succeeds() {
    let (config, manifest) = fixture();
    let update = discover(&sign(&manifest), &config, NOW, None)
        .unwrap()
        .unwrap();
    let temp = tempfile::tempdir().unwrap();
    let interrupted = io::Cursor::new(b"go").chain(Interrupted);
    assert!(update.stage(interrupted, temp.path()).is_err());
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 0);
    let retry = update.stage(b"good".as_slice(), temp.path()).unwrap();
    assert_eq!(fs::read(retry.path()).unwrap(), b"good");
}
#[test]
fn persistence_failure_preserves_existing_destination() {
    let (config, manifest) = fixture();
    let update = discover(&sign(&manifest), &config, NOW, None)
        .unwrap()
        .unwrap();
    let temp = tempfile::tempdir().unwrap();
    let destination = temp.path().join("existing");
    fs::write(&destination, b"old image").unwrap();
    assert!(
        update
            .stage(b"good".as_slice(), temp.path())
            .unwrap()
            .save(&destination)
            .is_err()
    );
    assert_eq!(fs::read(destination).unwrap(), b"old image");
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 1);
}

#[test]
fn malformed_manifest_payload_is_rejected_after_authentication() {
    let (config, _) = fixture();
    let key = Ed25519KeyPair::from_seed_unchecked(&[7; 32]).unwrap();
    for payload in [b"{".as_slice(), b"[]", b"{}"] {
        let envelope = Envelope {
            key_id: "test".into(),
            payload: B64.encode(payload),
            signature: B64.encode(key.sign(payload)),
        };
        assert!(discover(&serde_json::to_vec(&envelope).unwrap(), &config, NOW, None).is_err());
    }
}
#[test]
fn release_verifier_binds_the_sparkle_feed_bytes() {
    let (config, mut manifest) = fixture();
    manifest.published_at = chrono::Utc::now().to_rfc3339();
    manifest.expires_at = (chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339();
    let asset = &mut manifest.assets[0];
    asset.platform = "macos".into();
    asset.architecture = "universal".into();
    asset.format = "zip".into();
    asset.minimum_os = "13.0.0".into();
    asset.minimum_glibc = None;
    asset.filename = "test.zip".into();
    asset.url = "https://github.com/tlolabs/test/releases/download/v1.10.0/test.zip".into();
    manifest.appcast_sha256 = Some(format!("{:x}", Sha256::digest(b"signed feed fixture")));
    let temp = tempfile::tempdir().unwrap();
    let p = temp.path();
    fs::write(p.join("test.zip"), b"good").unwrap();
    fs::write(p.join("appcast.xml"), b"signed feed fixture").unwrap();
    fs::write(p.join("update-manifest.json"), sign(&manifest)).unwrap();
    fs::write(p.join("trust.json"), serde_json::to_vec(&serde_json::json!({"app_id":config.app_id,"repository":config.repository,"keys":config.keys,"identities":{"macos":config.identity}})).unwrap()).unwrap();
    let verify = || {
        std::process::Command::new(env!("CARGO_BIN_EXE_tlo-update-release"))
            .arg("verify")
            .arg(p.join("update-manifest.json"))
            .arg(p)
            .arg(p.join("trust.json"))
            .output()
            .unwrap()
            .status
            .success()
    };
    assert!(verify());
    fs::write(p.join("appcast.xml"), b"substituted feed").unwrap();
    assert!(!verify());
}
