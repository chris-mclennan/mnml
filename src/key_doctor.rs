//! Key-arrival diagnostic — "which modifier chords actually reach mnml?"
//!
//! # Why this exists
//!
//! mnml binds word/line motion to Ctrl+←/→, Option/Alt+←/→, Cmd+←/→ and
//! Home/End (`src/input/standard.rs`). It has to bind all of them,
//! because **no single chord survives every platform**:
//!
//! - **macOS** claims `Ctrl+←/→` for Mission Control's "move left/right
//!   a space", on by default the moment you have more than one Space.
//!   The key never reaches the terminal, let alone mnml.
//! - **Option+←/→** only arrives as ALT if the terminal is told to send
//!   it. Ghostty defaults `macos-option-as-alt = false` (Option composes
//!   `é`, `ß`, …); iTerm2 defaults Left Option to "Normal" rather than
//!   "Esc+".
//! - **Cmd+←/→** is forwarded by some terminals and swallowed by others.
//! - **Home/End** are reliable but are `Fn+←/→` on a MacBook.
//!
//! The failure is silent and misattributed: the user presses Ctrl+→,
//! nothing happens, and they reasonably conclude mnml's word-jump is
//! broken. It isn't — the keystroke was intercepted several layers up.
//!
//! # The approach
//!
//! Absence of a keypress is not observable, so mnml cannot detect this
//! passively — it can only *probe*. The user presses each chord and we
//! report what actually arrived. Same idea as the Nerd Font sample in
//! the first-launch wizard: don't guess at the environment, render
//! something the user can check against reality.
//!
//! This module is the shared engine. Two surfaces consume it:
//!   - the first-launch wizard's Keyboard section (catch it up front),
//!   - the `keys.doctor` command (run it later — people switch
//!     terminals, or skipped the wizard).
//!
//! Remedies are per-terminal text, with one auto-fix where we can be
//! certain: ghostty on macOS, whose config format and path we know.
//! Everything else gets accurate instructions rather than mnml writing
//! into a config file it may not understand.

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

/// The modifier bits a probe cares about. Shift is deliberately
/// excluded — `Shift+Alt+→` still proves ALT arrives — as are exotic
/// flags (KEYPAD, CAPS_LOCK) some terminals attach.
const TRACKED: KeyModifiers = KeyModifiers::CONTROL
    .union(KeyModifiers::ALT)
    .union(KeyModifiers::SUPER);

/// One chord we ask the user to press.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Probe {
    /// Stable id for remedy lookup + tests.
    pub id: &'static str,
    /// How the chord is written in the UI.
    pub label: &'static str,
    pub code: KeyCode,
    pub mods: KeyModifiers,
    /// What binding this chord drives, for the results table.
    pub purpose: &'static str,
    /// False for the control probe — a chord that should always arrive.
    /// If even this one never ticks, the user isn't pressing keys (or
    /// the probe itself is broken), which is worth distinguishing from
    /// "your terminal eats modifiers".
    pub is_control: bool,
}

/// The chords worth probing. Deliberately short: one direction each is
/// enough to prove a modifier is forwarded, since left/right are
/// symmetric in every layer that intercepts them.
pub const PROBES: &[Probe] = &[
    Probe {
        id: "ctrl_right",
        label: "Ctrl+→",
        code: KeyCode::Right,
        mods: KeyModifiers::CONTROL,
        purpose: "word right (Linux/Windows native)",
        is_control: false,
    },
    Probe {
        id: "alt_right",
        label: "Option/Alt+→",
        code: KeyCode::Right,
        mods: KeyModifiers::ALT,
        purpose: "word right (macOS native)",
        is_control: false,
    },
    Probe {
        id: "cmd_right",
        label: "Cmd+→",
        code: KeyCode::Right,
        mods: KeyModifiers::SUPER,
        purpose: "end of line (macOS native)",
        is_control: false,
    },
    Probe {
        id: "end",
        label: "End",
        code: KeyCode::End,
        mods: KeyModifiers::NONE,
        purpose: "end of line (all platforms; Fn+→ on a MacBook)",
        is_control: true,
    },
];

