//! Verify an installed FILLR package with the same lookup and probe used by the app.
use fillr_core::{VideoProbe, owned_ffprobe_for};
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let app = PathBuf::from(
        arguments
            .next()
            .ok_or("Usage: fillr-probe-smoke APP_EXECUTABLE MPG MP4")?,
    );
    let mpg = PathBuf::from(arguments.next().ok_or("Missing MPG fixture")?);
    let mp4 = PathBuf::from(arguments.next().ok_or("Missing MP4 fixture")?);
    if arguments.next().is_some() {
        return Err("Too many arguments".into());
    }
    let probe = VideoProbe::new(owned_ffprobe_for(&app.canonicalize()?)?);
    for (file, codec, format, minimum_ms) in [
        (mpg, "mpeg2video", "mpeg", 500),
        (mp4, "h264", "mov,mp4", 900),
    ] {
        let info = probe.media_info(&file)?;
        if info.codec_name != codec
            || !info.format_name.starts_with(format)
            || info.width != 64
            || info.height != 48
            || info.duration_ms.unwrap_or(0) < minimum_ms
        {
            return Err(format!(
                "Unexpected FFprobe result for {}: {} {} {}x{} {:?}",
                file.display(),
                info.codec_name,
                info.format_name,
                info.width,
                info.height,
                info.duration_ms
            )
            .into());
        }
        println!(
            "{}: {} {} {} ms",
            file.display(),
            info.format_name,
            info.codec_name,
            info.duration_ms.unwrap()
        );
    }
    Ok(())
}
