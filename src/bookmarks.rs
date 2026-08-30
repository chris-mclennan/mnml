//! Env-grouped web bookmarks for the browser chip.
//!
//! User ask (2026-08-29): right-click the browser icon and pick from a
//! list of defined sites grouped by environment — "ill have dev sites and
//! staging and prod". Explicitly NOT baked in: "i dont wnat these baked
//! in, they are user prefs".
//!
//! # Why the mechanism lives in mnml core but the data does not
//!
//! The user's own URLs are employer-specific and they asked whether the
//! whole feature belonged in `mnml-tattle-integrations` instead. The split
//! taken here: mnml core owns the MECHANISM (every developer has
//! dev/staging/prod URLs — that is not a Tattle concept), and the URLs are
//! DATA in a config file that any repo or user can ship. A bookmarks
//! feature only one company's employees could use would be a worse
//! feature, and the env→site menu has to be rendered by mnml either way.
//!
//! # Schema
//!
//! Two forms, because the real data has both shapes. A `[[site]]` is one
//! logical destination that exists in several environments:
//!
//! ```toml
//! [[site]]
//! name    = "ADX Admin"
//! dev     = "https://adx.dev.example.net/admin/dashboard"
//! staging = "https://adx.staging.example.net/admin/dashboard"
//! prod    = "https://adx.example.com/admin/dashboard"
//! ```
//!
//! That form exists because the user's twelve URLs are four sites × three
//! envs — repeating the label three times would make "probably more
//! coming" three times more expensive than it needs to be.
//!
//! A `[[bookmark]]` is a one-off that only exists in one place:
//!
//! ```toml
//! [[bookmark]]
//! label = "Metabase"
//! url   = "https://metabase.example.net"
//! env   = "prod"          # optional; defaults to "other"
//! ```
//!
//! # Precedence
//!
//! User-global `<data_root>/bookmarks.toml`, then workspace
//! `<workspace>/.mnml/bookmarks.toml`. Both are loaded and CONCATENATED
//! rather than one overriding the other — unlike integration manifests,
//! where a workspace file replaces a user file for the same id. Bookmarks
//! are a list, not a keyed record: a repo shipping its own sites should
//! add to your personal set, not hide it.

use std::path::{Path, PathBuf};

/// One resolved, openable bookmark.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bookmark {
    /// Display name, e.g. `"ADX Admin"`.
    pub label: String,
    pub url: String,
    /// Environment bucket — `"dev"` / `"staging"` / `"prod"`, or anything
    /// else the user writes. Free-form on purpose: not every shop uses
    /// those three names (`qa`, `sandbox`, `uat` are all real).
    pub env: String,
}

/// Env bucket for a `[[bookmark]]` that names none.
pub const DEFAULT_ENV: &str = "other";

#[derive(Debug, Default, serde::Deserialize)]
struct RawFile {
    #[serde(default)]
    site: Vec<RawSite>,
    #[serde(default)]
    bookmark: Vec<RawBookmark>,
}

#[derive(Debug, serde::Deserialize)]
struct RawSite {
    name: String,
    /// Any env name → URL. Flattened so `dev = "…"` / `uat = "…"` both
    /// work without the schema naming the environments — see `env`'s doc
    /// on [`Bookmark`].
    #[serde(flatten)]
    urls: std::collections::BTreeMap<String, String>,
}

#[derive(Debug, serde::Deserialize)]
struct RawBookmark {
    label: String,
    url: String,
    env: Option<String>,
}

/// The two files bookmarks are read from, in load order.
pub fn paths(workspace: &Path) -> Vec<PathBuf> {
    vec![
        crate::data_root::data_root().join("bookmarks.toml"),
        workspace.join(".mnml").join("bookmarks.toml"),
    ]
}

/// Load every bookmark for `workspace`.
///
/// A malformed or missing file is skipped rather than fatal — a typo in a
/// bookmarks file must not stop mnml starting. Returns them in file order,
/// sites expanded env-by-env.
pub fn load(workspace: &Path) -> Vec<Bookmark> {
    let mut out = Vec::new();
    for p in paths(workspace) {
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(raw) = toml::from_str::<RawFile>(&text) else {
            eprintln!("bookmarks: {} is not valid TOML — skipped", p.display());
            continue;
        };
        for site in raw.site {
            for (env, url) in site.urls {
                if url.trim().is_empty() {
                    continue;
                }
                out.push(Bookmark {
                    label: site.name.clone(),
                    url,
                    env,
                });
            }
        }
        for b in raw.bookmark {
            if b.url.trim().is_empty() {
                continue;
            }
            out.push(Bookmark {
                label: b.label,
                url: b.url,
                env: b.env.unwrap_or_else(|| DEFAULT_ENV.to_string()),
            });
        }
    }
    out
}