/// Which probes have been observed so far.
#[derive(Debug, Clone, Default)]
pub struct KeyDoctor {
    seen: Vec<bool>,
}

impl KeyDoctor {
    pub fn new() -> Self {
        Self {
            seen: vec![false; PROBES.len()],
        }
    }

    /// Feed a key event. Returns true if it matched a probe, so callers
    /// can swallow it rather than letting it fall through to navigation.
    pub fn observe(&mut self, key: KeyEvent) -> bool {
        let m = key.modifiers & TRACKED;
        for (i, p) in PROBES.iter().enumerate() {
            if p.code == key.code && m == (p.mods & TRACKED) {
                if self.seen.len() != PROBES.len() {
                    self.seen = vec![false; PROBES.len()];
                }
                self.seen[i] = true;
                return true;
            }
        }
        false
    }

    pub fn is_seen(&self, i: usize) -> bool {
        self.seen.get(i).copied().unwrap_or(false)
    }

    /// True once every non-control probe has arrived.
    pub fn all_arrived(&self) -> bool {
        PROBES
            .iter()
            .enumerate()
            .filter(|(_, p)| !p.is_control)
            .all(|(i, _)| self.is_seen(i))
    }

    /// True if nothing at all has arrived — including the control probe.
    /// Distinguishes "hasn't tried yet" from "terminal eats modifiers".
    pub fn nothing_arrived(&self) -> bool {
        !self.seen.iter().any(|s| *s)
    }

    pub fn missing(&self) -> Vec<&'static Probe> {
        PROBES
            .iter()
            .enumerate()
            .filter(|(i, p)| !p.is_control && !self.is_seen(*i))
            .map(|(_, p)| p)
            .collect()
    }
}

/// Terminals we can give specific advice for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalKind {
    Ghostty,
    ITerm2,
    AppleTerminal,
    Kitty,
    WezTerm,
    Alacritty,
    WindowsTerminal,
    Unknown,
}

/// Detect the host terminal from the environment it advertises.
///
/// Note this is the *outermost* thing we can see: under tmux or ssh the
/// vars describe whatever is nearest, which is why `under_multiplexer`
/// is reported separately — tmux needs its own passthrough regardless of
/// which terminal is underneath.
pub fn detect_terminal_from(
    term_program: Option<&str>,
    term: Option<&str>,
    kitty_window: bool,
    wt_session: bool,
) -> TerminalKind {
    match term_program.unwrap_or("").to_ascii_lowercase().as_str() {
        "ghostty" => return TerminalKind::Ghostty,
        "iterm.app" => return TerminalKind::ITerm2,
        "apple_terminal" => return TerminalKind::AppleTerminal,
        "wezterm" => return TerminalKind::WezTerm,
        _ => {}
    }
    if kitty_window {
        return TerminalKind::Kitty;
    }
    if wt_session {
        return TerminalKind::WindowsTerminal;
    }
    let t = term.unwrap_or("").to_ascii_lowercase();
    if t.contains("kitty") {
        return TerminalKind::Kitty;
    }
    if t.contains("alacritty") {
        return TerminalKind::Alacritty;
    }
    TerminalKind::Unknown
}

pub fn detect_terminal() -> TerminalKind {
    detect_terminal_from(
        std::env::var("TERM_PROGRAM").ok().as_deref(),
        std::env::var("TERM").ok().as_deref(),
        std::env::var("KITTY_WINDOW_ID").is_ok(),
        std::env::var("WT_SESSION").is_ok(),
    )
}

pub fn under_multiplexer() -> bool {
    std::env::var("TMUX").is_ok() || std::env::var("STY").is_ok()
}

/// A fix mnml can apply itself, as opposed to instructions to follow.
/// Deliberately tiny — we only automate where the config format AND
/// path are unambiguous.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutoFix {
    /// Append `macos-option-as-alt = true` to `~/.config/ghostty/config`.
    /// Unlocks Option+←/→ (and every other Alt chord) in one line.
    GhosttyOptionAsAlt,
}

/// What to tell the user about one missing chord.
#[derive(Debug, Clone)]
pub struct Remedy {
    pub text: String,
    pub fix: Option<AutoFix>,
}

