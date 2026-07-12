//! Key-spec parsing + the config-driven keymap resolver.
//!
//! `parse_key_spec` turns strings like `"ctrl+shift+p"`, `"enter"`, `"down"`,
//! `"a"` into `crossterm::event::KeyEvent`s (used by the IPC channel so e2e
//! scripts can send keys by name). `parse_key_seq` extends that to
//! whitespace-separated chord CHAINS — `"ctrl+k ctrl+i"` parses as two
//! events.
//!
//! [`Keymap`] is the *one table* app-level chords resolve through: built from
//! every [`crate::command::Command`]'s default `keys` and then overlaid with the
//! user's `[keys.global]` / `[keys.<input_style>]` config. `tui.rs`/`headless.rs`
//! drive it via [`Keymap::resolve_seq`] (chord-chain aware) for the dispatch
//! path, and [`Keymap::resolve`] for single-chord shortcuts (tests, single-key
//! callers that don't manage pending state).
//!
//! Chord-chain semantics — when a user starts a chain like `ctrl+k`:
//! * [`SeqResolution::Pending`] — wait for next key.
//! * [`SeqResolution::PendingWithFallback`] — the prefix is ALSO bound on its
//!   own (e.g. `ctrl+k` = `whichkey.leader` and `ctrl+k ctrl+i` = `lsp.hover`).
//!   Vim's ambiguous case: hold the prefix and wait `timeoutlen`; if a next
//!   key arrives and extends, fire the longer binding; if it doesn't extend
//!   or the timeout elapses, fire the inner. The App ticks the deadline.
//! * [`SeqResolution::Run`] — exact match, no longer binding extends it.
//!   Fire immediately.
//! * [`SeqResolution::None`] — no match at all, no pending prefix.

use std::collections::{HashMap, HashSet};

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::config::Config;

/// A normalized (code, modifiers) pair — the hashable lookup key. Normalization:
/// an uppercase `Char` is lowered and `SHIFT` made explicit, so `"P"` and
/// `"shift+p"` (and however a given terminal reports them) all collapse to the
/// same chord. The `kind`/`state` of a `KeyEvent` are dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Chord {
    pub code: KeyCode,
    pub mods: KeyModifiers,
}

impl Chord {
    pub fn of(ev: &KeyEvent) -> Chord {
        let mut mods = ev.modifiers;
        let code = match ev.code {
            KeyCode::Char(c) if c.is_ascii_uppercase() => {
                mods |= KeyModifiers::SHIFT;
                KeyCode::Char(c.to_ascii_lowercase())
            }
            other => other,
        };
        // Crossterm sometimes leaves SHIFT set on a `Char` even when the char is
        // already the shifted form on legacy terminals; the lowercasing above keeps
        // it consistent. We *don't* strip SHIFT otherwise (Ctrl+Shift+P needs it).
        Chord { code, mods }
    }

    /// Pretty-print as a key spec (`ctrl+shift+p`, `enter`, `f5`, etc.). Round-
    /// trips through [`parse_key_spec`] for the chord forms we use.
    #[allow(clippy::wrong_self_convention)] // `Chord` is Copy + small; clippy
    // wants `self`-by-value but `to_spec` reads better as `chord.to_spec()`.
    pub fn to_spec(&self) -> String {
        let mut parts: Vec<&str> = Vec::new();
        if self.mods.contains(KeyModifiers::CONTROL) {
            parts.push("ctrl");
        }
        if self.mods.contains(KeyModifiers::ALT) {
            parts.push("alt");
        }
        if self.mods.contains(KeyModifiers::SHIFT) {
            parts.push("shift");
        }
        let name = match self.code {
            KeyCode::Enter => "enter".to_string(),
            KeyCode::Tab => "tab".to_string(),
            KeyCode::BackTab => "backtab".to_string(),
            KeyCode::Esc => "esc".to_string(),
            KeyCode::Backspace => "backspace".to_string(),
            KeyCode::Delete => "delete".to_string(),
            KeyCode::Insert => "insert".to_string(),
            KeyCode::Up => "up".to_string(),
            KeyCode::Down => "down".to_string(),
            KeyCode::Left => "left".to_string(),
            KeyCode::Right => "right".to_string(),
            KeyCode::Home => "home".to_string(),
            KeyCode::End => "end".to_string(),
            KeyCode::PageUp => "pageup".to_string(),
            KeyCode::PageDown => "pagedown".to_string(),
            KeyCode::F(n) => format!("f{n}"),
            KeyCode::Char(' ') => "space".to_string(),
            KeyCode::Char(c) => c.to_string(),
            other => format!("{other:?}"),
        };
        parts.push(&name);
        parts.join("+")
    }
}

