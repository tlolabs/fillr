use crate::settings::SortSettings;
use good_lp::solvers::WithTimeLimit;
use good_lp::{Expression, Solution, SolverModel, constraint, variable, variables};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::time::{SystemTime, UNIX_EPOCH};

pub const TARGET_MS: u64 = 605_000;
pub const COMP_NUMBERS: [u8; 14] = [2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Assignment {
    pub comp: u8,
    pub filenames: Vec<String>,
    pub duration_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Plan {
    pub seed: u64,
    pub assignments: Vec<Assignment>,
    pub selected_duration_ms: u64,
}

impl Plan {
    pub fn validate(&self, clips: &[(String, u64)]) -> bool {
        self.validate_with(clips, &SortSettings::default())
    }

    pub fn validate_with(&self, clips: &[(String, u64)], settings: &SortSettings) -> bool {
        if settings.validate().is_err() || self.assignments.len() != settings.folder_count {
            return false;
        }
        let durations: std::collections::HashMap<&str, u64> =
            clips.iter().map(|(n, d)| (n.as_str(), *d)).collect();
        let mut used = HashSet::new();
        let mut selected = 0;
        for (index, assignment) in self.assignments.iter().enumerate() {
            if usize::from(assignment.comp) != settings.number(index) {
                return false;
            }
            let mut sum = 0u64;
            for name in &assignment.filenames {
                if !used.insert(name.as_str()) {
                    return false;
                }
                let Some(duration) = durations.get(name.as_str()) else {
                    return false;
                };
                sum = sum.saturating_add(*duration);
            }
            if sum < settings.target_ms(index) || sum != assignment.duration_ms {
                return false;
            }
            selected += sum;
        }
        selected == self.selected_duration_ms
    }
}

pub fn make_plan(clips: &[(String, u64)]) -> Option<Plan> {
    make_plan_with(clips, &SortSettings::default())
}

pub fn make_plan_with(clips: &[(String, u64)], settings: &SortSettings) -> Option<Plan> {
    if settings.validate().is_err()
        || clips.len() < settings.folder_count
        || clips.iter().map(|(_, d)| *d).sum::<u64>() < settings.total_ms
    {
        return None;
    }
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let mut best = None;
    for attempt in 0..1500u64 {
        let candidate = greedy(clips, seed.wrapping_add(attempt), settings);
        if let Some(plan) = candidate.filter(|p| p.validate_with(clips, settings))
            && best
                .as_ref()
                .is_none_or(|old: &Plan| score(&plan) < score(old))
        {
            best = Some(plan);
        }
    }
    best.or_else(|| mip_fallback(clips, seed, settings))
}

fn score(plan: &Plan) -> (u64, u64) {
    let count: u64 = plan
        .assignments
        .iter()
        .map(|a| a.filenames.len() as u64)
        .sum();
    (
        plan.selected_duration_ms + 10_000 * count,
        plan.assignments
            .iter()
            .map(|a| a.duration_ms)
            .max()
            .unwrap_or(0),
    )
}

fn greedy(clips: &[(String, u64)], seed: u64, settings: &SortSettings) -> Option<Plan> {
    let mut order: Vec<usize> = (0..clips.len()).collect();
    let mut rng = Rng(seed);
    for i in (1..order.len()).rev() {
        let j = rng.next() as usize % (i + 1);
        order.swap(i, j);
    }
    let mut groups: Vec<Vec<String>> = vec![Vec::new(); settings.folder_count];
    let mut totals = vec![0u64; settings.folder_count];
    for index in order {
        if totals
            .iter()
            .enumerate()
            .all(|(i, total)| *total >= settings.target_ms(i))
        {
            break;
        }
        let bin = (0..settings.folder_count)
            .filter(|i| totals[*i] < settings.target_ms(*i))
            .min_by_key(|i| totals[*i])
            .unwrap();
        groups[bin].push(clips[index].0.clone());
        totals[bin] += clips[index].1;
    }
    if totals
        .iter()
        .enumerate()
        .any(|(i, total)| *total < settings.target_ms(i))
    {
        return None;
    }
    let assignments = groups
        .into_iter()
        .enumerate()
        .map(|(i, filenames)| Assignment {
            comp: settings.number(i) as u8,
            filenames,
            duration_ms: totals[i],
        })
        .collect();
    Some(Plan {
        seed,
        assignments,
        selected_duration_ms: totals.iter().sum(),
    })
}

fn mip_fallback(clips: &[(String, u64)], seed: u64, settings: &SortSettings) -> Option<Plan> {
    let mut vars = variables!();
    let choices: Vec<Vec<_>> = (0..clips.len())
        .map(|_| {
            (0..settings.folder_count)
                .map(|_| vars.add(variable().binary()))
                .collect()
        })
        .collect();
    let mut objective = Expression::from(0.0);
    for ((_, duration), row) in clips.iter().zip(&choices) {
        for choice in row {
            objective += (*duration as f64 + 10_000.0) * *choice;
        }
    }
    let mut model = vars
        .minimise(objective)
        .using(good_lp::solvers::highs::highs)
        .with_time_limit(8.0);
    for row in &choices {
        let mut one = Expression::from(0.0);
        for v in row {
            one += *v;
        }
        model = model.with(constraint!(one <= 1));
    }
    for (comp, _) in choices.first()?.iter().enumerate() {
        let mut length = Expression::from(0.0);
        for ((_, duration), row) in clips.iter().zip(&choices) {
            length += *duration as f64 * row[comp];
        }
        model = model.with(constraint!(length >= settings.target_ms(comp) as f64));
    }
    let solved = model.solve().ok()?;
    let mut assignments = Vec::new();
    for (comp, _) in choices.first()?.iter().enumerate() {
        let mut filenames = Vec::new();
        let mut duration_ms = 0;
        for ((name, duration), row) in clips.iter().zip(&choices) {
            if solved.value(row[comp]) > 0.5 {
                filenames.push(name.clone());
                duration_ms += *duration;
            }
        }
        assignments.push(Assignment {
            comp: settings.number(comp) as u8,
            filenames,
            duration_ms,
        });
    }
    let selected_duration_ms = assignments.iter().map(|a| a.duration_ms).sum();
    let plan = Plan {
        seed,
        assignments,
        selected_duration_ms,
    };
    plan.validate_with(clips, settings).then_some(plan)
}

pub(crate) struct Rng(pub u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn produces_fourteen_disjoint_comp_groups() {
        let clips: Vec<_> = (0..60).map(|i| (format!("{i}.mpg"), 180_000)).collect();
        let plan = make_plan(&clips).unwrap();
        assert!(plan.validate(&clips));
        assert_eq!(plan.assignments.len(), 14);
        assert_eq!(plan.assignments[4].comp, 7);
    }

    #[test]
    fn aggregate_duration_does_not_imply_ready() {
        let clips: Vec<_> = (0..13).map(|i| (format!("{i}.mpg"), 1_000_000)).collect();
        assert!(make_plan(&clips).is_none());
    }

    #[test]
    fn rejects_duplicate_use_and_short_group() {
        let clips: Vec<_> = (0..14).map(|i| (format!("{i}.mpg"), 605_000)).collect();
        let mut plan = make_plan(&clips).unwrap();
        plan.assignments[0].filenames.push("1.mpg".into());
        assert!(!plan.validate(&clips));
    }

    #[test]
    fn configurable_groups_preserve_total_and_original_numbering() {
        let settings = SortSettings {
            folder_count: 3,
            folder_prefix: "Scene".into(),
            total_ms: 10_000,
        };
        let clips: Vec<_> = (0..3).map(|i| (format!("{i}.mpg"), 4_000)).collect();
        let plan = make_plan_with(&clips, &settings).unwrap();
        assert!(plan.validate_with(&clips, &settings));
        assert_eq!(
            settings.target_ms(0) + settings.target_ms(1) + settings.target_ms(2),
            10_000
        );
        assert_eq!(
            plan.assignments.iter().map(|a| a.comp).collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
        assert!(!plan.validate(&clips));
        assert_eq!(settings.folder_name(0), "Scene 1");
        assert_eq!(
            SortSettings {
                folder_count: 15,
                ..SortSettings::default()
            }
            .folder_name(14),
            "Comp 15"
        );
    }
}
