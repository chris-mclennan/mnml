//! Sort mode for the activity list panels — TODOS / NOTES / FINDINGS.
//!
//! User ask 2026-09-01: "not sure what controls order of notes, maybe
//! we need view modes like A-Z or newest ... findings, todo, and notes
//! might need same or similar."
//!
//! **Why a shared enum here, when mnml already has seven sort types.**
//! `file_browser::Sort`, `SessionsSortMode`, `InstalledSort`,
//! `MarketplaceSort`, `TestsSort`, `SpendSortKey` and
//! `claude_agents::SortBy` all exist, and they are NOT collapsible: a
//! file browser sorts dirs-first, sessions sort by run state, the
//! marketplace by install count. Their variants are genuinely
//! different, so a single universal `Sort` would be a lie that every
//! caller then works around.
//!
//! These three panels are the exception — all three are lists of files
//! with a name and an mtime, so they share both variants exactly. That
//! is the test for belonging here: same variants, not merely "also
//! sorted".

/// How a list panel orders its rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ListSort {
    /// Most-recently-modified first. The default for all three panels
    /// because it was already their hard-coded behaviour — changing
    /// what a user sees on upgrade is a separate decision from letting
    /// them choose.
    #[default]
    Newest,
    /// A–Z by the name the row displays. Case-insensitive, because a
    /// user scanning for `README` does not think about capitalisation.
    Name,
}

impl ListSort {
    /// The label shown in the panel's sort menu.
    pub fn label(self) -> &'static str {
        match self {
            ListSort::Newest => "Newest first",
            ListSort::Name => "Name (A–Z)",
        }
    }

    /// Config token. Kept short and stable — this lands in the user's
    /// `config.toml`.
    pub fn as_str(self) -> &'static str {
        match self {
            ListSort::Newest => "newest",
            ListSort::Name => "name",
        }
    }

    /// Parse a config token. Unknown values fall back to the default
    /// rather than erroring: a typo should not stop the panel drawing.
    ///
    /// Named `from_token`, not `from_str`, so it is not mistaken for
    /// `std::str::FromStr` — this never fails, and a `Result` here
    /// would push a pointless unwrap onto every caller.
    pub fn from_token(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "name" => ListSort::Name,
            _ => ListSort::Newest,
        }
    }

    /// Every mode, in menu order.
    pub fn all() -> [ListSort; 2] {
        [ListSort::Newest, ListSort::Name]
    }
}

/// Sort `paths` in place.
///
/// `key` yields the string a row DISPLAYS, which is not always the file
/// name — FINDINGS shows a path relative to its root so nested
/// tester-round directories keep their context. Sorting by the file
/// name there would order rows differently from how they read.
pub fn sort_paths<F>(paths: &mut [std::path::PathBuf], mode: ListSort, key: F)
where
    F: Fn(&std::path::PathBuf) -> String,
{
    match mode {
        ListSort::Name => {
            paths.sort_by_key(|p| key(p).to_lowercase());
        }
        ListSort::Newest => {
            // Name is the TIEBREAK, not decoration. mtime has
            // one-second resolution here, so files written in the same
            // second — which is most of a freshly-cloned or
            // agent-written directory — otherwise render in raw
            // `read_dir` order: `note-24, note-10, note-34`. TODOS
            // already tie-broke; the shared helper did not.
            paths.sort_by_key(|p| {
                let secs = std::fs::metadata(p)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                (std::cmp::Reverse(secs), key(p).to_lowercase())
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn name_sort_is_case_insensitive() {
        let mut v = vec![
            PathBuf::from("/x/beta.md"),
            PathBuf::from("/x/Alpha.md"),
            PathBuf::from("/x/gamma.md"),
        ];
        sort_paths(&mut v, ListSort::Name, |p| {
            p.file_name().unwrap().to_string_lossy().into_owned()
        });
        let names: Vec<String> = v
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            names,
            vec!["Alpha.md", "beta.md", "gamma.md"],
            "capitalised names sorted into their own block"
        );
    }

    /// The key is what the row DISPLAYS, not the file name — FINDINGS
    /// shows a relative path, and sorting by file name there would
    /// order rows differently from how they read on screen.
    #[test]
    fn name_sort_uses_the_displayed_key_not_the_file_name() {
        let mut v = vec![
            PathBuf::from("/root/zzz/a.md"),
            PathBuf::from("/root/aaa/z.md"),
        ];
        sort_paths(&mut v, ListSort::Name, |p| {
            p.strip_prefix("/root")
                .unwrap_or(p)
                .to_string_lossy()
                .into_owned()
        });
        assert_eq!(
            v[0],
            PathBuf::from("/root/aaa/z.md"),
            "sorted by file name instead of the displayed path"
        );
    }

    /// mtime has one-second resolution, so files written together —
    /// most of a cloned or agent-written directory — tie. Without a
    /// tiebreak they render in raw `read_dir` order, which looks
    /// random: `note-24, note-10, note-34`.
    #[test]
    fn newest_breaks_ties_by_name_not_read_dir_order() {
        let d = tempfile::tempdir().unwrap();
        let when = std::time::SystemTime::now();
        let mut v = Vec::new();
        // Deliberately created out of order, all with the SAME mtime.
        for n in ["note-24", "note-10", "note-34"] {
            let p = d.path().join(format!("{n}.md"));
            std::fs::write(&p, "x").unwrap();
            let f = std::fs::File::options().write(true).open(&p).unwrap();
            f.set_times(std::fs::FileTimes::new().set_modified(when))
                .unwrap();
            v.push(p);
        }
        sort_paths(&mut v, ListSort::Newest, |p| {
            p.file_name().unwrap().to_string_lossy().into_owned()
        });
        let names: Vec<String> = v
            .iter()
            .map(|p| p.file_stem().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            names,
            vec!["note-10", "note-24", "note-34"],
            "same-second files did not fall back to name order"
        );
    }

    #[test]
    fn config_tokens_round_trip() {
        for m in ListSort::all() {
            assert_eq!(
                ListSort::from_token(m.as_str()),
                m,
                "{m:?} did not round-trip"
            );
        }
    }

    /// An unknown token must not stop the panel drawing.
    #[test]
    fn an_unknown_token_falls_back_to_the_default() {
        assert_eq!(ListSort::from_token("nonsense"), ListSort::default());
        assert_eq!(ListSort::default(), ListSort::Newest, "default changed");
    }

    /// Every mode must be reachable from the menu, or a mode exists
    /// that no user can select.
    #[test]
    fn every_mode_is_listed_and_labelled() {
        let all = ListSort::all();
        assert_eq!(all.len(), 2);
        for m in all {
            assert!(!m.label().is_empty(), "{m:?} has no menu label");
        }
    }
}
