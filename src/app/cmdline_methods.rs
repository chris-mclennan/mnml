//! Ex-cmdline helpers + the no-pane cmdline methods (A-3 of the
//! file-split refactor — 2026-06-28).
//!
//! Owns: `compute_cmdline_completions_for_app` (the completion-
//! candidate engine used by Tab-cycle and the floating popup),
//! the substitute / line-range / undo-age parsers, plus the small
//! `App::open_ex_command_prompt` + `no_pane_cmdline_*` block.
//!
//! Extracted from `src/app/mod.rs`. Free functions are
//! `pub(crate)` and re-exported from `mod.rs` so call sites in
//! sibling files (`use super::*`) keep working.

use super::*;

/// Compute completion candidates for the current `:` cmdline —
/// used by both Tab-cycle and the floating popup. Single
/// source of truth: previous shape duplicated the first-word
/// logic in a stateless helper, which silently went stale when
/// commands moved to the registry.
///
/// - FIRST word ⇒ merged matches from
///   [`crate::input::vim::EX_COMPLETION_NAMES`] (hardcoded vim
///   ex commands) AND every id in
///   [`crate::command::registry`].
/// - Trailing arg of `:b`/`:buffer` ⇒ open-buffer display names.
/// - Trailing arg of `:colorscheme`/`:colo` ⇒ theme names.
/// - Trailing arg of a path-accepting command ⇒ workspace-rooted
///   file/dir lookup using the user's typed prefix.
pub(crate) fn compute_cmdline_completions_for_app(
    app: &App,
    line: &str,
) -> Option<CmdlineCompleteState> {
    use crate::input::vim::EX_COMPLETION_NAMES;
    let split_at = line.rfind(char::is_whitespace).map(|i| i + 1).unwrap_or(0);
    let head = &line[..split_at];
    let token = &line[split_at..];
    let first_word = head.split_whitespace().next().unwrap_or("");
    // `:b` / `:buffer <prefix>` — complete from open buffer display names.
    if !head.is_empty() && matches!(first_word, "b" | "buffer") {
        let token_lc = token.to_lowercase();
        let mut matches: Vec<String> = app
            .panes
            .iter()
            .filter_map(|p| match p {
                Pane::Editor(b) => Some(b.display_name().to_string()),
                _ => None,
            })
            .filter(|n| n.to_lowercase().contains(&token_lc) || token.is_empty())
            .collect();
        matches.sort();
        matches.dedup();
        return Some(CmdlineCompleteState {
            head: head.to_string(),
            matches,
            idx: 0,
            last_shown: String::new(),
        });
    }
    // Theme completion stays out of compute_cmdline_completions (which has
    // no App access) — handled here.
    if !head.is_empty() && matches!(first_word, "colorscheme" | "colo") {
        let mut matches: Vec<String> = crate::ui::theme::names()
            .into_iter()
            .filter(|n| n.starts_with(token))
            .map(String::from)
            .collect();
        matches.sort();
        matches.dedup();
        return Some(CmdlineCompleteState {
            head: head.to_string(),
            matches,
            idx: 0,
            last_shown: String::new(),
        });
    }
    // First word + path completers handled below.
    if head.is_empty() {
        // 2026-06-19 — tiered scoring for first-word completion.
        // Single source of truth (compute_cmdline_completions_for_app
        // is the only completer). Scoring layers high → low:
        //
        //   T1 (300): id starts with token           (`http.s` → http.send)
        //   T2 (200): id contains token as substring (`http`   → http.send)
        //   T3 (150): EX_COMPLETION_NAMES prefix     (legacy vim ex commands)
        //   T4 (100): title contains token (2+ chars) (`ag`    → ai.dashboard via "Agents")
        //
        // EX_COMPLETION_NAMES outranks title-contains so vim
        // muscle memory (`:wr` → write, `:ta` → tabclose) survives:
        // T3 (150) > T4 (100), so vim users hitting `:ta<Tab>` still
        // get `tabclose` first; the title-fuzzy matches appear below.
        // 2026-06-26 — gate lowered from 3 chars to 2. Solves the
        // "I typed a short query that should fuzzy-match a command
        // title but didn't" UX hole (e.g. `:ag` not finding
        // `ai.dashboard` because the id has no 'g').
        // Recent-commands bump (+50 most-recent, decreasing)
        // applies within tiers.
        let token_lc = token.to_lowercase();
        let mut scored: Vec<(i32, String)> = Vec::new();
        for cmd in crate::command::registry().all() {
            let mut score = 0i32;
            let id_lc = cmd.id.to_lowercase();
            if id_lc.starts_with(&token_lc) {
                score = score.max(300);
            } else if !token.is_empty() && id_lc.contains(&token_lc) {
                score = score.max(200);
            }
            if score == 0
                && token.chars().count() >= 2
                && cmd.title.to_lowercase().contains(&token_lc)
            {
                score = 100;
            }
            if score > 0 {
                if let Some(pos) = app.recent_commands.iter().position(|r| r == cmd.id) {
                    score += (50 - pos as i32).max(0);
                }
                scored.push((score, cmd.id.to_string()));
            }
        }
        for name in EX_COMPLETION_NAMES {
            if name.starts_with(token) {
                scored.push((150, name.to_string()));
            }
        }
        // Sort: higher score first; ties alphabetical.
        scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        scored.dedup_by(|a, b| a.1 == b.1);
        let matches: Vec<String> = scored.into_iter().map(|(_, s)| s).collect();
        return Some(CmdlineCompleteState {
            head: String::new(),
            matches,
            idx: 0,
            last_shown: String::new(),
        });
    }
    // 2026-06-19 — used to fall through to a separate stateless
    // `compute_cmdline_completions` helper that duplicated the
    // first-word block (and silently went stale when commands
    // moved to the registry). Folded inline: only path completion
    // is left, and it needs nothing the for_app function doesn't
    // already have.
    let path_takers = [
        "e", "edit", "sp", "split", "vs", "vsp", "vsplit", "tabnew", "tabe", "tabedit", "badd",
        "ba", "saveas", "w", "write", "source", "so", "r", "read", "Files",
    ];
    if !path_takers.contains(&first_word) {
        return Some(CmdlineCompleteState {
            head: head.to_string(),
            matches: Vec::new(),
            idx: 0,
            last_shown: String::new(),
        });
    }
    let (dir_part, stem) = match token.rfind('/') {
        Some(i) => (&token[..=i], &token[i + 1..]),
        None => ("", token),
    };
    let base = if dir_part.is_empty() {
        app.workspace.to_path_buf()
    } else if dir_part.starts_with('/') {
        Path::new(dir_part).to_path_buf()
    } else {
        app.workspace.join(dir_part)
    };
    let mut matches: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&base) {
        for ent in entries.flatten() {
            let Some(name) = ent.file_name().to_str().map(|s| s.to_string()) else {
                continue;
            };
            if !name.starts_with(stem) {
                continue;
            }
            if name.starts_with('.') && !stem.starts_with('.') {
                continue;
            }
            let is_dir = ent.file_type().map(|t| t.is_dir()).unwrap_or(false);
            let display = if is_dir {
                format!("{dir_part}{name}/")
            } else {
                format!("{dir_part}{name}")
            };
            matches.push(display);
        }
    }
    matches.sort();
    matches.dedup();
    Some(CmdlineCompleteState {
        head: head.to_string(),
        matches,
        idx: 0,
        last_shown: String::new(),
    })
}

