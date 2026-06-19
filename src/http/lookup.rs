//! Lookup picker — fills env vars from real API responses.
//!
//! Workflow (Ctrl+; in the TUI):
//!   1. PickingFile  pick a saved lookup file under <ws>/.rqst/lookups/
//!   2. Loading      fire the lookup curl, parse the JSON response
//!   3. PickingItem  pick an item rendered as "label (id)"
//!   4. EnteringVar  type the env var name to receive the id
//!
//! Item parsing heuristic — assumes a list-shaped response:
//!   bare array               → use it
//!   { "data":   [...] }      → use it
//!   { "items":  [...] }      → use it
//!   { <single-key>: [...] }  → use it
//! For each entry, the id field is the first of:
//!   `id`, `Id`, `<*>Id` (camelCase), `_id`
//! and the label is the first of:
//!   `name`, `displayName`, `label`, `title`, `label`, otherwise the id.

use serde_json::Value;
use std::path::{Path, PathBuf};

const SKIP_DIRS: &[&str] = &["target", "node_modules"];

#[derive(Debug, Clone, PartialEq)]
pub enum Stage {
    PickingFile,
    Loading,
    PickingItem,
    EnteringVar,
}

#[derive(Debug, Clone)]
pub struct LookupItem {
    pub id: String,
    pub label: String,
}

#[derive(Debug)]
pub struct LookupPicker {
    pub stage: Stage,
    pub workspace: PathBuf,

    // Stage 1 state
    pub files: Vec<PathBuf>,
    pub file_filter: String,
    pub file_cursor: usize,

    // Stage 2 state — set when transitioning to Loading
    pub loading_file: Option<PathBuf>,

    // Stage 3 state — populated when items land
    pub items: Vec<LookupItem>,
    pub item_filter: String,
    pub item_cursor: usize,

    // Stage 4 state
    pub picked: Option<LookupItem>,
    pub var_name_input: String,
    pub var_name_suggestion: Option<String>,
}

impl LookupPicker {
    pub fn open(workspace: &Path) -> Self {
        let files = scan_lookups(workspace);
        Self {
            stage: Stage::PickingFile,
            workspace: workspace.to_path_buf(),
            files,
            file_filter: String::new(),
            file_cursor: 0,
            loading_file: None,
            items: Vec::new(),
            item_filter: String::new(),
            item_cursor: 0,
            picked: None,
            var_name_input: String::new(),
            var_name_suggestion: None,
        }
    }

    pub fn filtered_files(&self) -> Vec<usize> {
        let q = self.file_filter.to_lowercase();
        self.files
            .iter()
            .enumerate()
            .filter(|(_, p)| {
                let rel = relative_label(p, &self.workspace);
                rel.to_lowercase().contains(&q)
            })
            .map(|(i, _)| i)
            .collect()
    }

    pub fn filtered_items(&self) -> Vec<usize> {
        let q = self.item_filter.to_lowercase();
        self.items
            .iter()
            .enumerate()
            .filter(|(_, it)| {
                it.label.to_lowercase().contains(&q) || it.id.to_lowercase().contains(&q)
            })
            .map(|(i, _)| i)
            .collect()
    }

    pub fn selected_file(&self) -> Option<&PathBuf> {
        let filtered = self.filtered_files();
        filtered
            .get(self.file_cursor)
            .and_then(|&i| self.files.get(i))
    }

    pub fn selected_item(&self) -> Option<&LookupItem> {
        let filtered = self.filtered_items();
        filtered
            .get(self.item_cursor)
            .and_then(|&i| self.items.get(i))
    }
}

