use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SortSettings {
    pub folder_count: usize,
    pub folder_prefix: String,
    pub total_ms: u64,
    pub use_all_clips: bool,
}

impl Default for SortSettings {
    fn default() -> Self {
        Self {
            folder_count: 14,
            folder_prefix: "Comp".into(),
            total_ms: 8_470_000,
            use_all_clips: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_usable_clips_is_enabled_for_defaults_and_saved_legacy_settings() {
        assert!(SortSettings::default().use_all_clips);
        let legacy: SortSettings =
            serde_json::from_str(r#"{"folder_count":3,"folder_prefix":"Scene","total_ms":12000}"#)
                .unwrap();
        assert!(legacy.use_all_clips);
        assert_eq!(legacy.folder_count, 3);
        assert_eq!(legacy.total_ms, 12_000);
    }

    #[test]
    fn explicit_minimum_selection_survives_settings_round_trip() {
        let settings = SortSettings {
            use_all_clips: false,
            ..SortSettings::default()
        };
        let encoded = serde_json::to_string(&settings).unwrap();
        assert_eq!(
            serde_json::from_str::<SortSettings>(&encoded).unwrap(),
            settings
        );
    }
}

impl SortSettings {
    pub fn validate(&self) -> Result<(), String> {
        if !(1..=100).contains(&self.folder_count) {
            return Err("Folder count must be between 1 and 100".into());
        }
        if self.total_ms == 0 || !self.total_ms.is_multiple_of(1000) {
            return Err("Total time must be a positive whole number of seconds".into());
        }
        let prefix = self.folder_prefix.trim();
        if prefix.is_empty()
            || prefix.len() > 80
            || prefix == "."
            || prefix == ".."
            || prefix.chars().any(|c| {
                c.is_control() || matches!(c, '/' | '\\' | ':' | '<' | '>' | '"' | '|' | '?' | '*')
            })
            || prefix.ends_with('.')
        {
            return Err("Folder prefix must be a safe name of 1 to 80 characters".into());
        }
        Ok(())
    }

    pub fn number(&self, index: usize) -> usize {
        const ORIGINAL: [usize; 14] = [2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
        if self.folder_count == 14 {
            ORIGINAL[index]
        } else {
            index + 1
        }
    }

    pub fn folder_name(&self, index: usize) -> String {
        format!("{} {}", self.folder_prefix.trim(), self.number(index))
    }

    pub fn target_ms(&self, index: usize) -> u64 {
        self.total_ms / self.folder_count as u64
            + u64::from(index < (self.total_ms % self.folder_count as u64) as usize)
    }
}