/// Parse vim's `:earlier` / `:later` duration suffix into seconds.
/// `5s` → 5; `10m` → 600; `2h` → 7200; `1d` → 86400. Returns `None`
/// when there's no unit suffix (caller falls back to "step count").
pub(crate) fn parse_undo_age_spec(arg: &str) -> Option<u64> {
    let arg = arg.trim();
    if arg.is_empty() {
        return None;
    }
    let unit = arg.chars().last()?;
    let mult = match unit {
        's' => 1u64,
        'm' => 60,
        'h' => 3600,
        'd' => 86_400,
        _ => return None,
    };
    let num_part = &arg[..arg.len() - unit.len_utf8()];
    num_part.parse::<u64>().ok().map(|n| n * mult)
}

pub(crate) fn parse_line_range(
    line: &str,
    current_line: usize,
    line_count: usize,
) -> Option<(usize, usize, &str)> {
    // First char must look like a range opener.
    let first = line.chars().next()?;
    if !(first.is_ascii_digit() || first == '.' || first == '$') {
        return None;
    }
    // Find the boundary between the range spec and the command — the
    // first ASCII letter (other than `e` in `123,5` — handled below).
    let bytes = line.as_bytes();
    let mut split = 0usize;
    while split < bytes.len() {
        let b = bytes[split];
        // Stop at the first ASCII letter or vim-canonical command-char
        // (`>` / `<` for indent / outdent).
        if b.is_ascii_alphabetic() || b == b'>' || b == b'<' {
            break;
        }
        split += 1;
    }
    if split == 0 || split == bytes.len() {
        return None;
    }
    let spec = &line[..split];
    let remainder = &line[split..];
    // Parse the spec: `<from>` or `<from>,<to>`.
    let (from_str, to_str) = match spec.find(',') {
        Some(comma) => (&spec[..comma], &spec[comma + 1..]),
        None => (spec, spec),
    };
    let resolve = |part: &str| -> Option<usize> {
        let part = part.trim();
        if part == "$" {
            return Some(line_count.saturating_sub(1));
        }
        if part == "." || part.is_empty() {
            return Some(current_line);
        }
        if let Some(rest) = part.strip_prefix(".+") {
            let n: usize = rest.parse().ok()?;
            return Some(
                current_line
                    .saturating_add(n)
                    .min(line_count.saturating_sub(1)),
            );
        }
        if let Some(rest) = part.strip_prefix(".-") {
            let n: usize = rest.parse().ok()?;
            return Some(current_line.saturating_sub(n));
        }
        if let Some(rest) = part.strip_prefix('+') {
            let n: usize = rest.parse().ok()?;
            return Some(
                current_line
                    .saturating_add(n)
                    .min(line_count.saturating_sub(1)),
            );
        }
        if let Some(rest) = part.strip_prefix('-') {
            let n: usize = rest.parse().ok()?;
            return Some(current_line.saturating_sub(n));
        }
        // Bare number — 1-based on the wire.
        let n: usize = part.parse().ok()?;
        Some(n.saturating_sub(1).min(line_count.saturating_sub(1)))
    };
    let from = resolve(from_str)?;
    let to = resolve(to_str)?;
    let (lo, hi) = if from <= to { (from, to) } else { (to, from) };
    Some((lo, hi, remainder))
}

