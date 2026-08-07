//! Tattle Feature Coverage — Trends. Reads the aggregate JSON that
//! `render_trends.py` publishes (same data source the Confluence page
//! renders from) and exposes it to mnml's statusline chip + Pane::Coverage.
//!
//! Data path: `~/.tattle-claude-artifacts/feature-coverage/_trends/trends.json`
//! (produced by the scheduled coverage runs). If the file is missing, the
//! chip + pane hide themselves — no auth, no network, no HTTP fallback in v1.

use serde::Deserialize;
use std::path::PathBuf;

/// Top-level shape of `trends.json`. Only fields mnml needs are decoded;
/// unknown fields are ignored so `render_trends.py` schema tweaks don't
/// break the reader.
#[derive(Debug, Clone, Deserialize)]
pub struct TrendsFile {
    #[serde(default)]
    pub latest_date: String,
    #[serde(default)]
    pub generated_at: String,
    #[serde(default)]
    pub apps: Vec<AppSeries>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AppSeries {
    pub slug: String,
    pub name: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub series: Vec<Point>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Point {
    #[serde(default)]
    pub date: String,
    #[serde(default)]
    pub features: u32,
    #[serde(default)]
    pub ui: Option<f64>,
    #[serde(default)]
    pub api: Option<f64>,
    #[serde(default)]
    pub source_ref: String,
}

impl AppSeries {
    /// Latest recorded point, if any.
    pub fn latest(&self) -> Option<&Point> {
        self.series.last()
    }

    /// The point closest to (but not more recent than) `days_ago` days
    /// before the latest — for the delta arrow. Returns None if the
    /// series doesn't have enough history.
    pub fn point_n_days_ago(&self, days_ago: u32) -> Option<&Point> {
        let latest = self.latest()?;
        let target = date_offset(&latest.date, -(days_ago as i32))?;
        // Walk from newest to oldest, first point with date <= target wins.
        self.series
            .iter()
            .rev()
            .find(|p| p.date <= target)
            .or_else(|| self.series.first())
    }
}

impl TrendsFile {
    /// Load from the default artifact path. `None` if the file doesn't
    /// exist or fails to parse (silently — the caller hides the UI).
    pub fn load_default() -> Option<Self> {
        let path = Self::default_path()?;
        Self::load_from(&path)
    }

    pub fn load_from(path: &PathBuf) -> Option<Self> {
        let text = std::fs::read_to_string(path).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn default_path() -> Option<PathBuf> {
        let home = std::env::var_os("HOME")?;
        Some(
            PathBuf::from(home)
                .join(".tattle-claude-artifacts")
                .join("feature-coverage")
                .join("_trends")
                .join("trends.json"),
        )
    }

    /// Weighted-average current coverage across all apps + both axes,
    /// weighted by each surface's feature count. UI-only + API-only
    /// surfaces contribute only the axes they measure.
    pub fn overall_current(&self) -> Option<f64> {
        weighted_axis_avg(&self.apps, |p| avg_of_both(p.ui, p.api), |_| true)
    }

    /// Same shape as `overall_current`, but for the point closest to
    /// `days_ago` days ago. None if not enough history.
    pub fn overall_at(&self, days_ago: u32) -> Option<f64> {
        weighted_axis_avg(
            &self.apps,
            |p| avg_of_both(p.ui, p.api),
            |_| true, // filter: any app
        )
        .and(Some(())) // placeholder — we recompute below with prior points
        .and_then(|_| {
            let mut total_weight = 0.0f64;
            let mut total = 0.0f64;
            for app in &self.apps {
                let Some(p) = app.point_n_days_ago(days_ago) else {
                    continue;
                };
                let Some(score) = avg_of_both(p.ui, p.api) else {
                    continue;
                };
                let w = p.features as f64;
                total += score * w;
                total_weight += w;
            }
            if total_weight == 0.0 {
                None
            } else {
                Some(total / total_weight)
            }
        })
    }
}

fn avg_of_both(ui: Option<f64>, api: Option<f64>) -> Option<f64> {
    match (ui, api) {
        (Some(a), Some(b)) => Some((a + b) / 2.0),
        (Some(a), None) | (None, Some(a)) => Some(a),
        (None, None) => None,
    }
}

fn weighted_axis_avg<F, G>(apps: &[AppSeries], score_of: F, filter: G) -> Option<f64>
where
    F: Fn(&Point) -> Option<f64>,
    G: Fn(&AppSeries) -> bool,
{
    let mut total_weight = 0.0f64;
    let mut total = 0.0f64;
    for app in apps.iter().filter(|a| filter(a)) {
        let Some(p) = app.latest() else { continue };
        let Some(score) = score_of(p) else { continue };
        let w = p.features as f64;
        total += score * w;
        total_weight += w;
    }
    if total_weight == 0.0 {
        None
    } else {
        Some(total / total_weight)
    }
}

/// Add `delta` days to a YYYY-MM-DD string. Returns the new date string
/// or None on parse failure. Uses a naive date walk (no chrono dep) —
/// works because `render_trends.py` emits ISO-8601 dates.
fn date_offset(date: &str, delta: i32) -> Option<String> {
    let mut parts = date.split('-');
    let mut y: i32 = parts.next()?.parse().ok()?;
    let mut m: i32 = parts.next()?.parse().ok()?;
    let mut d: i32 = parts.next()?.parse().ok()?;
    d += delta;
    // Normalize by walking day-at-a-time. Cheap: our deltas are ≤ 30.
    while d < 1 {
        m -= 1;
        if m < 1 {
            m = 12;
            y -= 1;
        }
        d += days_in_month(y, m);
    }
    loop {
        let dim = days_in_month(y, m);
        if d <= dim {
            break;
        }
        d -= dim;
        m += 1;
        if m > 12 {
            m = 1;
            y += 1;
        }
    }
    Some(format!("{y:04}-{m:02}-{d:02}"))
}

fn days_in_month(y: i32, m: i32) -> i32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 {
                29
            } else {
                28
            }
        }
        _ => 30,
    }
}