/// The resolved binding table. `resolve` is the hot path (one hashmap lookup per
/// unconsumed key event).
#[derive(Debug, Clone, Default)]
pub struct Keymap {
    /// All bindings. A length-1 `Vec` is a normal single-chord binding;
    /// longer `Vec`s are multi-chord chains like `ctrl+k ctrl+i`.
    map: HashMap<Vec<Chord>, String>,
    /// Every PROPER prefix of every bound sequence. Lets us answer
    /// "is this pending prefix worth waiting on?" in O(1) without
    /// scanning the full map. Rebuilt by [`Self::rebuild_prefixes`]
    /// whenever the map changes.
    prefixes: HashSet<Vec<Chord>>,
}

/// Result of looking up a (possibly-partial) chord sequence in the keymap.
#[derive(Debug, PartialEq, Eq)]
pub enum SeqResolution<'a> {
    /// Exact match; this is the FINAL command for the sequence. Fire it
    /// immediately and clear pending state.
    Run(&'a str),
    /// No exact match, but the sequence is a prefix of one or more longer
    /// bindings. Wait for the next key (with a timeout in case the user
    /// gave up mid-chord).
    Pending,
    /// Both: exact match exists AND the sequence is also a prefix of longer
    /// bindings. Vim's ambiguous case: wait `timeoutlen`; fire the inner
    /// command if no extending key arrives, or fire the longer binding if
    /// one does.
    PendingWithFallback(&'a str),
    /// No match, no prefix. Caller should clear pending and fall through
    /// to whatever single-key handler exists for the current key.
    None,
}

impl Keymap {
    /// Defaults from the command registry, then `[keys.global]`, then
    /// `[keys.<input_style>]` (so a mode can override a shared chord). A config
    /// value of `""` / `"none"` / `"unbound"` removes whatever was bound there.
    pub fn build(cfg: &Config) -> Keymap {
        let mut km = Keymap::default();
        // Track which command first claimed each sequence — when a later
        // command in the registry order declares the same sequence, the
        // HashMap silently overwrites and the earlier binding stops
        // firing. This bit us twice (forge chords masked by `+insert`,
        // then `ctrl+\` masked between `term.scratch_toggle` and
        // `view.split_right`) — post-fix hunt 2026-06-08. Surface
        // collisions to stderr at startup so the next one shows up
        // immediately instead of weeks later.
        let mut prior_owner: HashMap<Vec<Chord>, &'static str> = HashMap::new();
        for cmd in crate::command::registry().all() {
            for spec in cmd.keys {
                let Some(seq) = parse_key_seq(spec) else {
                    // Every chord token in the spec must parse; if
                    // any token (e.g. `ctrl++` or a bare prefix glyph
                    // `<leader>`) doesn't, the whole spec drops.
                    // Surface so the next mistake shows up in seconds.
                    eprintln!(
                        "mnml: command `{}` declares key `{spec}` that doesn't parse — chord ignored, command still palette-reachable",
                        cmd.id
                    );
                    continue;
                };
                if let Some(prev) = prior_owner.get(&seq)
                    && *prev != cmd.id
                {
                    eprintln!(
                        "mnml: keymap collision on `{spec}` — `{prev}` overridden by `{}` (drop one default to silence)",
                        cmd.id
                    );
                }
                prior_owner.insert(seq.clone(), cmd.id);
                km.map.insert(seq, cmd.id.to_string());
            }
        }
        // Vim mode reserves several chords the global keymap would otherwise
        // swallow before the buffer's input handler ever sees them:
        // `Ctrl+W` (window/split prefix), `Ctrl+G` (file info), `Ctrl+D` /
        // `Ctrl+U` (half-page motions), `Ctrl+E` / `Ctrl+Y` (line scroll —
        // 2026-06-08 nvchad hunt), `Ctrl+R` (redo — 2026-06-13 nvchad
        // SEV-1 follow-up; was firing the recent-files picker mid-edit,
        // breaking the reflexive `u u u Ctrl+R` redo flow). Standard mode
        // keeps these as `buffer.close` / `editor.goto_line` /
        // `editor.add_cursor_at_next_word` / `focus.cycle` /
        // `picker.recent`. We remove here BEFORE user `[keys.*]` overlays
        // so a user can still bind them in `[keys.vim]` if desired.
        if super::is_vim_style(cfg) {
            // nvchad-user SEV-2 (2026-06-28): mnml strips a canonical
            // set of Ctrl+<letter> chords when in vim mode so they
            // fall through to the vim INSERT/NORMAL handler instead
            // of being intercepted by the global chord chain. Each
            // has a vim meaning that the editor MUST receive:
            //   W: delete word (insert) · G: keyword-cmd / cmd-prefix
            //   D: ½ page down · U: ½ page up · E: scroll down
            //   Y: scroll up · R: redo (normal) / digraph (insert)
            //   N: keyword-completion-next (insert) — added today
            //   H: backspace (insert) — added today
            //   J: newline (insert) — added today
            //   T: indent (insert) — added today
            // mnml users access the displaced commands via palette /
            // ex / leader chords (`:s/foo/bar/g` for Ctrl+H replace;
            // `<leader>at` for Ctrl+T terminal; `<leader>Ix` /
            // palette `snippet.expand` for Ctrl+J snippet expand).
            // Ctrl+P stays bound globally (palette / recents — strong
            // nvchad muscle memory); vim users want INSERT completion-
            // prev via `Ctrl+X Ctrl+P` (omni) which is unbound globally.
            // Ctrl+S stays bound (save) — vim users save in insert too.
            // Ctrl+B stays bound (sidebar) — no canonical vim meaning.
            // nvchad-round-10 SEV-2 2026-07-12 — `ctrl+f` also
            // removed so the vim insert-mode Ctrl+F handler
            // (routes to picker.files as the `Ctrl+X Ctrl+F` file-
            // path completion analogue) can fire without the global
            // find.find binding stealing the chord first.
            for spec in [
                "ctrl+w", "ctrl+g", "ctrl+d", "ctrl+u", "ctrl+e", "ctrl+y", "ctrl+r", "ctrl+n",
                "ctrl+h", "ctrl+j", "ctrl+t", "ctrl+f",
            ] {
                if let Some(seq) = parse_key_seq(spec) {
                    km.map.remove(&seq);
                }
            }
        } else {
            // Standard-mode VS Code muscle memory: ctrl+] indents, ctrl+[
            // outdents. Override the vim-canonical bracket_match binding
            // — VS Code users press ctrl+] to indent and expect that to
            // work; the bracket-match chord can be reached via `gd` /
            // `view.bracket_match` from the palette.
            // vscode-keyboard-2026-06-10 S3-01.
            for (spec, id) in [
                ("ctrl+]", "editor.indent_line"),
                ("ctrl+[", "editor.outdent_line"),
            ] {
                if let Some(seq) = parse_key_seq(spec) {
                    km.map.insert(seq, id.to_string());
                }
            }
            // Reserve `Ctrl+L` for the standard editor's SelectLine
            // (the EditOp dispatched by `StandardInputHandler`). The
            // global `view.redraw` binding would otherwise swallow it
            // before the editor's pane handler ever sees the key —
            // vscode-keyboard-2026-06-10 S2-02. `view.redraw` stays
            // palette-reachable; the chord is the standard-mode loss.
            for spec in ["ctrl+l"] {
                if let Some(seq) = parse_key_seq(spec) {
                    km.map.remove(&seq);
                }
            }
        }
        for section in ["global", cfg.editor.input_style.as_str()] {
            if let Some(table) = cfg.keys.get(section) {
                for (key, id) in table {
                    let Some(seq) = parse_key_seq(key) else {
                        eprintln!("mnml: [keys.{section}] bad key spec {key:?} — ignored");
                        continue;
                    };
                    let id = id.trim();
                    if id.is_empty() || id == "none" || id == "unbound" {
                        km.map.remove(&seq);
                    } else {
                        km.map.insert(seq, id.to_string());
                    }
                }
            }
        }
        km.rebuild_prefixes();
        km
    }

    /// Rebuild the `prefixes` set from the current `map`. Called after every
    /// batch mutation (build, bind, etc.). O(sum of sequence lengths).
    fn rebuild_prefixes(&mut self) {
        self.prefixes.clear();
        for seq in self.map.keys() {
            for i in 1..seq.len() {
                self.prefixes.insert(seq[..i].to_vec());
            }
        }
    }

    /// Single-chord convenience lookup. Equivalent to
    /// `resolve_seq(&[Chord::of(ev)])` collapsed to Option: returns the
    /// command id only when the chord is bound on its own. For chord-chain
    /// aware dispatch (with pending state), use [`Self::resolve_seq`].
    pub fn resolve(&self, ev: &KeyEvent) -> Option<&str> {
        let chord = Chord::of(ev);
        self.map
            .get(std::slice::from_ref(&chord))
            .map(String::as_str)
    }

    /// Look up a possibly-partial chord sequence. See [`SeqResolution`] for
    /// what each variant means + how the App's dispatch path is expected to
    /// react to each one.
    pub fn resolve_seq(&self, seq: &[Chord]) -> SeqResolution<'_> {
        if seq.is_empty() {
            return SeqResolution::None;
        }
        let exact = self.map.get(seq).map(String::as_str);
        let is_prefix = self.prefixes.contains(seq);
        match (exact, is_prefix) {
            (Some(id), false) => SeqResolution::Run(id),
            (Some(id), true) => SeqResolution::PendingWithFallback(id),
            (None, true) => SeqResolution::Pending,
            (None, false) => SeqResolution::None,
        }
    }

    /// Number of bound sequences. Used by the About / Settings display.
    pub fn binding_count(&self) -> usize {
        self.map.len()
    }

    /// Iterate `(chord_seq, command_id)` pairs. Useful for `:Maps` discovery
    /// and similar listings. Order is undefined (HashMap-backed). Single-
    /// chord bindings yield a 1-element slice; chord chains yield N>1.
    pub fn iter(&self) -> impl Iterator<Item = (&[Chord], &str)> {
        self.map.iter().map(|(s, id)| (s.as_slice(), id.as_str()))
    }

    /// Bind one keyspec → command id (used for plugin-registered commands). A
    /// keyspec that doesn't parse is ignored. Overwrites any existing binding.
    /// Accepts chord chains (whitespace-separated tokens).
    pub fn bind(&mut self, spec: &str, id: &str) {
        if let Some(seq) = parse_key_seq(spec) {
            self.map.insert(seq, id.to_string());
            self.rebuild_prefixes();
        }
    }
}