/// Advice for a chord that never arrived.
pub fn remedy(probe_id: &str, term: TerminalKind, is_macos: bool) -> Remedy {
    let none = |t: &str| Remedy {
        text: t.to_string(),
        fix: None,
    };
    match probe_id {
        "ctrl_right" if is_macos => none(
            "macOS binds Ctrl+←/→ to Mission Control's \"move left/right a space\" \
             whenever you have more than one Space, so it never reaches the \
             terminal. Free it in System Settings → Keyboard → Keyboard Shortcuts \
             → Mission Control, or just use Option+←/→ instead.",
        ),
        "ctrl_right" => none(
            "Ctrl+←/→ is normally forwarded on this platform. Check your terminal \
             or window manager for a conflicting global shortcut.",
        ),
        "alt_right" => match term {
            TerminalKind::Ghostty if is_macos => Remedy {
                text: "Ghostty defaults to using Option for special characters \
                       (Option+e → é) rather than sending Alt. Adding \
                       `macos-option-as-alt = true` to ~/.config/ghostty/config \
                       forwards it — this unlocks Option+←/→ and every other Alt \
                       chord. Restart ghostty afterwards."
                    .to_string(),
                fix: Some(AutoFix::GhosttyOptionAsAlt),
            },
            TerminalKind::ITerm2 => none(
                "iTerm2 defaults Left Option to \"Normal\". Set Settings → Profiles \
                 → Keys → Left Option key = \"Esc+\" to send Alt.",
            ),
            TerminalKind::AppleTerminal => none(
                "Terminal.app: Settings → Profiles → Keyboard → tick \"Use Option as \
                 Meta key\".",
            ),
            _ if is_macos => none(
                "On macOS most terminals use Option to compose special characters \
                 rather than sending Alt. Look for an \"Option as Meta/Alt\" setting \
                 in your terminal's preferences.",
            ),
            _ => none(
                "Alt+←/→ isn't arriving. Check your terminal's key-encoding settings, \
                 or use Ctrl+←/→ instead.",
            ),
        },
        "cmd_right" if is_macos => none(
            "Most terminals reserve Cmd for their own shortcuts and never forward it. \
             This one is optional — Home/End cover line motion, and on a MacBook \
             that's Fn+←/→.",
        ),
        "cmd_right" => none("Cmd only exists on macOS — nothing to fix here."),
        _ => none(
            "This chord didn't arrive. If even End is missing, keys aren't reaching \
             mnml at all.",
        ),
    }
}

/// What `apply_ghostty_option_as_alt` actually did, so the UI can say
/// something true rather than a generic "done".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FixOutcome {
    /// Already `true` — nothing written. The chord is failing for some
    /// other reason (or ghostty needs restarting).
    AlreadySet,
    /// An explicit `= false` (or other value) was flipped to `true`.
    Flipped,
    /// The key wasn't present; appended.
    Appended,
}

pub fn ghostty_config_path() -> Option<std::path::PathBuf> {
    // Ghostty reads $XDG_CONFIG_HOME/ghostty/config, falling back to
    // ~/.config/ghostty/config on macOS AND Linux (it does not use
    // ~/Library/Application Support for the config file).
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME")
        && !xdg.is_empty()
    {
        return Some(std::path::PathBuf::from(xdg).join("ghostty").join("config"));
    }
    let home = std::env::var("HOME").ok()?;
    Some(
        std::path::PathBuf::from(home)
            .join(".config")
            .join("ghostty")
            .join("config"),
    )
}

const OPTION_AS_ALT: &str = "macos-option-as-alt";

