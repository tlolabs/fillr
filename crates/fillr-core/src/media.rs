use crate::probe::MediaInfo;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TelevisionStandard {
    Any,
    #[default]
    Ntsc,
    Pal,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanType {
    Any,
    #[default]
    Interlaced,
    Progressive,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Orientation {
    Any,
    #[default]
    Horizontal,
    Vertical,
}

/// An editable preference. Empty lists and None mean "allow any" for that field.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MediaPolicy {
    pub enabled: bool,
    pub delete_rejected: bool,
    pub allowed_extensions: Vec<String>,
    pub allowed_containers: Vec<String>,
    pub allowed_codecs: Vec<String>,
    pub required_width: Option<u32>,
    pub required_height: Option<u32>,
    pub television_standard: TelevisionStandard,
    pub frame_rate: Option<String>,
    pub scan_type: ScanType,
    pub orientation: Orientation,
    pub display_aspect_ratio: Option<String>,
}

impl Default for MediaPolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            delete_rejected: true,
            allowed_extensions: vec!["mpg".into()],
            allowed_containers: vec!["mpeg".into()],
            allowed_codecs: vec!["mpeg2video".into()],
            required_width: Some(1920),
            required_height: Some(1080),
            television_standard: TelevisionStandard::Ntsc,
            frame_rate: Some("30000/1001".into()),
            scan_type: ScanType::Interlaced,
            orientation: Orientation::Horizontal,
            display_aspect_ratio: Some("16:9".into()),
        }
    }
}

/// Canonical grammar for ratio or positive decimal values (e.g. frame rates and aspect ratios):
/// - Positive whole integer: "25", "30", "60"
/// - Positive decimal fraction: "29.97", "23.976", "1.7778"
/// - Positive rational fraction with '/' or ':': "30000/1001", "16:9", "4/3"
///
/// Operands must be positive, finite numbers. Zero, negative values, nonfinite numbers (NaN, Inf),
/// multiple separators, and malformed strings are rejected.
fn parse_positive_decimal(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || !trimmed.bytes().any(|b| b.is_ascii_digit())
        || !trimmed.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        || trimmed.bytes().filter(|&b| b == b'.').count() > 1
    {
        return None;
    }
    let val = trimmed.parse::<f64>().ok()?;
    (val.is_finite() && val > 0.0).then_some(val)
}

pub fn parse_ratio_or_number(value: &str) -> Option<f64> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some((a, b)) = trimmed.split_once(['/', ':']) {
        if b.contains(['/', ':']) {
            return None;
        }
        let num = parse_positive_decimal(a)?;
        let den = parse_positive_decimal(b)?;
        let res = num / den;
        (res.is_finite() && res > 0.0).then_some(res)
    } else {
        parse_positive_decimal(trimmed)
    }
}

fn rational(value: &str) -> Option<f64> {
    parse_ratio_or_number(value)
}

fn near(a: f64, b: f64, tolerance: f64) -> bool {
    (a - b).abs() <= tolerance
}

impl MediaPolicy {
    pub fn validate(&self) -> Result<(), String> {
        if self.required_width == Some(0) || self.required_height == Some(0) {
            return Err("Required dimensions must be greater than zero".into());
        }
        if let Some(rate) = self.frame_rate.as_deref() {
            let trimmed = rate.trim();
            if !trimmed.is_empty() && parse_ratio_or_number(trimmed).is_none() {
                return Err(
                    "Frame rate must be a positive number or ratio (e.g. 30000/1001 or 29.97)"
                        .into(),
                );
            }
        }
        if let Some(aspect) = self.display_aspect_ratio.as_deref() {
            let trimmed = aspect.trim();
            if !trimmed.is_empty() && parse_ratio_or_number(trimmed).is_none() {
                return Err(
                    "Display aspect ratio must be a positive number or ratio (e.g. 16:9 or 1.78)"
                        .into(),
                );
            }
        }
        Ok(())
    }