/// Render a chord sequence to its canonical spec string. The inverse of
/// [`parse_key_seq`] up to canonical-form differences (`shift+p` vs `P`).
/// Used by help / cheatsheet rendering.
pub fn chord_seq_to_spec(seq: &[Chord]) -> String {
    seq.iter()
        .map(|c| c.to_spec())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Parse a chord-chain spec — one or more whitespace-separated chords.
/// Returns None if any individual chord token fails to parse. Single-token
/// specs (the common case) yield a length-1 vec.
pub fn parse_key_seq(spec: &str) -> Option<Vec<Chord>> {
    let mut out = Vec::new();
    for tok in spec.split_whitespace() {
        let ev = parse_key_spec(tok)?;
        out.push(Chord::of(&ev));
    }
    if out.is_empty() { None } else { Some(out) }
}

/// Parse a key spec. Modifiers (`ctrl+`, `shift+`, `alt+`) may prefix in any
/// order; the final token is a named key or a single character. Returns `None`
/// for anything unrecognized.
pub fn parse_key_spec(spec: &str) -> Option<KeyEvent> {
    let spec = spec.trim();
    if spec.is_empty() {
        return None;
    }
    let mut mods = KeyModifiers::NONE;
    let mut rest = spec;
    loop {
        let lower = rest.to_ascii_lowercase();
        if let Some(r) = lower
            .strip_prefix("ctrl+")
            .or_else(|| lower.strip_prefix("c-"))
        {
            mods |= KeyModifiers::CONTROL;
            rest = &rest[rest.len() - r.len()..];
        } else if let Some(r) = lower
            .strip_prefix("shift+")
            .or_else(|| lower.strip_prefix("s-"))
        {
            mods |= KeyModifiers::SHIFT;
            rest = &rest[rest.len() - r.len()..];
        } else if let Some(r) = lower
            .strip_prefix("alt+")
            .or_else(|| lower.strip_prefix("a-"))
            .or_else(|| lower.strip_prefix("meta+"))
        {
            mods |= KeyModifiers::ALT;
            rest = &rest[rest.len() - r.len()..];
        } else if let Some(r) = lower
            .strip_prefix("super+")
            .or_else(|| lower.strip_prefix("cmd+"))
            .or_else(|| lower.strip_prefix("win+"))
        {
            // macOS Command key / Linux Super key / Windows Win key.
            // Crossterm reports them as SUPER on platforms that
            // forward the modifier (mostly Kitty / WezTerm protocol).
            // On terminals that don't, the key spec parses but the
            // chord never fires — the user can still bind via
            // [keys.global] and it'll just be inert. Without this
            // arm the spec doesn't parse at all and the chord-warn
            // surfaces a startup eprintln for every cmd+ default.
            // 2026-06-13 vscode-keyboard follow-up.
            mods |= KeyModifiers::SUPER;
            rest = &rest[rest.len() - r.len()..];
        } else {
            break;
        }
    }
    let code = key_code(rest)?;
    Some(KeyEvent::new(code, mods))
}

fn key_code(token: &str) -> Option<KeyCode> {
    let t = token.to_ascii_lowercase();
    Some(match t.as_str() {
        "enter" | "return" | "cr" => KeyCode::Enter,
        "tab" => KeyCode::Tab,
        "backtab" => KeyCode::BackTab,
        "esc" | "escape" => KeyCode::Esc,
        "space" | "leader" => KeyCode::Char(' '),
        "backspace" | "bs" => KeyCode::Backspace,
        "delete" | "del" => KeyCode::Delete,
        "insert" | "ins" => KeyCode::Insert,
        "up" => KeyCode::Up,
        "down" => KeyCode::Down,
        "left" => KeyCode::Left,
        "right" => KeyCode::Right,
        "home" => KeyCode::Home,
        "end" => KeyCode::End,
        "pageup" | "pgup" => KeyCode::PageUp,
        "pagedown" | "pgdn" | "pgdown" => KeyCode::PageDown,
        "f1" => KeyCode::F(1),
        "f2" => KeyCode::F(2),
        "f3" => KeyCode::F(3),
        "f4" => KeyCode::F(4),
        "f5" => KeyCode::F(5),
        "f6" => KeyCode::F(6),
        "f7" => KeyCode::F(7),
        "f8" => KeyCode::F(8),
        "f9" => KeyCode::F(9),
        "f10" => KeyCode::F(10),
        "f11" => KeyCode::F(11),
        "f12" => KeyCode::F(12),
        _ => {
            let mut chars = token.chars();
            let c = chars.next()?;
            if chars.next().is_some() {
                return None; // multi-char and not a known name
            }
            KeyCode::Char(c)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_modified_and_named() {
        let e = parse_key_spec("ctrl+q").unwrap();
        assert_eq!(e.code, KeyCode::Char('q'));
        assert!(e.modifiers.contains(KeyModifiers::CONTROL));
        assert_eq!(parse_key_spec("enter").unwrap().code, KeyCode::Enter);
        assert_eq!(parse_key_spec("down").unwrap().code, KeyCode::Down);
        let e = parse_key_spec("ctrl+shift+p").unwrap();
        assert!(
            e.modifiers.contains(KeyModifiers::CONTROL)
                && e.modifiers.contains(KeyModifiers::SHIFT)
        );
        assert_eq!(parse_key_spec("a").unwrap().code, KeyCode::Char('a'));
        assert!(parse_key_spec("nope-not-a-key").is_none());
    }

    #[test]
    fn leader_alias_maps_to_space() {
        // #polish 2026-07-06 — from nvchad-user audit. `leader` is the
        // vim canonical name for the leader chord; every doc / test
        // says `<leader>ff` — IPC parser must accept it as an alias
        // for space so agent-driven .test scripts translate 1:1.
        assert_eq!(parse_key_spec("leader").unwrap().code, KeyCode::Char(' '));
        // Modifier + leader also parses (unusual but no reason to
        // reject).
        assert_eq!(
            parse_key_spec("ctrl+leader").unwrap().code,
            KeyCode::Char(' ')
        );
    }

    #[test]
    fn chord_normalizes_uppercase_char() {
        // `"P"` typed and `"shift+p"` typed must collapse to the same chord.
        let a = Chord::of(&KeyEvent::new(KeyCode::Char('P'), KeyModifiers::NONE));
        let b = Chord::of(&KeyEvent::new(KeyCode::Char('p'), KeyModifiers::SHIFT));
        assert_eq!(a, b);
        assert_eq!(a.code, KeyCode::Char('p'));
        assert!(a.mods.contains(KeyModifiers::SHIFT));
    }

    #[test]
    fn default_keymap_has_builtin_chords() {
        let km = Keymap::build(&Config::default());
        let ev = |s: &str| parse_key_spec(s).unwrap();
        assert_eq!(km.resolve(&ev("ctrl+q")), Some("app.quit"));
        assert_eq!(km.resolve(&ev("ctrl+p")), Some("picker.files"));
        // F1 used to also bind palette; the 2026-06-08 collision
        // cleanup kept F1 on view.help only (universal Help
        // convention). Palette is Ctrl+Shift+P / `Ctrl+K p` / the
        // `:` cmdline.
        assert_eq!(km.resolve(&ev("f1")), Some("view.help"));
        assert_eq!(km.resolve(&ev("ctrl+shift+p")), Some("palette"));
        assert_eq!(km.resolve(&ev("ctrl+b")), Some("view.toggle_tree"));
        assert_eq!(km.resolve(&ev("ctrl+z")), None);
    }

    #[test]
    fn config_overlays_and_unbinds() {
        let mut cfg = Config::default();
        let mut global = std::collections::BTreeMap::new();
        global.insert("ctrl+;".to_string(), "palette".to_string()); // add
        global.insert("ctrl+p".to_string(), "none".to_string()); // unbind
        global.insert("ctrl+b".to_string(), "tree.refresh".to_string()); // rebind
        cfg.keys.insert("global".to_string(), global);
        let km = Keymap::build(&cfg);
        let ev = |s: &str| parse_key_spec(s).unwrap();
        assert_eq!(km.resolve(&ev("ctrl+;")), Some("palette"));
        assert_eq!(km.resolve(&ev("ctrl+p")), None);
        assert_eq!(km.resolve(&ev("ctrl+b")), Some("tree.refresh"));
        // a default that wasn't touched still resolves
        assert_eq!(km.resolve(&ev("f1")), Some("view.help"));
    }

    #[test]
    fn input_style_section_overrides_global() {
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        cfg.keys.insert(
            "global".to_string(),
            std::collections::BTreeMap::from([("ctrl+g".to_string(), "app.quit".to_string())]),
        );
        cfg.keys.insert(
            "vim".to_string(),
            std::collections::BTreeMap::from([("ctrl+g".to_string(), "tree.refresh".to_string())]),
        );
        let km = Keymap::build(&cfg);
        assert_eq!(
            km.resolve(&parse_key_spec("ctrl+g").unwrap()),
            Some("tree.refresh")
        );
    }

    fn chord(spec: &str) -> Chord {
        Chord::of(&parse_key_spec(spec).unwrap())
    }

    #[test]
    fn parse_key_seq_handles_single_and_multi_token() {
        assert_eq!(parse_key_seq("ctrl+a").unwrap().len(), 1);
        let seq = parse_key_seq("ctrl+k ctrl+i").unwrap();
        assert_eq!(seq.len(), 2);
        assert_eq!(seq[0], chord("ctrl+k"));
        assert_eq!(seq[1], chord("ctrl+i"));
    }

    #[test]
    fn parse_key_seq_rejects_bad_token() {
        // Whole seq fails if any token doesn't parse.
        assert!(parse_key_seq("ctrl+k bogus").is_none());
        assert!(parse_key_seq("").is_none());
    }

    #[test]
    fn resolve_seq_returns_run_for_exact_match() {
        let km = Keymap::build(&Config::default());
        // F1 is a single-key binding.
        assert_eq!(
            km.resolve_seq(&[chord("f1")]),
            SeqResolution::Run("view.help")
        );
    }

    #[test]
    fn resolve_seq_returns_none_for_unbound() {
        let km = Keymap::build(&Config::default());
        // `ctrl+z` is intentionally not bound in the registry — confirmed
        // by the existing `default_keymap_has_builtin_chords` test below.
        assert_eq!(km.resolve_seq(&[chord("ctrl+z")]), SeqResolution::None);
        // Empty sequence is None too.
        assert_eq!(km.resolve_seq(&[]), SeqResolution::None);
    }

    #[test]
    fn resolve_seq_returns_pending_with_fallback_for_chain_prefix() {
        // `ctrl+k` is bound to `whichkey.leader` AND is the prefix of
        // `ctrl+k ctrl+i` → `lsp.hover`. Resolving just `[ctrl+k]` should
        // return PendingWithFallback with the leader as fallback.
        let km = Keymap::build(&Config::default());
        match km.resolve_seq(&[chord("ctrl+k")]) {
            SeqResolution::PendingWithFallback(fb) => assert_eq!(fb, "whichkey.leader"),
            other => panic!("expected PendingWithFallback, got {other:?}"),
        }
        // The full chain resolves to the longer command.
        assert_eq!(
            km.resolve_seq(&[chord("ctrl+k"), chord("ctrl+i")]),
            SeqResolution::Run("lsp.hover")
        );
    }

    #[test]
    fn resolve_seq_pending_alone_when_prefix_has_no_leaf() {
        // Build a keymap where the only binding is a chord chain whose
        // prefix is NOT itself bound. The intermediate state should be
        // `Pending` (no fallback), not `PendingWithFallback`.
        let mut km = Keymap::default();
        km.map
            .insert(parse_key_seq("alt+q alt+z").unwrap(), "test.cmd".into());
        km.rebuild_prefixes();
        assert_eq!(km.resolve_seq(&[chord("alt+q")]), SeqResolution::Pending);
        assert_eq!(
            km.resolve_seq(&[chord("alt+q"), chord("alt+z")]),
            SeqResolution::Run("test.cmd")
        );
    }

    #[test]
    fn chord_seq_to_spec_joins_with_spaces() {
        let seq = vec![chord("ctrl+k"), chord("ctrl+i")];
        assert_eq!(chord_seq_to_spec(&seq), "ctrl+k ctrl+i");
        let lone = vec![chord("f5")];
        assert_eq!(chord_seq_to_spec(&lone), "f5");
    }
}