/// Distinct env names, ordered for a menu: the conventional promotion
/// order first, then anything else alphabetically.
///
/// Promotion order rather than alphabetical because `dev → staging → prod`
/// is how people think about environments; alphabetically it would read
/// `dev, prod, staging`, putting production in the middle.
pub fn envs(marks: &[Bookmark]) -> Vec<String> {
    const ORDER: [&str; 6] = ["local", "dev", "test", "qa", "staging", "prod"];
    let mut known: Vec<String> = Vec::new();
    let mut rest: Vec<String> = Vec::new();
    for m in marks {
        let seen = known.iter().chain(rest.iter()).any(|e| e == &m.env);
        if seen {
            continue;
        }
        if ORDER.contains(&m.env.as_str()) {
            known.push(m.env.clone());
        } else {
            rest.push(m.env.clone());
        }
    }
    known.sort_by_key(|e| ORDER.iter().position(|o| o == e).unwrap_or(usize::MAX));
    rest.sort();
    known.extend(rest);
    known
}

/// Bookmarks in one env, file order preserved.
pub fn in_env<'a>(marks: &'a [Bookmark], env: &str) -> Vec<&'a Bookmark> {
    marks.iter().filter(|m| m.env == env).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str, body: &str) {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join(name), body).unwrap();
    }

    /// The user's real shape: four sites × three envs, each site declared
    /// once. Twelve bookmarks from twelve lines of URL.
    #[test]
    fn a_site_expands_into_one_bookmark_per_env() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", d.path().join("root"));
        write(
            &d.path().join("root"),
            "bookmarks.toml",
            r#"
[[site]]
name = "ADX Admin"
dev = "https://adx.dev.example.net/admin/dashboard"
staging = "https://adx.staging.example.net/admin/dashboard"
prod = "https://adx.example.com/admin/dashboard"
"#,
        );
        let marks = load(d.path());
        assert_eq!(marks.len(), 3, "{marks:?}");
        assert!(marks.iter().all(|m| m.label == "ADX Admin"));
        let envs: Vec<&str> = marks.iter().map(|m| m.env.as_str()).collect();
        for e in ["dev", "staging", "prod"] {
            assert!(envs.contains(&e), "missing {e}: {envs:?}");
        }
    }

    #[test]
    fn a_flat_bookmark_without_an_env_lands_in_other() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", d.path().join("root"));
        write(
            &d.path().join("root"),
            "bookmarks.toml",
            "[[bookmark]]\nlabel = \"Docs\"\nurl = \"https://example.com\"\n",
        );
        let marks = load(d.path());
        assert_eq!(marks.len(), 1);
        assert_eq!(marks[0].env, DEFAULT_ENV);
    }

    /// A repo's bookmarks ADD to the user's rather than replacing them —
    /// unlike integration manifests, which are keyed by id.
    #[test]
    fn workspace_bookmarks_are_added_not_substituted() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", d.path().join("root"));
        write(
            &d.path().join("root"),
            "bookmarks.toml",
            "[[bookmark]]\nlabel = \"Mine\"\nurl = \"https://a\"\nenv = \"dev\"\n",
        );
        write(
            &d.path().join(".mnml"),
            "bookmarks.toml",
            "[[bookmark]]\nlabel = \"Repo\"\nurl = \"https://b\"\nenv = \"dev\"\n",
        );
        let labels: Vec<String> = load(d.path()).into_iter().map(|m| m.label).collect();
        assert_eq!(labels, vec!["Mine".to_string(), "Repo".to_string()]);
    }

    /// A typo must not stop mnml starting.
    #[test]
    fn a_malformed_file_is_skipped_not_fatal() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", d.path().join("root"));
        write(
            &d.path().join("root"),
            "bookmarks.toml",
            "this is not toml [[[",
        );
        write(
            &d.path().join(".mnml"),
            "bookmarks.toml",
            "[[bookmark]]\nlabel = \"Good\"\nurl = \"https://ok\"\n",
        );
        let marks = load(d.path());
        assert_eq!(
            marks.len(),
            1,
            "the valid file should still load: {marks:?}"
        );
        assert_eq!(marks[0].label, "Good");
    }

    #[test]
    fn envs_are_ordered_by_promotion_not_alphabetically() {
        let marks: Vec<Bookmark> = ["prod", "dev", "staging", "zeta", "alpha"]
            .iter()
            .map(|e| Bookmark {
                label: "x".into(),
                url: "https://x".into(),
                env: (*e).to_string(),
            })
            .collect();
        assert_eq!(
            envs(&marks),
            vec![
                "dev".to_string(),
                "staging".to_string(),
                "prod".to_string(),
                "alpha".to_string(),
                "zeta".to_string()
            ],
            "alphabetical order would put prod between dev and staging"
        );
    }

    #[test]
    fn an_empty_url_is_dropped() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", d.path().join("root"));
        write(
            &d.path().join("root"),
            "bookmarks.toml",
            "[[site]]\nname = \"S\"\ndev = \"https://d\"\nprod = \"\"\n",
        );
        let marks = load(d.path());
        assert_eq!(marks.len(), 1, "an empty env URL should not become a row");
        assert_eq!(marks[0].env, "dev");
    }
}