    pub fn reject_reasons(&self, extension: &str, info: &MediaInfo) -> Vec<String> {
        if !self.enabled {
            return vec![];
        }
        let mut reasons = Vec::new();
        if !self.allowed_extensions.is_empty()
            && !self
                .allowed_extensions
                .iter()
                .any(|x| x.trim_start_matches('.').eq_ignore_ascii_case(extension))
        {
            reasons.push(format!("extension .{extension} is not allowed"));
        }
        if !self.allowed_containers.is_empty()
            && !info.format_name.split(',').any(|actual| {
                self.allowed_containers
                    .iter()
                    .any(|wanted| actual.eq_ignore_ascii_case(wanted))
            })
        {
            reasons.push(format!("container {} is not allowed", info.format_name));
        }
        if !self.allowed_codecs.is_empty()
            && !self
                .allowed_codecs
                .iter()
                .any(|x| x.eq_ignore_ascii_case(&info.codec_name))
        {
            reasons.push(format!("codec {} is not allowed", info.codec_name));
        }
        if self.required_width.is_some_and(|v| info.width != v)
            || self.required_height.is_some_and(|v| info.height != v)
        {
            reasons.push(format!(
                "resolution {}×{} does not match the preference",
                info.width, info.height
            ));
        }
        if self.scan_type != ScanType::Any {
            let interlaced = matches!(info.field_order.as_str(), "tt" | "bb" | "tb" | "bt");
            let progressive = info.field_order == "progressive";
            if (self.scan_type == ScanType::Interlaced && !interlaced)
                || (self.scan_type == ScanType::Progressive && !progressive)
            {
                reasons.push(format!(
                    "scan type {} does not match the preference",
                    info.field_order
                ));
            }
        }
        let mut display_ratio = rational(&info.display_aspect_ratio)
            .or_else(|| {
                rational(&info.sample_aspect_ratio)
                    .map(|sar| info.width as f64 * sar / info.height as f64)
            })
            .or_else(|| (info.height > 0).then_some(info.width as f64 / info.height.max(1) as f64));
        if info.rotation_degrees.is_some_and(|degrees| {
            let quarter_turns = (degrees / 90.0).round();
            near(degrees / 90.0, quarter_turns, 0.05) && (quarter_turns as i64).rem_euclid(2) == 1
        }) {
            display_ratio = display_ratio
                .filter(|ratio| *ratio > 0.0)
                .map(|ratio| 1.0 / ratio);
        }
        if self.orientation != Orientation::Any {
            let correct = display_ratio.is_some_and(|ratio| match self.orientation {
                Orientation::Horizontal => ratio > 1.0,
                Orientation::Vertical => ratio < 1.0,
                Orientation::Any => true,
            });
            if !correct {
                reasons.push(format!("orientation does not match {:?}", self.orientation));
            }
        }
        if let Some(wanted) = self
            .display_aspect_ratio
            .as_deref()
            .filter(|value| !value.trim().is_empty())
            && !display_ratio
                .zip(rational(wanted))
                .is_some_and(|(actual, expected)| near(actual, expected, 0.025))
        {
            reasons.push(format!(
                "display aspect ratio {} does not match {wanted}",
                info.display_aspect_ratio
            ));
        }
        let rate = rational(&info.frame_rate);
        if let Some(wanted) = self
            .frame_rate
            .as_deref()
            .filter(|value| !value.trim().is_empty())
            && !rate
                .zip(rational(wanted))
                .is_some_and(|(actual, expected)| near(actual, expected, 0.03))
        {
            reasons.push(format!(
                "frame rate {} does not match {wanted}",
                info.frame_rate
            ));
        }
        if self.television_standard != TelevisionStandard::Any {
            let is_ntsc =
                rate.is_some_and(|v| [23.976, 29.970, 59.940].iter().any(|n| near(v, *n, 0.03)));
            let is_pal = rate.is_some_and(|v| [25.0, 50.0].iter().any(|n| near(v, *n, 0.03)));
            if (self.television_standard == TelevisionStandard::Ntsc && !is_ntsc)
                || (self.television_standard == TelevisionStandard::Pal && !is_pal)
            {
                reasons.push(format!(
                    "frame rate {} is not {:?}",
                    info.frame_rate, self.television_standard
                ));
            }
        }
        reasons
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> MediaInfo {
        MediaInfo {
            duration_ms: Some(42_000),
            format_name: "mpeg".into(),
            codec_name: "mpeg2video".into(),
            width: 1920,
            height: 1080,
            sample_aspect_ratio: "1:1".into(),
            display_aspect_ratio: "16:9".into(),
            field_order: "tt".into(),
            frame_rate: "30000/1001".into(),
            rotation_degrees: None,
        }
    }

    #[test]
    fn default_accepts_observed_ntsc_hd_interlaced_mpeg() {
        assert!(
            MediaPolicy::default()
                .reject_reasons("mpg", &sample())
                .is_empty()
        );
    }

    #[test]
    fn rejects_sd_anamorphic_and_vertical_and_pal() {
        let policy = MediaPolicy::default();
        let mut sd = sample();
        sd.width = 720;
        sd.height = 480;
        sd.display_aspect_ratio = "16:9".into();
        assert!(
            policy
                .reject_reasons("mpg", &sd)
                .iter()
                .any(|r| r.contains("resolution"))
        );
        let mut vertical = sample();
        vertical.width = 1080;
        vertical.height = 1920;
        vertical.display_aspect_ratio = "9:16".into();
        assert!(
            policy
                .reject_reasons("mp4", &vertical)
                .iter()
                .any(|r| r.contains("orientation"))
        );
        let mut pal = sample();
        pal.frame_rate = "25/1".into();
        assert!(
            policy
                .reject_reasons("mp4", &pal)
                .iter()
                .any(|r| r.contains("Ntsc"))
        );
    }

    #[test]
    fn settings_can_allow_other_profiles() {
        let mut policy = MediaPolicy::default();
        policy.allowed_extensions.clear();
        policy.allowed_containers.clear();
        policy.allowed_codecs.clear();
        policy.required_width = None;
        policy.required_height = None;
        policy.frame_rate = None;
        policy.television_standard = TelevisionStandard::Any;
        policy.scan_type = ScanType::Any;
        policy.orientation = Orientation::Any;
        policy.display_aspect_ratio = None;
        assert!(policy.reject_reasons("mp4", &sample()).is_empty());
    }

    #[test]
    fn valid_blank_optional_preferences_do_not_reject_media() {
        for blank in ["", "   ", "\t\n"] {
            let policy = MediaPolicy {
                frame_rate: Some(blank.into()),
                display_aspect_ratio: Some(blank.into()),
                ..MediaPolicy::default()
            };
            assert!(policy.validate().is_ok());
            assert!(policy.reject_reasons("mpg", &sample()).is_empty());
        }
    }

    #[test]
    fn display_rotation_changes_orientation() {
        let mut rotated = sample();
        rotated.rotation_degrees = Some(90.0);
        assert!(
            MediaPolicy::default()
                .reject_reasons("mpg", &rotated)
                .iter()
                .any(|reason| reason.contains("orientation"))
        );
    }

    #[test]
    fn omitted_optional_fields_mean_any_in_swift_preferences() {
        let mut value = serde_json::to_value(MediaPolicy::default()).unwrap();
        let object = value.as_object_mut().unwrap();
        object.remove("required_width");
        object.remove("required_height");
        object.remove("frame_rate");
        object.remove("display_aspect_ratio");
        let decoded: MediaPolicy = serde_json::from_value(value).unwrap();
        assert!(decoded.required_width.is_none());
        assert!(decoded.required_height.is_none());
        assert!(decoded.frame_rate.is_none());
        assert!(decoded.display_aspect_ratio.is_none());
    }

    #[test]
    fn shared_validation_fixture_table() {
        let cases = [
            ("", true),
            ("   ", true),
            ("25", true),
            ("25.0", true),
            ("30", true),
            ("60", true),
            ("29.97", true),
            ("23.976", true),
            ("1.7778", true),
            ("30000/1001", true),
            ("16/9", true),
            ("16 / 9", true),
            ("4/3", true),
            ("16:9", true),
            ("4:3", true),
            ("0", false),
            ("0.0", false),
            ("0/1", false),
            ("30000/0", false),
            ("-25", false),
            ("+25", false),
            ("-16:9", false),
            ("30000/-1001", false),
            ("nan", false),
            ("inf", false),
            ("-inf", false),
            ("1e5", false),
            ("1e400", false),
            (".", false),
            ("1..2", false),
            ("abc", false),
            ("30000//1001", false),
            ("16:9:4", false),
            ("16/9/4", false),
        ];

        for (input, expected) in cases {
            let policy = MediaPolicy {
                frame_rate: Some(input.to_string()),
                ..MediaPolicy::default()
            };
            assert_eq!(
                policy.validate().is_ok(),
                expected,
                "Failed frame rate validation fixture for: '{input}'"
            );

            let policy_aspect = MediaPolicy {
                display_aspect_ratio: Some(input.to_string()),
                ..MediaPolicy::default()
            };
            assert_eq!(
                policy_aspect.validate().is_ok(),
                expected,
                "Failed aspect ratio validation fixture for: '{input}'"
            );
        }

        // Test dimension boundaries
        let mut policy = MediaPolicy {
            required_width: Some(0),
            ..MediaPolicy::default()
        };
        assert!(policy.validate().is_err());
        policy.required_width = Some(1920);
        policy.required_height = Some(0);
        assert!(policy.validate().is_err());
        policy.required_height = Some(1080);
        assert!(policy.validate().is_ok());
    }
}