fn scan_lookups(workspace: &Path) -> Vec<PathBuf> {
    let lookup_dir = workspace.join(".rqst").join("lookups");
    if !lookup_dir.is_dir() {
        return Vec::new();
    }
    let mut out: Vec<PathBuf> = Vec::new();
    let mut stack: Vec<PathBuf> = vec![lookup_dir];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with('.') || SKIP_DIRS.iter().any(|s| s == &name_str) {
                continue;
            }
            let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
            if is_dir {
                stack.push(path);
            } else if path.extension().and_then(|e| e.to_str()) == Some("curl") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

pub fn relative_label(path: &Path, workspace: &Path) -> String {
    path.strip_prefix(workspace.join(".rqst").join("lookups"))
        .unwrap_or(path)
        .to_string_lossy()
        .into_owned()
}

/// Parse a JSON response into a list of (id, label) items. Returns None when
/// no list shape is found.
pub fn parse_items(body: &str) -> Option<Vec<LookupItem>> {
    let v: Value = serde_json::from_str(body.trim()).ok()?;
    let array = pick_array(&v)?;
    let mut items: Vec<LookupItem> = Vec::new();
    for entry in array {
        if let Some(item) = item_from_value(entry) {
            items.push(item);
        }
    }
    if items.is_empty() { None } else { Some(items) }
}

fn pick_array(v: &Value) -> Option<&Vec<Value>> {
    if let Some(arr) = v.as_array() {
        return Some(arr);
    }
    if let Some(obj) = v.as_object() {
        for key in &["data", "items", "results"] {
            if let Some(arr) = obj.get(*key).and_then(|x| x.as_array()) {
                return Some(arr);
            }
        }
        // Single-key object whose value is an array.
        if obj.len() == 1 {
            let only = obj.values().next().unwrap();
            if let Some(arr) = only.as_array() {
                return Some(arr);
            }
        }
    }
    None
}

fn item_from_value(v: &Value) -> Option<LookupItem> {
    let obj = v.as_object()?;
    let id_val = obj
        .get("id")
        .or_else(|| obj.get("Id"))
        .or_else(|| obj.get("_id"))
        .or_else(|| {
            obj.iter()
                .find(|(k, _)| {
                    let lk = k.to_ascii_lowercase();
                    (lk.ends_with("id") && lk.len() > 2) || lk == "id"
                })
                .map(|(_, v)| v)
        })?;
    let id = match id_val {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => return None,
    };
    let label = ["name", "displayName", "label", "title", "summary"]
        .iter()
        .find_map(|k| obj.get(*k).and_then(|x| x.as_str()).map(String::from))
        .unwrap_or_else(|| id.clone());
    Some(LookupItem { id, label })
}

/// Suggest the env var name to ask for, given the chosen lookup file's
/// stem. e.g. `locations.curl` → `LOCATION_ID`, `delivery-partners.curl`
/// → `DELIVERY_PARTNER_ID`.
pub fn suggest_var_name(file: &Path) -> String {
    let stem = file
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("ITEM")
        .trim_end_matches('s')
        .replace(['-', ' '], "_");
    format!("{}_ID", stem.to_ascii_uppercase())
}

/// Inverse of suggest_var_name: given a var like `LOCATION_ID`, find the
/// index of a lookup file whose stem matches. Tries the var with `_ID`
/// stripped, both with and without a trailing `s`.
pub fn match_lookup_for_var(var: &str, files: &[PathBuf]) -> Option<usize> {
    let core = var
        .strip_suffix("_ID")
        .or_else(|| var.strip_suffix("Id"))
        .unwrap_or(var)
        .to_ascii_lowercase()
        .replace('_', "-");
    let candidates = [
        format!("{core}s"), // locations
        core.clone(),       // location
    ];
    for cand in &candidates {
        if let Some(i) = files
            .iter()
            .position(|p| p.file_stem().and_then(|s| s.to_str()) == Some(cand.as_str()))
        {
            return Some(i);
        }
    }
    None
}

/// Find the `{{var_name}}` placeholder that the cursor sits inside,
/// returning its name. Returns None if the cursor isn't between matching
/// `{{` and `}}` markers.
pub fn var_at_cursor(text: &str, cursor: usize) -> Option<String> {
    if cursor > text.len() {
        return None;
    }
    // Look backward from cursor for `{{`, forward for `}}`. Reject if
    // either marker is missing or another `{{` / `}}` is between.
    let before = &text[..cursor];
    let open_at = before.rfind("{{")?;
    // No `}}` between open_at and cursor.
    if before[open_at + 2..].contains("}}") {
        return None;
    }
    let after = &text[cursor..];
    let close_rel = after.find("}}")?;
    if after[..close_rel].contains("{{") {
        return None;
    }
    let inner = &text[open_at + 2..cursor + close_rel];
    let trimmed = inner.trim();
    if trimmed.is_empty()
        || !trimmed
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
    {
        return None;
    }
    Some(trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_items_handles_data_envelope() {
        let body = json!({
            "data": [
                { "id": 1, "name": "First" },
                { "id": 2, "name": "Second" }
            ]
        })
        .to_string();
        let items = parse_items(&body).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "1");
        assert_eq!(items[0].label, "First");
    }

    #[test]
    fn parse_items_handles_bare_array() {
        let body = json!([
            { "id": "a", "displayName": "Alpha" },
            { "id": "b", "title": "Beta" }
        ])
        .to_string();
        let items = parse_items(&body).unwrap();
        assert_eq!(items[0].label, "Alpha");
        assert_eq!(items[1].label, "Beta");
    }

    #[test]
    fn parse_items_falls_back_to_camel_id_field() {
        let body = json!({
            "data": [
                { "merchantId": 2148, "name": "Hot Pizza" }
            ]
        })
        .to_string();
        let items = parse_items(&body).unwrap();
        assert_eq!(items[0].id, "2148");
        assert_eq!(items[0].label, "Hot Pizza");
    }

    #[test]
    fn parse_items_label_falls_back_to_id_when_no_name() {
        let body = json!([{ "id": 42 }]).to_string();
        let items = parse_items(&body).unwrap();
        assert_eq!(items[0].id, "42");
        assert_eq!(items[0].label, "42");
    }

    #[test]
    fn parse_items_returns_none_for_non_list_shape() {
        let body = json!({ "x": 1, "y": 2 }).to_string();
        assert!(parse_items(&body).is_none());
        assert!(parse_items("not json").is_none());
    }

    #[test]
    fn match_lookup_for_var_finds_plural_and_singular() {
        let files = vec![
            PathBuf::from("/ws/.rqst/lookups/locations.curl"),
            PathBuf::from("/ws/.rqst/lookups/merchant.curl"),
            PathBuf::from("/ws/.rqst/lookups/delivery-partners.curl"),
        ];
        assert_eq!(match_lookup_for_var("LOCATION_ID", &files), Some(0));
        assert_eq!(match_lookup_for_var("MERCHANT_ID", &files), Some(1));
        assert_eq!(match_lookup_for_var("DELIVERY_PARTNER_ID", &files), Some(2));
        assert_eq!(match_lookup_for_var("UNKNOWN_ID", &files), None);
    }

    #[test]
    fn var_at_cursor_finds_surrounding_placeholder() {
        let text = "curl '{{BASE_URL}}/api/{{LOCATION_ID}}/x'";
        // cursor in middle of {{LOCATION_ID}}
        let pos = text.find("LOCATION").unwrap() + 4;
        assert_eq!(var_at_cursor(text, pos).as_deref(), Some("LOCATION_ID"));
        // cursor outside any var
        let pos = text.find("/api").unwrap();
        assert_eq!(var_at_cursor(text, pos), None);
        // cursor in the BASE_URL var
        let pos = text.find("BASE_URL").unwrap() + 1;
        assert_eq!(var_at_cursor(text, pos).as_deref(), Some("BASE_URL"));
    }

    #[test]
    fn var_at_cursor_rejects_unterminated_placeholders() {
        assert_eq!(var_at_cursor("{{LOCATION_ID", 5), None);
        assert_eq!(var_at_cursor("LOCATION_ID}}", 5), None);
    }

    #[test]
    fn suggest_var_name_strips_trailing_s_and_uppercases() {
        assert_eq!(
            suggest_var_name(Path::new(".rqst/lookups/locations.curl")),
            "LOCATION_ID"
        );
        assert_eq!(
            suggest_var_name(Path::new(".rqst/lookups/delivery-partners.curl")),
            "DELIVERY_PARTNER_ID"
        );
    }
}