pub(crate) fn parse_substitute(line: &str) -> Option<Substitute> {
    // `%s/...` ⇒ buffer-wide; bare `s/...` ⇒ current-line only (vim convention).
    let (rest, whole_buffer) = if let Some(r) = line.strip_prefix("%s/") {
        (r, true)
    } else {
        let r = line.strip_prefix("s/")?;
        (r, false)
    };
    // Split into find / replace / flags on unescaped `/`. `\/` and `\\` survive.
    let mut parts: Vec<String> = Vec::with_capacity(3);
    let mut cur = String::new();
    let mut chars = rest.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('/') => cur.push('/'),
                Some('\\') => cur.push('\\'),
                Some('n') => cur.push('\n'),
                Some('t') => cur.push('\t'),
                Some(other) => {
                    cur.push('\\');
                    cur.push(other);
                }
                None => cur.push('\\'),
            }
        } else if c == '/' {
            parts.push(std::mem::take(&mut cur));
            if parts.len() == 2 {
                // Everything after the second `/` is flags (no more splits).
                let flags: String = chars.collect();
                parts.push(flags);
                break;
            }
        } else {
            cur.push(c);
        }
    }
    if parts.len() < 2 {
        // `:%s/foo` — no replacement field. Treat as `:%s/foo//` (delete).
        parts.push(String::new());
    }
    let find = parts.remove(0);
    let replace = parts.remove(0);
    let flags = parts.first().cloned().unwrap_or_default();
    // Empty find ⇒ reuse last :s find (vim canonical: `:s//foo/g`).
    // We allow the empty here; `run_substitute` resolves via `last_substitute`.
    let case_insensitive = flags.contains('i');
    let confirm = flags.contains('c');
    let count_only = flags.contains('n');
    Some(Substitute {
        find,
        replace,
        case_insensitive,
        whole_buffer,
        confirm,
        count_only,
        line_range: None,
    })
}

impl App {
    /// Begin typing an ex-command from non-pane focus — the App-
    /// level cmdline (`no_pane_cmdline`) gets populated and the
    /// bottom `cmdline_bar` paints `:<text>▏` in the same yellow
    /// style as vim's in-buffer cmdline. Enter dispatches via
    /// `run_ex_command`; Esc cancels.
    pub fn open_ex_command_prompt(&mut self) {
        self.no_pane_cmdline = Some(String::new());
    }

    /// Type a single char into the no-pane cmdline. No-op when it's
    /// closed. Caller (tree key handler) gates on
    /// `no_pane_cmdline.is_some()` before forwarding chars.
    pub fn no_pane_cmdline_push_char(&mut self, ch: char) {
        if let Some(buf) = self.no_pane_cmdline.as_mut() {
            buf.push(ch);
        }
    }

    /// Backspace one char.
    pub fn no_pane_cmdline_backspace(&mut self) {
        if let Some(buf) = self.no_pane_cmdline.as_mut() {
            buf.pop();
        }
    }

    /// Commit the typed cmdline — runs the body as an ex-command and
    /// closes the line. Empty body just closes (matches vim's
    /// Enter-on-empty behavior).
    pub fn no_pane_cmdline_commit(&mut self) {
        let Some(line) = self.no_pane_cmdline.take() else {
            return;
        };
        let line = line.trim().to_string();
        if !line.is_empty() {
            self.run_ex_command(&line);
        }
    }

    /// Esc — drop the cmdline without firing.
    pub fn no_pane_cmdline_cancel(&mut self) {
        self.no_pane_cmdline = None;
    }
}