/// Set `macos-option-as-alt = true` in a ghostty config, preserving
/// everything else.
///
/// Ghostty's config is line-oriented `key = value`, NOT TOML — so this
/// is a targeted text edit rather than a parse/serialize round-trip,
/// which would reformat and drop the user's comments.
///
/// Writes a timestamped backup beside the file first. Deliberately does
/// NOT route through `write_toml_with_backup`: that helper writes via
/// `write_secret` (0600), and silently tightening the permissions on a
/// config file mnml doesn't own is a side effect nobody asked for.
pub fn apply_ghostty_option_as_alt(path: &std::path::Path) -> std::io::Result<FixOutcome> {
    let existing = std::fs::read_to_string(path).unwrap_or_default();

    // Find an uncommented assignment of the key.
    let hit = existing.lines().enumerate().find(|(_, line)| {
        let t = line.trim();
        !t.starts_with('#')
            && t.split('=')
                .next()
                .map(|k| k.trim() == OPTION_AS_ALT)
                .unwrap_or(false)
    });

    let (outcome, next) = match hit {
        Some((idx, line)) => {
            let val = line.split_once('=').map(|(_, v)| v.trim()).unwrap_or("");
            if val.eq_ignore_ascii_case("true") {
                return Ok(FixOutcome::AlreadySet);
            }
            let mut lines: Vec<String> = existing.lines().map(str::to_string).collect();
            lines[idx] = format!("{OPTION_AS_ALT} = true");
            (FixOutcome::Flipped, lines.join("\n") + "\n")
        }
        None => {
            let mut s = existing.clone();
            if !s.is_empty() && !s.ends_with('\n') {
                s.push('\n');
            }
            // Leave a breadcrumb — a line appearing in your terminal
            // config with no explanation is its own small mystery.
            s.push_str(
                "\n# Added by mnml (keys.doctor): send Option as Alt so\n\
                 # Option+←/→ reaches the app as a word-motion chord.\n\
                 # Without this, Option composes special characters instead.\n",
            );
            s.push_str(&format!("{OPTION_AS_ALT} = true\n"));
            (FixOutcome::Appended, s)
        }
    };

    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if path.exists() {
        let backup = path.with_extension(format!("pre-mnml-{}", crate::app::backup::utc_stamp()));
        let _ = std::fs::copy(path, &backup);
    }
    std::fs::write(path, next)?;
    Ok(outcome)
}