#[cfg(test)]
mod menu_wiring_tests {
    use crate::context_menu::MenuAction;

    fn seed(root: &std::path::Path) {
        std::fs::create_dir_all(root).unwrap();
        std::fs::write(
            root.join("bookmarks.toml"),
            r#"
[[site]]
name = "ADX Admin"
dev = "https://adx.dev.example.net/admin/dashboard"
staging = "https://adx.staging.example.net/admin/dashboard"
prod = "https://adx.example.com/admin/dashboard"
"#,
        )
        .unwrap();
    }

    /// #1229 — "right click it and shoose from list of defined sites by
    /// env". One row per env, in promotion order, plus an all-envs row.
    #[test]
    fn the_browser_chip_menu_gains_one_row_per_env() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", d.path().join("root"));
        seed(&d.path().join("root"));

        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        let idx = app
            .config
            .ui
            .integration_icons
            .iter()
            .position(|i| i.id == "browser")
            .expect("browser chip is a shipped default");
        app.open_integration_chip_context_menu(idx, (5, 5));

        let menu = app.context_menu.as_ref().expect("menu did not open");
        let envs: Vec<String> = menu
            .items
            .iter()
            .filter_map(|it| match &it.action {
                MenuAction::OpenBookmarks(Some(e)) => Some(e.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(
            envs,
            vec!["dev".to_string(), "staging".to_string(), "prod".to_string()],
            "env rows missing or out of promotion order: {:?}",
            menu.items.iter().map(|i| &i.label).collect::<Vec<_>>()
        );
        assert!(
            menu.items
                .iter()
                .any(|it| matches!(it.action, MenuAction::OpenBookmarks(None))),
            "no all-envs row"
        );
    }

    /// A user who has never written the file must not see dead rows.
    #[test]
    fn no_bookmark_rows_when_no_bookmarks_are_defined() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", d.path().join("empty-root"));

        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        let idx = app
            .config
            .ui
            .integration_icons
            .iter()
            .position(|i| i.id == "browser")
            .unwrap();
        app.open_integration_chip_context_menu(idx, (5, 5));

        let menu = app.context_menu.as_ref().expect("menu did not open");
        assert!(
            !menu
                .items
                .iter()
                .any(|it| matches!(it.action, MenuAction::OpenBookmarks(_))),
            "bookmark rows appeared with no bookmarks defined"
        );
    }

    /// Scoping to an env must actually narrow the picker, and the URL is
    /// the id the accept path opens.
    #[test]
    fn the_env_scoped_picker_lists_only_that_env() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _root = crate::EnvGuard::set("MNML_DATA_ROOT", d.path().join("root"));
        seed(&d.path().join("root"));

        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.open_bookmarks_picker(Some("staging"));

        let pk = app.picker.as_ref().expect("picker did not open");
        assert_eq!(pk.len(), 1, "expected only the staging row");
        let first = pk.items_view().next().expect("no rows");
        assert!(
            first.id.contains("staging"),
            "picker id must be the URL: {:?}",
            first.id
        );
    }
}