/// Render a series of Option<f64> as a braille sparkline. Two dots per
/// column (one glyph = 2 x-samples), so 8 points → 4 braille chars.
/// Missing points render as U+2800 (blank braille) so gaps show.
pub fn braille_sparkline(values: &[Option<f64>], width: usize) -> String {
    if values.is_empty() || width == 0 {
        return String::new();
    }
    // Sample values into `2 * width` columns. If fewer points than
    // needed, spread them across the columns (front-pad with blanks).
    let cols = width * 2;
    let mut samples: Vec<Option<f64>> = Vec::with_capacity(cols);
    if values.len() >= cols {
        // Take the last `cols` values.
        samples.extend_from_slice(&values[values.len() - cols..]);
    } else {
        // Pad front with None, then values.
        for _ in 0..cols - values.len() {
            samples.push(None);
        }
        samples.extend_from_slice(values);
    }
    // Find min/max of the non-None samples.
    let (mut min, mut max) = (f64::INFINITY, f64::NEG_INFINITY);
    for v in samples.iter().flatten() {
        if *v < min {
            min = *v;
        }
        if *v > max {
            max = *v;
        }
    }
    let range = (max - min).max(0.0001);
    // For each pair of columns, map each value to one of 4 rows
    // (braille has 2 columns × 4 rows per glyph). We use only the two
    // left dots (columns 1 + 2) of each glyph so a single value maps
    // cleanly to a horizontal bar.
    //
    // Braille dot layout (per glyph):
    //   1 4
    //   2 5
    //   3 6
    //   7 8
    // Bits: 1=0x01 2=0x02 3=0x04 4=0x08 5=0x10 6=0x20 7=0x40 8=0x80.
    // Column 0 uses dots 1/2/3/7, column 1 uses 4/5/6/8.
    let mut out = String::with_capacity(width);
    for i in 0..width {
        let a = samples[2 * i];
        let b = samples.get(2 * i + 1).copied().flatten();
        let mut bits: u32 = 0;
        if let Some(v) = a {
            let row = value_to_braille_row(v, min, range);
            bits |= LEFT_COL_ROW_BITS[row];
        }
        if let Some(v) = b {
            let row = value_to_braille_row(v, min, range);
            bits |= RIGHT_COL_ROW_BITS[row];
        }
        let code = 0x2800u32 + bits;
        if let Some(ch) = char::from_u32(code) {
            out.push(ch);
        }
    }
    out
}

fn value_to_braille_row(v: f64, min: f64, range: f64) -> usize {
    // Map v ∈ [min, min+range] → row ∈ [0..=3], where 0 = top, 3 = bottom.
    let norm = ((v - min) / range).clamp(0.0, 1.0);
    // Higher value = higher on screen = lower row index.
    let row = 3.0 * (1.0 - norm);
    (row.round() as isize).clamp(0, 3) as usize
}

// Row 0 (top) to row 3 (bottom) → braille dot bits, for the left column.
const LEFT_COL_ROW_BITS: [u32; 4] = [0x01, 0x02, 0x04, 0x40];
// Same, right column.
const RIGHT_COL_ROW_BITS: [u32; 4] = [0x08, 0x10, 0x20, 0x80];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn date_offset_walks_month_boundaries() {
        assert_eq!(
            date_offset("2026-08-05", -7),
            Some("2026-07-29".to_string())
        );
        assert_eq!(
            date_offset("2026-03-05", -10),
            Some("2026-02-23".to_string())
        );
        assert_eq!(
            date_offset("2026-01-01", -1),
            Some("2025-12-31".to_string())
        );
    }

    #[test]
    fn braille_sparkline_shape() {
        let v: Vec<Option<f64>> = (0..8).map(|i| Some(i as f64)).collect();
        let s = braille_sparkline(&v, 4);
        assert_eq!(s.chars().count(), 4);
        // Every char in Braille range.
        for c in s.chars() {
            assert!((0x2800..=0x28FF).contains(&(c as u32)));
        }
    }

    #[test]
    fn braille_sparkline_handles_missing() {
        let v = vec![Some(1.0), None, Some(3.0), Some(4.0)];
        let s = braille_sparkline(&v, 2);
        assert_eq!(s.chars().count(), 2);
    }

    #[test]
    fn overall_current_weighted() {
        let apps = vec![
            AppSeries {
                slug: "a".into(),
                name: "A".into(),
                url: String::new(),
                series: vec![Point {
                    date: "2026-08-05".into(),
                    features: 10,
                    ui: Some(80.0),
                    api: Some(60.0),
                    source_ref: String::new(),
                }],
            },
            AppSeries {
                slug: "b".into(),
                name: "B".into(),
                url: String::new(),
                series: vec![Point {
                    date: "2026-08-05".into(),
                    features: 5,
                    ui: None,
                    api: Some(100.0),
                    source_ref: String::new(),
                }],
            },
        ];
        let file = TrendsFile {
            latest_date: "2026-08-05".into(),
            generated_at: String::new(),
            apps,
        };
        // avg of both for A = 70; single axis for B = 100.
        // weighted: (70*10 + 100*5) / 15 = 1200 / 15 = 80.0
        assert_eq!(file.overall_current(), Some(80.0));
    }
}