/// A one-line summary for the results header.
pub fn summary(doc: &KeyDoctor) -> String {
    if doc.nothing_arrived() {
        return "Nothing pressed yet — try the chords above.".to_string();
    }
    let missing = doc.missing();
    if missing.is_empty() {
        return "All chords arrive — word and line motion will work everywhere.".to_string();
    }
    let names: Vec<&str> = missing.iter().map(|p| p.label).collect();
    format!(
        "{} not arriving: {}. mnml is bound correctly; something above it is \
         intercepting.",
        missing.len(),
        names.join(", ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, mods)
    }

    #[test]
    fn observe_ticks_the_matching_probe_only() {
        let mut d = KeyDoctor::new();
        assert!(d.nothing_arrived());
        assert!(d.observe(ev(KeyCode::Right, KeyModifiers::ALT)));
        let alt_idx = PROBES.iter().position(|p| p.id == "alt_right").unwrap();
        let ctrl_idx = PROBES.iter().position(|p| p.id == "ctrl_right").unwrap();
        assert!(d.is_seen(alt_idx));
        assert!(!d.is_seen(ctrl_idx), "Alt must not tick the Ctrl probe");
        assert!(!d.nothing_arrived());
    }

    /// Shift is not a tracked bit — Shift+Alt+→ still proves ALT is
    /// being forwarded, which is the only thing the probe is asking.
    #[test]
    fn shift_does_not_prevent_a_match() {
        let mut d = KeyDoctor::new();
        assert!(d.observe(ev(KeyCode::Right, KeyModifiers::ALT | KeyModifiers::SHIFT)));
        let i = PROBES.iter().position(|p| p.id == "alt_right").unwrap();
        assert!(d.is_seen(i));
    }

    /// Ctrl+Alt+→ must not count as either Ctrl+→ or Alt+→ — it is a
    /// distinct chord, and crediting it would report a modifier as
    /// working when it isn't.
    #[test]
    fn combined_modifiers_do_not_credit_either_single_probe() {
        let mut d = KeyDoctor::new();
        assert!(!d.observe(ev(
            KeyCode::Right,
            KeyModifiers::CONTROL | KeyModifiers::ALT
        )));
        assert!(d.nothing_arrived());
    }

    #[test]
    fn unrelated_keys_are_not_swallowed() {
        let mut d = KeyDoctor::new();
        assert!(!d.observe(ev(KeyCode::Char('j'), KeyModifiers::NONE)));
        assert!(!d.observe(ev(KeyCode::Down, KeyModifiers::NONE)));
        assert!(d.nothing_arrived());
    }

    /// The control probe is excluded from all_arrived/missing — it
    /// proves the harness works, not that the environment is healthy.
    #[test]
    fn control_probe_is_excluded_from_the_verdict() {
        let mut d = KeyDoctor::new();
        for p in PROBES.iter().filter(|p| !p.is_control) {
            d.observe(ev(p.code, p.mods));
        }
        assert!(d.all_arrived());
        assert!(d.missing().is_empty());
        let end_idx = PROBES.iter().position(|p| p.id == "end").unwrap();
        assert!(
            !d.is_seen(end_idx),
            "control probe not pressed in this test"
        );
    }

    #[test]
    fn terminal_detection_prefers_term_program() {
        assert_eq!(
            detect_terminal_from(Some("ghostty"), Some("xterm-256color"), false, false),
            TerminalKind::Ghostty
        );
        assert_eq!(
            detect_terminal_from(Some("iTerm.app"), None, false, false),
            TerminalKind::ITerm2
        );
        // kitty advertises itself via TERM / KITTY_WINDOW_ID, not TERM_PROGRAM.
        assert_eq!(
            detect_terminal_from(None, Some("xterm-kitty"), false, false),
            TerminalKind::Kitty
        );
        assert_eq!(
            detect_terminal_from(None, None, true, false),
            TerminalKind::Kitty
        );
        assert_eq!(
            detect_terminal_from(None, None, false, true),
            TerminalKind::WindowsTerminal
        );
        assert_eq!(
            detect_terminal_from(None, Some("alacritty"), false, false),
            TerminalKind::Alacritty
        );
        assert_eq!(
            detect_terminal_from(None, Some("dumb"), false, false),
            TerminalKind::Unknown
        );
    }

    /// Ghostty on macOS is the one case we can fix for the user, since
    /// its config path and format are unambiguous. Everything else must
    /// be instructions only — mnml should not write a config file whose
    /// grammar it is guessing at.
    #[test]
    fn only_ghostty_on_macos_offers_an_autofix() {
        assert_eq!(
            remedy("alt_right", TerminalKind::Ghostty, true).fix,
            Some(AutoFix::GhosttyOptionAsAlt)
        );
        assert_eq!(remedy("alt_right", TerminalKind::Ghostty, false).fix, None);
        for t in [
            TerminalKind::ITerm2,
            TerminalKind::AppleTerminal,
            TerminalKind::Kitty,
            TerminalKind::WezTerm,
            TerminalKind::Alacritty,
            TerminalKind::WindowsTerminal,
            TerminalKind::Unknown,
        ] {
            assert_eq!(remedy("alt_right", t, true).fix, None, "{t:?}");
            assert!(!remedy("alt_right", t, true).text.is_empty(), "{t:?}");
        }
    }

    #[test]
    fn macos_ctrl_remedy_names_mission_control() {
        let r = remedy("ctrl_right", TerminalKind::Ghostty, true);
        assert!(r.text.contains("Mission Control"));
        // Non-macOS must not blame a macOS feature.
        let r2 = remedy("ctrl_right", TerminalKind::Alacritty, false);
        assert!(!r2.text.contains("Mission Control"));
    }

    fn write_cfg(dir: &std::path::Path, body: &str) -> std::path::PathBuf {
        let p = dir.join("config");
        std::fs::write(&p, body).unwrap();
        p
    }

    #[test]
    fn autofix_appends_when_key_is_absent_and_keeps_existing_settings() {
        let d = tempfile::tempdir().unwrap();
        let p = write_cfg(
            d.path(),
            "font-family = JetBrainsMono Nerd Font\nfont-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols\n",
        );
        assert_eq!(
            apply_ghostty_option_as_alt(&p).unwrap(),
            FixOutcome::Appended
        );
        let out = std::fs::read_to_string(&p).unwrap();
        assert!(out.contains("macos-option-as-alt = true"));
        // The user's own settings must survive untouched.
        assert!(out.contains("font-family = JetBrainsMono Nerd Font"));
        assert!(out.contains("font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols"));
    }

    #[test]
    fn autofix_flips_an_explicit_false_rather_than_appending_a_duplicate() {
        let d = tempfile::tempdir().unwrap();
        let p = write_cfg(d.path(), "macos-option-as-alt = false\nfont-size = 13\n");
        assert_eq!(
            apply_ghostty_option_as_alt(&p).unwrap(),
            FixOutcome::Flipped
        );
        let out = std::fs::read_to_string(&p).unwrap();
        assert_eq!(
            out.matches(OPTION_AS_ALT).count(),
            1,
            "must not leave two conflicting assignments: {out}"
        );
        assert!(out.contains("macos-option-as-alt = true"));
        assert!(out.contains("font-size = 13"));
    }

    #[test]
    fn autofix_is_idempotent() {
        let d = tempfile::tempdir().unwrap();
        let p = write_cfg(d.path(), "macos-option-as-alt = true\n");
        assert_eq!(
            apply_ghostty_option_as_alt(&p).unwrap(),
            FixOutcome::AlreadySet
        );
        // Second run over a file we just appended to must also no-op.
        let p2 = write_cfg(d.path(), "font-size = 13\n");
        apply_ghostty_option_as_alt(&p2).unwrap();
        assert_eq!(
            apply_ghostty_option_as_alt(&p2).unwrap(),
            FixOutcome::AlreadySet
        );
        assert_eq!(
            std::fs::read_to_string(&p2)
                .unwrap()
                .matches(OPTION_AS_ALT)
                .count(),
            1
        );
    }

    /// A commented-out line is not an assignment — treating it as one
    /// would leave the real setting unset while reporting success.
    #[test]
    fn autofix_ignores_a_commented_out_assignment() {
        let d = tempfile::tempdir().unwrap();
        let p = write_cfg(d.path(), "# macos-option-as-alt = false\nfont-size = 13\n");
        assert_eq!(
            apply_ghostty_option_as_alt(&p).unwrap(),
            FixOutcome::Appended
        );
        let out = std::fs::read_to_string(&p).unwrap();
        // The user's commented line stays exactly as they left it.
        assert!(out.contains("# macos-option-as-alt = false"));
        assert!(out.contains("\nmacos-option-as-alt = true"));
    }

    #[test]
    fn autofix_creates_the_file_and_parent_dir_when_missing() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("nested").join("ghostty").join("config");
        assert_eq!(
            apply_ghostty_option_as_alt(&p).unwrap(),
            FixOutcome::Appended
        );
        assert!(
            std::fs::read_to_string(&p)
                .unwrap()
                .contains("macos-option-as-alt = true")
        );
    }

    #[test]
    fn autofix_backs_up_the_original() {
        let d = tempfile::tempdir().unwrap();
        let p = write_cfg(d.path(), "font-size = 13\n");
        apply_ghostty_option_as_alt(&p).unwrap();
        let backups: Vec<_> = std::fs::read_dir(d.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().contains("pre-mnml-"))
            .collect();
        assert_eq!(backups.len(), 1, "expected exactly one backup");
        let body = std::fs::read_to_string(backups[0].path()).unwrap();
        assert_eq!(body, "font-size = 13\n", "backup must be the ORIGINAL");
    }

    #[test]
    fn summary_distinguishes_untried_from_broken() {
        let mut d = KeyDoctor::new();
        assert!(summary(&d).contains("Nothing pressed yet"));
        d.observe(ev(KeyCode::End, KeyModifiers::NONE));
        let s = summary(&d);
        assert!(s.contains("not arriving"), "got: {s}");
        for p in PROBES.iter().filter(|p| !p.is_control) {
            d.observe(ev(p.code, p.mods));
        }
        assert!(summary(&d).contains("All chords arrive"));
    }
}
