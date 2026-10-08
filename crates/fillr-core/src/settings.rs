use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SortSettings {
    pub folder_count: usize,
    pub folder_prefix: String,
    pub total_ms: u64,
}

impl Default for SortSettings {
    fn default() -> Self {
        Self {
            folder_count: 14,
            folder_prefix: "Comp".into(),
            total_ms: 8_470_000,
        }
    }
}

impl SortSettings {
    pub fn validate(&self) -> Result<(), String> {
        if !(1..=100).contains(&self.folder_count) {
            return Err("Folder count must be between 1 and 100".into());
        }
        if self.total_ms == 0 || self.total_ms % 1000 != 0 {
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
