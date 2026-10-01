//! Shared release-side signer/verifier. Never logs signing keys.
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use fillr_update_policy::*;
use ring::signature::{Ed25519KeyPair, KeyPair};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs, path::Path};
fn verify(raw: &[u8], assets: &Path, trust: &serde_json::Value) -> Result<()> {
    if raw.len() as u64 > MAX_METADATA {
        return Err("Oversized release metadata".into());
    }
    let envelope: Envelope = serde_json::from_slice(raw)?;
    // Parsing here discovers target names only. Every field is authenticated by discover below.
    let manifest: Manifest = serde_json::from_slice(&B64.decode(&envelope.payload)?)?;
    if manifest.assets.is_empty() {
        return Err("No release artifacts".into());
    }
    let keys: BTreeMap<String, String> = serde_json::from_value(trust["keys"].clone())?;
    for asset in &manifest.assets {
        let config = Config {
            app_id: trust["app_id"].as_str().ok_or("Missing app ID")?.into(),
            repository: trust["repository"]
                .as_str()
                .ok_or("Missing repository")?
                .into(),
            version: "0.0.0".into(),
            platform: asset.platform.clone(),
            architecture: if asset.architecture == "universal" {
                "aarch64".into()
            } else {
                asset.architecture.clone()
            },
            os_version: "999.999.999".into(),
            glibc_version: (asset.platform == "linux").then(|| "999.999.999".into()),
            keys: keys.clone(),
            identity: trust["identities"][&asset.platform]
                .as_str()
                .ok_or("Missing platform identity")?
                .into(),
        };
        let update = discover(raw, &config, chrono::Utc::now().timestamp(), None)?
            .ok_or("Release is not eligible for stable updates")?;
        let staging = tempfile::tempdir()?;
        update.stage(
            fs::File::open(assets.join(&update.asset().filename))?,
            staging.path(),
        )?;
    }
    if manifest.assets.iter().any(|a| a.platform == "macos") {
        let expected = manifest
            .appcast_sha256
            .as_deref()
            .ok_or("Missing authenticated Sparkle feed digest")?;
        let feed = fs::read(assets.join("appcast.xml"))?;
        if feed.len() as u64 > MAX_METADATA || format!("{:x}", Sha256::digest(&feed)) != expected {
            return Err("Sparkle feed differs from authenticated release manifest".into());
        }
    }
    Ok(())
}
fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 4 {
        return Err("usage: tlo-update-release <sign|verify|fetch> <manifest> <asset-dir> <trust.json> [key-id]".into());
    }
    let path = Path::new(&args[1]);
    let assets = Path::new(&args[2]);
    let trust: serde_json::Value = serde_json::from_slice(&fs::read(&args[3])?)?;
    if args[0] == "sign" {
        let key_id = args.get(4).ok_or("Signing key ID required")?;
        let seed = B64.decode(std::env::var("TLO_UPDATE_PRIVATE_KEY")?)?;
        if seed.len() != 32 {
            return Err("Signing seed must be 32 bytes".into());
        }
        let key = Ed25519KeyPair::from_seed_unchecked(&seed).map_err(|_| "Invalid Ed25519 key")?;
        let expected = trust["keys"][key_id]
            .as_str()
            .ok_or("Key ID is not pinned in installed trust configuration")?;
        if B64.decode(expected)? != key.public_key().as_ref() {
            return Err("Signing key does not match pinned public key".into());
        }
        let payload = fs::read(path)?;
        let envelope = Envelope {
            key_id: key_id.clone(),
            payload: B64.encode(&payload),
            signature: B64.encode(key.sign(&payload)),
        };
        let raw = serde_json::to_vec_pretty(&envelope)?;
        verify(&raw, assets, &trust)?;
        fs::write(assets.join("update-manifest.json"), raw)?;
    } else if args[0] == "verify" {
        verify(&fs::read(path)?, assets, &trust)?;
    } else if args[0] == "fetch" {
        // Post-publication qualification uses the actual production transport and verifier.
        // Argument 1 contains installed-client Config, with an older application version.
        let config: Config = serde_json::from_slice(&fs::read(path)?)?;
        if Some(config.identity.as_str()) != trust["identities"][&config.platform].as_str()
            || config.app_id != trust["app_id"].as_str().ok_or("Missing app ID")?
            || config.repository != trust["repository"].as_str().ok_or("Missing repo")?
            || config.keys
                != serde_json::from_value::<BTreeMap<String, String>>(trust["keys"].clone())?
        {
            return Err("Qualification trust mismatch".into());
        }
        let github = GitHub::new()?;
        let raw = github.metadata(&config)?;
        let update = discover(&raw, &config, chrono::Utc::now().timestamp(), None)?
            .ok_or("No newer compatible published update")?;
        fs::create_dir_all(assets)?;
        let stage = github.download(&update, assets)?;
        stage.save(&assets.join(&update.asset().filename))?;
        fs::write(assets.join("update-manifest.json"), raw)?;
    } else {
        return Err("Unknown release command".into());
    }
    println!(
        "Authenticated metadata and artifact verification passed; installation is not qualified by this check."
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("Release verification failed: {e}");
        std::process::exit(1);
    }
}
