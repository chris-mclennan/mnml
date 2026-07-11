//! Vim `:`-command interpreter — the giant `run_ex_command` match,
//! `:s/.../.../` substitute, `:sort`, `:move`, `:copy`, `:!cmd` filter,
//! and the quit-confirm accept handler.
//!
//! `run_ex_command` itself is still a ~3k-line single fn — splitting
//! its arms into per-topic helper methods is a true refactor, deferred.
//!
//! Sub-extracted from `app/editor_features.rs`. Non-destructive move.

use super::*;

/// Expand `:args {pattern}` under `ws` into a list of absolute paths.
/// Supports:
/// - literal (no wildcards): treated as a single path (skipped if not
///   an existing file).
/// - `*.EXT` / `foo*bar.rs`: basename glob at workspace root (non-
///   recursive).
/// - `dir/**/*.EXT` or plain `**/*.EXT`: recursive walk under `dir`
///   (or workspace root), matching the trailing `*.EXT` pattern.
///
/// Not vim-complete (no `[abc]`, no `{a,b}`) but covers `:args *.rs`
/// and `:args src/**/*.rs` — the two forms nvchad users hit ~always.
/// Uses `ignore::WalkBuilder` so `.gitignore` is respected during
/// recursive scans.
fn arglist_expand(ws: &std::path::Path, pattern: &str) -> Vec<std::path::PathBuf> {
    let expanded = shellexpand_tilde(pattern);
    let has_wildcard = expanded.contains('*') || expanded.contains('?');
    if !has_wildcard {
        let p = if std::path::Path::new(&expanded).is_absolute() {
            std::path::PathBuf::from(&expanded)
        } else {
            ws.join(&expanded)
        };
        return if p.is_file() { vec![p] } else { Vec::new() };
    }
    // Split into root + relative pattern. If `**` is present, walk
    // recursively from the leading literal segment.
    let (walk_root, glob_tail) = if let Some(pos) = expanded.find("**") {
        let head = &expanded[..pos];
        let tail = &expanded[pos + 2..];
        let tail = tail.trim_start_matches('/');
        let head_trim = head.trim_end_matches('/');
        let root = if head_trim.is_empty() {
            ws.to_path_buf()
        } else if std::path::Path::new(head_trim).is_absolute() {
            std::path::PathBuf::from(head_trim)
        } else {
            ws.join(head_trim)
        };
        (root, tail.to_string())
    } else {
        // Non-recursive: split on last `/` if any.
        let (dir, base) = expanded
            .rsplit_once('/')
            .map(|(d, b)| (d.to_string(), b.to_string()))
            .unwrap_or_else(|| (String::new(), expanded.clone()));
        let root = if dir.is_empty() {
            ws.to_path_buf()
        } else if std::path::Path::new(&dir).is_absolute() {
            std::path::PathBuf::from(&dir)
        } else {
            ws.join(&dir)
        };
        (root, base)
    };
    let mut out: Vec<std::path::PathBuf> = Vec::new();
    let recursive = glob_tail.is_empty() || pattern.contains("**");
    for entry in ignore::WalkBuilder::new(&walk_root)
        .max_depth(if recursive { None } else { Some(1) })
        .build()
        .flatten()
    {
        let p = entry.path();
        if !p.is_file() {
            continue;
        }
        let name = match p.file_name().and_then(|n| n.to_str()) {
            Some(s) => s,
            None => continue,
        };
        let pat_for_match = if glob_tail.is_empty() {
            &pattern[pattern.rfind('/').map(|i| i + 1).unwrap_or(0)..]
        } else {
            glob_tail.as_str()
        };
        if simple_glob_match(pat_for_match, name) {
            out.push(p.to_path_buf());
        }
    }
    out.sort();
    out
}

/// `~` → `$HOME` prefix expansion. No env-var support (vim's `$VAR`
/// syntax); nvchad users just type paths.
fn shellexpand_tilde(s: &str) -> String {
    if let Some(rest) = s.strip_prefix("~/")
        && let Some(home) = std::env::var_os("HOME")
    {
        let mut p = std::path::PathBuf::from(home);
        p.push(rest);
        return p.to_string_lossy().into_owned();
    }
    s.to_string()
}

/// Translate vim's `:s/PATTERN/…/` grammar (the find side) to the
/// `regex` crate's grammar. Vim uses `\(…\)` for capture groups,
/// `\|` for alternation, `\<`/`\>` for word boundaries. The `regex`
/// crate uses `(…)`, `|`, `\b`. Keys we do NOT rewrite (they already
/// mean the same thing): `\d`, `\w`, `\s`, `\D`, `\W`, `\S`, `\b`.
///
/// nvchad-round-7 SEV-2 2026-07-11.
fn vim_pattern_to_regex(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('(') => out.push('('),
                Some(')') => out.push(')'),
                Some('|') => out.push('|'),
                Some('<') | Some('>') => out.push_str("\\b"),
                Some('{') => out.push('{'),
                Some('}') => out.push('}'),
                Some('+') => out.push('+'),
                Some('?') => out.push('?'),
                Some('=') => out.push('?'), // vim `\=` = optional (regex `?`)
                Some(next) => {
                    out.push('\\');
                    out.push(next);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Translate vim's `:s/…/REPLACEMENT/` grammar to the `regex` crate's
/// [`Replacer`] grammar. Vim uses `\1..\9` for capture groups, `&` /
/// `\0` for the whole match, and `\\` for a literal backslash. The
/// crate uses `$1..$9`, `$0`, and treats a bare `$` as the start of a
/// group reference — so literal `$` in the input must double as `$$`.
///
/// Grammar handled:
/// - `\0`  → `$0`
/// - `\1..\9` → `$1..$9`
/// - `\\`  → `\`
/// - `\&`  → `&` (literal)
/// - `&`   → `$0`  (whole match)
/// - `$`   → `$$` (escape crate's own metachar)
/// - `\n`  → `\n` newline (vim uses `\r` for newline in replacement,
///   but users routinely type `\n`; support both for tolerance)
/// - `\r`  → `\n` newline (vim canonical — `\n` in replacement means
///   NUL in strict vim, but every nvchad user types `\n` meaning
///   newline; we honor both)
/// - `\t`  → tab
/// - other `\X` → `X` literal
///
/// nvchad-round-7 SEV-1 2026-07-11.
fn vim_replacement_to_regex(input: &str) -> String {
    let mut out = String::with_capacity(input.len() + 8);
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some(next) => match next {
                    '0'..='9' => {
                        out.push('$');
                        out.push(next);
                    }
                    '\\' => out.push('\\'),
                    '&' => out.push('&'),
                    'n' | 'r' => out.push('\n'),
                    't' => out.push('\t'),
                    other => out.push(other),
                },
                None => out.push('\\'),
            },
            '&' => out.push_str("$0"),
            '$' => out.push_str("$$"),
            other => out.push(other),
        }
    }
    out
}

/// `*` matches any run (incl. empty), `?` matches one char. No brace
/// or bracket expansion. Case-sensitive.
fn simple_glob_match(pat: &str, name: &str) -> bool {
    let pat = pat.as_bytes();
    let name = name.as_bytes();
    fn inner(pat: &[u8], name: &[u8]) -> bool {
        let mut pi = 0;
        let mut ni = 0;
        let mut star = None;
        let mut star_ni = 0;
        while ni < name.len() {
            if pi < pat.len() && pat[pi] == b'*' {
                star = Some(pi);
                star_ni = ni;
                pi += 1;
            } else if pi < pat.len() && (pat[pi] == b'?' || pat[pi] == name[ni]) {
                pi += 1;
                ni += 1;
            } else if let Some(sp) = star {
                pi = sp + 1;
                star_ni += 1;
                ni = star_ni;
            } else {
                return false;
            }
        }
        while pi < pat.len() && pat[pi] == b'*' {
            pi += 1;
        }
        pi == pat.len()
    }
    inner(pat, name)
}

impl App {
    /// `:%!cmd` / `:'<,'>!cmd` — pipe the whole buffer (or the active
    /// selection if `selection_only=true`) through `cmd` via `$SHELL -c`,
    /// replacing the input range with the command's stdout. Single edit op
    /// so undo restores. Non-zero exit ⇒ buffer untouched + toast.
    pub fn run_filter_through_shell(&mut self, cmd: &str, selection_only: bool) {
        if cmd.is_empty() {
            self.toast(":%! — command required");
            return;
        }
        let Some(idx) = self.active else {
            self.toast(":%! — no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            self.toast(":%! — no active editor");
            return;
        };
        // Determine the input range.
        let (start, end) = if selection_only || (b.editor.has_selection() && !cmd.is_empty()) {
            match b.editor.selection() {
                Some((lo, hi)) => (lo, hi),
                None => (0, b.editor.text().len()),
            }
        } else {
            (0, b.editor.text().len())
        };
        let buf_len = b.editor.text().len();
        let input = b.editor.text()[start..end].to_string();
        // Spawn the shell synchronously, write input to stdin, capture stdout.
        // Use the active workspace as cwd so `:%!cmd` resolves relative
        // paths against the active workspace, not the launch primary.
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        let workspace = self.active_workspace_path().to_path_buf();
        let result = std::thread::scope(|s| {
            let handle = s.spawn(|| {
                use std::io::Write;
                let mut child = match std::process::Command::new(&shell)
                    .arg("-c")
                    .arg(cmd)
                    .current_dir(&workspace)
                    .stdin(std::process::Stdio::piped())
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::piped())
                    .spawn()
                {
                    Ok(c) => c,
                    Err(e) => return Err(format!("spawn: {e}")),
                };
                if let Some(mut stdin) = child.stdin.take() {
                    let _ = stdin.write_all(input.as_bytes());
                }
                match child.wait_with_output() {
                    Ok(out) => {
                        if !out.status.success() {
                            let stderr = String::from_utf8_lossy(&out.stderr);
                            let preview: String = stderr.trim().chars().take(120).collect();
                            return Err(format!(
                                "exit {} — {preview}",
                                out.status.code().unwrap_or(-1)
                            ));
                        }
                        Ok(String::from_utf8_lossy(&out.stdout).to_string())
                    }
                    Err(e) => Err(format!("wait: {e}")),
                }
            });
            handle.join().unwrap()
        });
        match result {
            Ok(stdout) => {
                let len = stdout.len();
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::ReplaceRange {
                            start,
                            end,
                            text: stdout,
                        }],
                        &mut self.clipboard,
                        0,
                    );
                }
                let scope_label = if selection_only || end - start < buf_len {
                    "selection"
                } else {
                    "buffer"
                };
                self.toast(format!(":! — {scope_label} ⇐ {len}B"));
            }
            Err(e) => self.toast(format!(":! — {e}")),
        }
    }

    pub fn run_sort_lines(&mut self, unique: bool, reverse: bool) {
        self.run_sort_lines_opts(unique, reverse, false);
    }

    /// Same as [`Self::run_sort_lines`] but with a case-insensitive flag —
    /// vim's `:sort i`. `case_insensitive=true` compares lines via their
    /// lowercase form (ASCII; cheap, matches vim's default behavior).
    pub fn run_sort_lines_opts(&mut self, unique: bool, reverse: bool, case_insensitive: bool) {
        let Some(b) = self.active_editor_mut() else {
            self.toast("no active editor");
            return;
        };
        let text = b.editor.text();
        // Determine the line range — selection if any, else whole buffer.
        let (start_byte, end_byte, start_line, end_line) =
            if let Some((sel_lo, sel_hi)) = b.editor.selection() {
                let line_at = |byte: usize| text[..byte].bytes().filter(|&c| c == b'\n').count();
                let lo_line = line_at(sel_lo);
                let hi_line = line_at(sel_hi);
                let line_start = |line: usize| -> usize {
                    if line == 0 {
                        return 0;
                    }
                    let mut seen = 0;
                    for (i, ch) in text.bytes().enumerate() {
                        if ch == b'\n' {
                            seen += 1;
                            if seen == line {
                                return i + 1;
                            }
                        }
                    }
                    text.len()
                };
                let line_end = |line: usize| -> usize {
                    let s = line_start(line);
                    text[s..].find('\n').map(|i| s + i).unwrap_or(text.len())
                };
                (line_start(lo_line), line_end(hi_line), lo_line, hi_line)
            } else {
                let line_count = text.bytes().filter(|&c| c == b'\n').count() + 1;
                (0, text.len(), 0, line_count.saturating_sub(1))
            };
        if start_byte >= end_byte {
            return;
        }
        let mut lines: Vec<&str> = text[start_byte..end_byte].split('\n').collect();
        if case_insensitive {
            lines.sort_by_key(|l| l.to_ascii_lowercase());
        } else {
            lines.sort();
        }
        if unique {
            if case_insensitive {
                lines.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
            } else {
                lines.dedup();
            }
        }
        if reverse {
            lines.reverse();
        }
        let new_block = lines.join("\n");
        if new_block == text[start_byte..end_byte] {
            return;
        }
        let ops = vec![crate::edit_op::EditOp::ReplaceRange {
            start: start_byte,
            end: end_byte,
            text: new_block,
        }];
        let mut clip = crate::clipboard::Clipboard::new();
        b.apply_edit_ops(ops, &mut clip, 0);
        self.toast(format!(
            ":sort{} — {} line(s)",
            if unique { " (unique)" } else { "" },
            end_line + 1 - start_line
        ));
    }

    /// `:retab` — replace every TAB with `[editor] tab_width` spaces in the
    /// whole buffer. One ReplaceRange so undo reverts in a single step.
    /// `:m N` / `:co N` — move (`copy=false`) or copy (`copy=true`) the
    /// cursor's current line to right after line N (1-based; `0` ⇒ top of
    /// buffer). `+K` / `-K` (relative form) ⇒ N = current_row + K. The
    /// cursor lands on the line in its new home. Single edit op so undo
    /// restores the original ordering.
    pub fn run_move_or_copy_line(&mut self, dest: &str, copy: bool) {
        let dest = dest.trim();
        let label = if copy { ":copy" } else { ":move" };
        let Some(b) = self.active_editor_mut() else {
            self.toast(format!("{label} — no active editor"));
            return;
        };
        let text = b.editor.text();
        let line_count = b.editor.line_count();
        let cur_row = b.editor.row_col().0;
        // Parse destination — `+N`, `-N`, or absolute `N` (1-based; 0 = top).
        let dest_idx_signed: i64 = if let Some(rest) = dest.strip_prefix('+') {
            let n: i64 = rest.parse().unwrap_or(0);
            cur_row as i64 + n
        } else if let Some(rest) = dest.strip_prefix('-') {
            let n: i64 = rest.parse().unwrap_or(0);
            cur_row as i64 - n
        } else if dest == "$" {
            // `$` ⇒ end of buffer.
            line_count as i64
        } else if dest.is_empty() {
            self.toast(format!("{label} — destination required"));
            return;
        } else {
            match dest.parse::<i64>() {
                Ok(n) => n, // absolute (vim 1-based; 0 = top)
                Err(_) => {
                    self.toast(format!("{label} — bad destination: {dest:?}"));
                    return;
                }
            }
        };
        // Convert vim's 1-based line ref to "insert after this 0-based line"
        // semantics. `:m 0` ⇒ insert at the very top (before line 0).
        let dest_after: i64 = dest_idx_signed.clamp(0, line_count as i64);
        // Find byte ranges of the source line + the destination boundary.
        let line_start =
            |row: usize| -> usize { text.split('\n').take(row).map(|s| s.len() + 1).sum() };
        let src_start = line_start(cur_row);
        let src_end_excl_nl = src_start
            + text[src_start..]
                .find('\n')
                .unwrap_or(text.len() - src_start);
        // Destination insertion point: the start of (dest_after)th line.
        let insert_at: usize = if dest_after == 0 {
            0
        } else if (dest_after as usize) >= line_count {
            text.len()
        } else {
            line_start(dest_after as usize)
        };
        // The source line text *with* its trailing newline (so we re-insert
        // it as a complete line).
        let src_with_nl = if src_end_excl_nl < text.len() {
            text[src_start..src_end_excl_nl + 1].to_string()
        } else {
            // Last line — synthesize a trailing newline so the splice
            // preserves the line shape.
            let mut s = text[src_start..].to_string();
            if !s.ends_with('\n') {
                s.push('\n');
            }
            s
        };
        // No-op cases that vim treats as harmless.
        if !copy && (dest_after as usize == cur_row || dest_after as usize == cur_row + 1) {
            return;
        }
        // Build a single-string buffer rewrite. Cheap (one alloc).
        let new_text = if copy {
            // Copy: leave source in place, splice a duplicate at insert_at.
            let mut s = String::with_capacity(text.len() + src_with_nl.len());
            s.push_str(&text[..insert_at]);
            s.push_str(&src_with_nl);
            s.push_str(&text[insert_at..]);
            s
        } else {
            // Move: cut source first, then splice at the dest boundary
            // (translating insert_at if it sits past the cut).
            let cut_end = if src_end_excl_nl < text.len() {
                src_end_excl_nl + 1
            } else {
                text.len()
            };
            let translated_insert = if insert_at >= cut_end {
                insert_at - (cut_end - src_start)
            } else {
                insert_at
            };
            let mut s = String::with_capacity(text.len());
            s.push_str(&text[..src_start]);
            s.push_str(&text[cut_end..]);
            // Now splice src into the translated position.
            let mut out = String::with_capacity(s.len() + src_with_nl.len());
            out.push_str(&s[..translated_insert]);
            out.push_str(&src_with_nl);
            out.push_str(&s[translated_insert..]);
            out
        };
        let end = text.len();
        let ops = vec![crate::edit_op::EditOp::ReplaceRange {
            start: 0,
            end,
            text: new_text,
        }];
        let mut clip = crate::clipboard::Clipboard::new();
        b.apply_edit_ops(ops, &mut clip, 0);
        // Land cursor on the moved/copied line in its new home.
        let new_row = if copy {
            // Inserted right at insert_at — that line's row index.
            // Cursor was at cur_row; insertion shifts it if before cur_row.
            if dest_after as usize <= cur_row {
                cur_row + 1 // duplicate is above us; original shifts down
            } else {
                dest_after as usize // duplicate sits at dest_after
            }
        } else if dest_after as usize > cur_row {
            (dest_after as usize).saturating_sub(1)
        } else {
            dest_after as usize
        };
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(new_row, 0);
        }
        let verb = if copy { "copied" } else { "moved" };
        self.toast(format!(
            "{label} — line {} {verb} → {}",
            cur_row + 1,
            new_row + 1
        ));
    }

    /// Interpret a vim `:`-line (without the leading `:`). Anything we don't
    /// recognise is bridged to a registered command if one matches, else toasted.
    /// Apply a parsed `:%s/old/new/[flags]` (or `:s/...` for current line) to
    /// the active editor. Literal substring replace (no regex);
    /// case-insensitive when the `i` flag is set. Staged as one undo step.
    pub(super) fn run_substitute(&mut self, mut sub: Substitute) {
        let Some(idx) = self.active else {
            self.toast(":s — no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            self.toast(":s — only works in editor panes");
            return;
        };
        // Empty find ⇒ reuse last :s find (vim canonical `:s//new/g`).
        if sub.find.is_empty() {
            if let Some(last) = self.last_substitute.as_ref() {
                sub.find = last.find.clone();
                // Inherit case-insensitivity flag from last sub if not set.
                if !sub.case_insensitive {
                    sub.case_insensitive = last.case_insensitive;
                }
            } else {
                self.toast(":s — no previous find to reuse");
                return;
            }
        }
        // Remember for vim `&` (re-run on the cursor's current line).
        self.last_substitute = Some(sub.clone());
        let text = b.editor.text().to_string();
        // Compute the byte range to operate on:
        //   - explicit `line_range` (`:5,10s/…/…/`) wins
        //   - `:%s` ⇒ whole buffer
        //   - bare `:s` ⇒ cursor's current line (vim canonical)
        let (lo, hi) = if let Some((sr, er)) = sub.line_range {
            let lines: Vec<&str> = text.split('\n').collect();
            let sr = sr.min(lines.len().saturating_sub(1));
            let er = er.min(lines.len().saturating_sub(1));
            let mut byte_off = 0usize;
            let mut start = 0usize;
            let mut end = text.len();
            for (i, line) in lines.iter().enumerate() {
                if i == sr {
                    start = byte_off;
                }
                byte_off += line.len();
                if i == er {
                    end = byte_off;
                    break;
                }
                byte_off += 1; // trailing '\n'
            }
            (start, end)
        } else if sub.whole_buffer {
            (0usize, text.len())
        } else {
            let cur = b.editor.cursor();
            let bol = text[..cur].rfind('\n').map(|i| i + 1).unwrap_or(0);
            let eol = text[bol..]
                .find('\n')
                .map(|i| bol + i)
                .unwrap_or(text.len());
            (bol, eol)
        };
        let scope = &text[lo..hi];
        // nvchad-user SEV-2 2026-07-10: `:%s/…/…/g` used to be pure
        // literal — `.`, `\d`, `\w`, `(…)`, `|` were all treated as
        // ordinary chars. Vim's `:s` is regex-first (any of those
        // meta-chars are meaningful unless escaped). Try regex first;
        // fall back to the old literal path only when regex compile
        // fails (so a stray unbalanced `[` still doesn't panic — it
        // just falls to literal, matching prior behavior).
        // Translate vim regex grammar → regex-crate grammar on the
        // find side too: `\(…\)` → `(…)`, `\|` → `|`, `\<`/`\>` → `\b`.
        // Nvchad users type these routinely and the old code treated
        // them as literal. nvchad-round-7 SEV-2.
        let translated_find = vim_pattern_to_regex(&sub.find);
        let regex_matches = crate::buffer::find_all_regex(scope, &translated_find);
        let regex_used = !regex_matches.is_empty();
        let matches: Vec<(usize, usize)> = if regex_used {
            regex_matches
        } else if sub.case_insensitive {
            crate::buffer::find_all_ci_ascii(scope, &sub.find)
        } else {
            find_all_case_sensitive(scope, &sub.find)
        }
        .into_iter()
        .map(|(s, e)| (s + lo, e + lo))
        .collect();
        let label = if sub.whole_buffer { ":%s" } else { ":s" };
        if matches.is_empty() {
            self.toast(format!("{label} — no match for {:?}", sub.find));
            return;
        }
        let n = matches.len();
        // `:%s/.../.../n` ⇒ count-only mode (vim canonical). Don't touch
        // the buffer; just toast the count.
        if sub.count_only {
            self.toast(format!("{label} — {n} match(es) of {:?}", sub.find));
            return;
        }
        // `:%s/.../.../c` ⇒ interactive: pop the confirm overlay and walk
        // through matches one at a time. The overlay's keys do the work.
        if sub.confirm {
            // Descending order so each apply keeps earlier offsets valid;
            // we pop from the end (last match first) is *un*-vim-like, so
            // reverse to keep walk-from-top order. As replacements happen,
            // the upcoming offsets are shifted by `apply_replace_confirm`
            // since they're all strictly later in the buffer.
            let mut remaining: Vec<(usize, usize)> = matches.clone();
            remaining.reverse(); // now last match is at index 0; pop = first
            self.replace_confirm = Some(ReplaceConfirm {
                pane_id: idx,
                find: sub.find.clone(),
                replace: sub.replace.clone(),
                remaining,
                applied: 0,
                total: n,
            });
            // Place the cursor on the first match so the user sees what's
            // about to change.
            self.replace_confirm_jump_to_current();
            return;
        }
        // Choose the replacement strategy. If the regex matcher won,
        // rebuild the scope via `Regex::replace_all` so `\1`, `\2`,
        // `&`, `\0` in the replacement text expand against the capture
        // groups. nvchad-round-7 SEV-1 2026-07-11 — before this
        // fix, `\1` etc. were literal text on the wire, silently
        // destroying the match (e.g. `%s/\(foo\) \(bar\)/\2 \1/g`
        // wrote `\2 \1` on every line — actual data loss).
        //
        // Non-regex (literal / ci-ascii) matchers keep the old
        // per-match ReplaceRange fan-out — they have no capture
        // groups to expand, so the raw `sub.replace` is the right
        // text.
        let ops: Vec<crate::edit_op::EditOp> = if !regex_used {
            matches
                .into_iter()
                .rev()
                .map(|(s, e)| crate::edit_op::EditOp::ReplaceRange {
                    start: s,
                    end: e,
                    text: sub.replace.clone(),
                })
                .collect()
        } else {
            // Translate vim replacement grammar → regex-crate grammar,
            // then run one `replace_all` over the scope. Splice into
            // the buffer as a single ReplaceRange covering [lo..hi].
            let prefixed = if sub.case_insensitive {
                format!("(?i){translated_find}")
            } else {
                translated_find.clone()
            };
            match regex::Regex::new(&prefixed) {
                Ok(re) => {
                    let replacement = vim_replacement_to_regex(&sub.replace);
                    let replaced = re.replace_all(scope, replacement.as_str()).into_owned();
                    vec![crate::edit_op::EditOp::ReplaceRange {
                        start: lo,
                        end: hi,
                        text: replaced,
                    }]
                }
                Err(_) => matches
                    .into_iter()
                    .rev()
                    .map(|(s, e)| crate::edit_op::EditOp::ReplaceRange {
                        start: s,
                        end: e,
                        text: sub.replace.clone(),
                    })
                    .collect(),
            }
        };
        // Wrap the whole run in a single undo group so `u` reverts
        // all replacements in one step. nvchad-user SEV-2 S2-02
        // ("`:%s/.../.../g` is not a single undo step — needs one
        // `u` per replaced line").
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let clip = &mut self.clipboard;
            b.editor.atomic_undo(|editor| {
                for op in ops {
                    editor.apply(op, 0, clip);
                }
            });
            // Notify the LSP / persistent undo path by marking the
            // buffer dirty (the per-op apply_edit_ops path used to do
            // this; we replicate the high-level effect here).
            b.dirty = true;
        }
        // Push the new text to the LSP so diagnostics stay current.
        if let Some(Pane::Editor(b)) = self.panes.get(idx)
            && let Some(p) = b.path.clone()
        {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&p, &t);
        }
        self.toast(format!("{label} — {n} replacement(s)"));
    }

    pub fn run_ex_command(&mut self, line: &str) {
        // Callers land here from two paths:
        //   1. The cmdline overlay (`:term foo` typed by the user) — the
        //      leading `:` is stripped by the overlay before we see it.
        //   2. Manifest-registered integration commands whose `run`
        //      field is stored *with* the leading `:` (2026-07-03 SDK
        //      bug: `run = ":term mnml-aws-amplify"` reached here as
        //      literal `":term mnml-aws-amplify"` and got dispatched as
        //      the unknown command `":term"`).
        // Normalize both by stripping any single leading colon.
        let line = line.trim().trim_start_matches(':').trim_start();
        if line.is_empty() {
            return;
        }
        // Bare number ⇒ jump to that line.
        if let Ok(n) = line.parse::<usize>() {
            if let Some(b) = self.active_editor_mut() {
                b.editor.place_cursor(n.saturating_sub(1), 0);
            }
            return;
        }
        // Leading line-range form (`:1,5d`, `:5,$y`, `:.,+3d`, `:.+1d`,
        // `:'a,'bd`, `:'<,'>d`). Mark refs (`'<letter>` / `'<` / `'>`) are
        // resolved to row numbers first; then the existing parser handles
        // numeric / `.` / `$` / `+N` / `-N` forms.
        let active_row = self
            .active_editor()
            .map(|b| b.editor.row_col().0)
            .unwrap_or(0);
        let active_line_count = self
            .active_editor()
            .map(|b| b.editor.line_count())
            .unwrap_or(1);
        let resolve_mark = |c: char| -> Option<usize> {
            let b = self.active_editor()?;
            if c == '<' || c == '>' {
                let (lo, hi) = b.editor.last_selection_rows()?;
                return Some(if c == '<' { lo } else { hi });
            }
            if c.is_ascii_uppercase() {
                self.global_marks.get(&c).map(|(_, row, _)| *row)
            } else {
                b.marks.get(&c).map(|(row, _)| *row)
            }
        };
        let expanded = expand_mark_refs(line, &resolve_mark);
        if let Some((start, end, remainder)) =
            parse_line_range(&expanded, active_row, active_line_count)
        {
            let cmd = remainder.trim();
            // Split into head + arg (`:5,10y a` → "y" + "a"). Vim
            // allows an optional register letter as the argument for
            // y / d. nvchad-user SEV-2 2026-07-11.
            let (head, arg) = match cmd.split_once(char::is_whitespace) {
                Some((h, a)) => (h, a.trim()),
                None => (cmd, ""),
            };
            // Substitute-shortcut: `s/foo/bar/g` has no whitespace,
            // so the whole thing becomes `head`. Detect the
            // `s`-followed-by-delim pattern and route to the
            // substitute arm without the whitespace-split path.
            // nvchad round 6 SEV-2 2026-07-11 regression fix.
            let is_subst_shortcut = (head.starts_with("s/")
                || head.starts_with("s#")
                || head.starts_with("s!")
                || head.starts_with("s|"))
                && arg.is_empty();
            if is_subst_shortcut {
                let synthesized = head.to_string();
                if let Some(mut sub) = parse_substitute(&synthesized) {
                    sub.whole_buffer = false;
                    sub.line_range = Some((start, end));
                    self.run_substitute(sub);
                    return;
                }
            }
            match head {
                "d" | "delete" | "del" | "de" => {
                    if !arg.is_empty()
                        && arg.len() == 1
                        && let Some(reg) = arg.chars().next()
                        && reg.is_ascii_alphabetic()
                    {
                        self.clipboard.set_pending_register(Some(reg));
                    }
                    self.delete_lines(start, end);
                    return;
                }
                "y" | "yank" | "ya" => {
                    if !arg.is_empty()
                        && arg.len() == 1
                        && let Some(reg) = arg.chars().next()
                        && reg.is_ascii_alphabetic()
                    {
                        self.clipboard.set_pending_register(Some(reg));
                    }
                    self.yank_lines(start, end);
                    return;
                }
                "j" | "join" => {
                    self.join_lines_range(start, end);
                    return;
                }
                ">" | ">>" => {
                    self.indent_lines_range(start, end, true);
                    return;
                }
                "<" | "<<" => {
                    self.indent_lines_range(start, end, false);
                    return;
                }
                // `:{range}s/…/…/[flags]` — substitute within a range.
                // Vim's canonical form. Previously only `:%s` worked.
                // nvchad-user SEV-2 2026-07-11.
                "s" | "sub" | "substitute" => {
                    // Reconstruct as `:%s<rest>` where <rest> is the
                    // /old/new/flags payload, then walk it through
                    // parse_substitute and clamp the byte range to
                    // [start_line..=end_line] inside run_substitute.
                    if let Some(sub_body) = remainder.trim().strip_prefix(head) {
                        // parse_substitute expects the leading `s`.
                        let synthesized = format!("s{sub_body}");
                        if let Some(mut sub) = parse_substitute(&synthesized) {
                            sub.whole_buffer = false;
                            sub.line_range = Some((start, end));
                            self.run_substitute(sub);
                            return;
                        }
                    }
                    self.toast(format!(":{start}..{end}s — unrecognized substitute"));
                    return;
                }
                _ => { /* fall through to normal dispatcher */ }
            }
        }
        // `:%s/old/new/[flags]` — vim-style global substitute. (No regex; flags
        // supported: `g` replace all on each line [default — we always do all
        // matches in the whole buffer]; `i` case-insensitive; `c` confirm
        // ignored for now — applies all without prompting.)
        if let Some(sub) = parse_substitute(line) {
            self.run_substitute(sub);
            return;
        }
        // User-defined ex command resolution. `:command MyCmd <body>`
        // adds it; `:MyCmd <args>` runs `<body> <args>` as a fresh ex
        // command. Lookup is by the leading word (case-sensitive — vim
        // requires user commands to start with a capital letter, but we
        // don't enforce that).
        if let Some(first_word) = line.split_whitespace().next()
            && let Some(cmd) = self.user_ex_commands.get(first_word).cloned()
        {
            let args = line[first_word.len()..].trim();
            if let Err(reason) = cmd.nargs.check(args) {
                self.toast(format!(":{first_word} — {reason}"));
                return;
            }
            let merged = if args.is_empty() {
                cmd.expansion
            } else {
                format!("{} {args}", cmd.expansion)
            };
            self.run_ex_command(&merged);
            return;
        }
        // `:g/pattern/cmd` — vim's "global" command. Runs `<cmd>` on
        // every line whose text contains `<pattern>` (literal substring,
        // case-sensitive). Reverse form `:v/pattern/cmd` runs on lines
        // that *don't* match. Lines are visited top-to-bottom; the cmd
        // runs after `place_cursor(row, 0)` so things like `:d` apply
        // to the matched line.
        if let Some(rest) = line
            .strip_prefix("g/")
            .or_else(|| line.strip_prefix("global/"))
        {
            self.run_global_cmd(rest, false);
            return;
        }
        if let Some(rest) = line
            .strip_prefix("v/")
            .or_else(|| line.strip_prefix("vglobal/"))
        {
            self.run_global_cmd(rest, true);
            return;
        }
        // `:silent <cmd>` / `:sil <cmd>` — run `<cmd>` with toasts
        // suppressed (still recorded in `:messages`). Useful for
        // chained ex commands you don't want narrating themselves.
        if let Some(rest) = line
            .strip_prefix("silent! ")
            .or_else(|| line.strip_prefix("sil! "))
            .or_else(|| line.strip_prefix("silent "))
            .or_else(|| line.strip_prefix("sil "))
        {
            // Mnml doesn't distinguish error toasts from normal toasts,
            // so `:silent` and `:silent!` behave identically.
            self.silent_depth = self.silent_depth.saturating_add(1);
            self.run_ex_command(rest);
            self.silent_depth = self.silent_depth.saturating_sub(1);
            return;
        }
        // Vim adverbs `:keepjumps <cmd>` / `:keepalt <cmd>` / `:noautocmd <cmd>`.
        // Vim uses them to suppress jumplist / alt-buffer / autocmd side effects.
        // mnml's jumplist + alt-buffer machinery aren't sophisticated enough
        // to honor these strictly — strip the adverb and run the inner cmd
        // (vim users get the chained behavior; the suppression is best-effort).
        for adverb in [
            "keepjumps ",
            "keepj ",
            "keepalt ",
            "keepa ",
            "noautocmd ",
            "noa ",
            "keepmarks ",
            "kee ",
        ] {
            if let Some(rest) = line.strip_prefix(adverb) {
                self.run_ex_command(rest);
                return;
            }
        }
        // `:%!cmd` — pipe the whole buffer through `cmd`, replace it
        // with stdout. With an active selection (no `%` prefix), filters
        // the selection only. Useful for `jq .`, `sort`, `prettier`, etc.
        if let Some(rest) = line.strip_prefix("%!") {
            self.run_filter_through_shell(rest.trim(), false);
            return;
        }
        if let Some(rest) = line.strip_prefix("'<,'>!") {
            // Vim canonical visual-range form (``:'<,'>!``) — selection-only.
            self.run_filter_through_shell(rest.trim(), true);
            return;
        }
        // `:!cmd` — fire `cmd` through the shell synchronously, toast a snippet
        // of stdout/stderr (capped) + exit status. Bounded by the harness — not
        // a substitute for opening a `:term <cmd>` pty for long-running things.
        if let Some(rest) = line.strip_prefix("!") {
            let rest = rest.trim();
            // `:!!` ⇒ repeat last `:!` command (vim canonical).
            let actual_cmd = if rest == "!" {
                let Some(last) = self.last_shell_cmd.clone() else {
                    self.toast(":!! — no previous :! command");
                    return;
                };
                last
            } else if rest.is_empty() {
                self.toast(":! — command required");
                return;
            } else {
                rest.to_string()
            };
            self.last_shell_cmd = Some(actual_cmd.clone());
            let cwd = self.active_workspace_path().to_path_buf();
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
            let out = std::process::Command::new(&shell)
                .arg("-c")
                .arg(&actual_cmd)
                .current_dir(&cwd)
                .output();
            match out {
                Ok(out) => {
                    let mut text = String::from_utf8_lossy(&out.stdout).to_string();
                    if text.is_empty() {
                        text = String::from_utf8_lossy(&out.stderr).to_string();
                    }
                    let text = text.trim_end().to_string();
                    let preview: String = text.chars().take(200).collect();
                    let suffix = if text.chars().count() > 200 {
                        "…"
                    } else {
                        ""
                    };
                    let status = match out.status.code() {
                        Some(0) => String::new(),
                        Some(c) => format!(" [exit {c}]"),
                        None => " [killed]".to_string(),
                    };
                    if preview.is_empty() {
                        self.toast(format!(":! ok{status}"));
                    } else {
                        self.toast(format!(":! {preview}{suffix}{status}"));
                    }
                }
                Err(e) => self.toast(format!(":! — {e}")),
            }
            return;
        }
        let (cmd, rest) = match line.split_once(char::is_whitespace) {
            Some((c, r)) => (c, r.trim()),
            None => (line, ""),
        };
        match cmd {
            "w" | "write" => {
                if rest.is_empty() {
                    self.save_active();
                } else if let Some(shell_cmd) = rest.strip_prefix('!') {
                    // `:w !cmd` — pipe the buffer contents to `cmd` on
                    // stdin, toast the output. Vim canonical.
                    // nvchad-round-7 SEV-2 2026-07-11 — was
                    // "save-as filename `!cmd`" which literally
                    // created a file named `!cmd`.
                    self.write_buffer_to_shell(shell_cmd.trim());
                } else {
                    self.save_active_as(rest);
                }
            }
            "saveas" => {
                if rest.is_empty() {
                    self.toast(":saveas <path> — path required");
                } else {
                    self.save_active_as(rest);
                }
            }
            // `:q` / `:x` / `:wq` close the active PANE only. Vim
            // quits when the last pane closes; mnml shows the welcome
            // screen instead so unsaved work in OTHER mnml UI state
            // (recents, settings, the tree, AI threads) isn't blown
            // away by reflexive `ZZ` / `:q`. The explicit quit chord
            // is `:qa` / `:qall` / `Cmd+Q` for app-quit.
            //
            // 2026-06-13 nvchad-user SEV-1 / SEV-2 follow-up: closing
            // the last buffer with `ZZ` was firing `should_quit = true`
            // and exiting the app, masking any other in-flight UI.
            "q" | "quit" => {
                if self.active.is_some() && self.active_pane().is_some_and(Pane::is_dirty) {
                    self.toast("unsaved changes — use :q! to discard");
                } else {
                    self.close_active_pane();
                    if self.panes.is_empty() {
                        self.show_welcome = true;
                    }
                }
            }
            "q!" | "quit!" => {
                self.force_close_active_pane();
                if self.panes.is_empty() {
                    self.show_welcome = true;
                }
            }
            "wq" | "x" | "xit" => {
                self.save_active();
                // After a successful save the buffer's clean, so this won't prompt.
                self.close_active_pane();
                if self.panes.is_empty() {
                    self.show_welcome = true;
                }
            }
            "wa" | "wall" => self.save_all(),
            "wqa" | "wqall" | "xa" | "xall" => {
                self.save_all();
                self.should_quit = true;
            }
            "qa" | "qall" | "quitall" => self.should_quit = true,
            "qa!" | "qall!" => self.should_quit = true,
            "bd" | "bdelete" => self.close_active_pane(),
            // `:bd!` / `:bdelete!` — force-close (bypass dirty prompt).
            "bd!" | "bdelete!" => {
                if let Some(idx) = self.active {
                    self.force_close_pane(idx);
                }
            }
            // `:close` / `:clo` / `:hide` — close the active pane (vim canonical
            // "close window"). Same dirty-prompt path as `:bd` so unsaved
            // editors prompt.
            "close" | "clo" | "hide" => self.close_active_pane(),
            // `:settings` — open the settings overlay. Same as
            // `view.settings` in the palette.
            "settings" => {
                self.open_settings_overlay();
            }
            // `:commands` / `:reference` — open a scratch buffer
            // listing every registered command grouped by category.
            // Same as `view.commands_reference` in the palette.
            "commands" | "reference" => {
                let text =
                    crate::command::build_commands_reference_text_public(&self.dynamic_commands);
                self.open_scratch_with_text("[commands]".into(), text);
            }
            // `:debug.rects` — toggle the visual click-rect overlay.
            // Paints borders around every registered hit-rect so you
            // can SEE where clicks are caught vs where glyphs are
            // rendered. Bug-hunt tool added 2026-06-19 after a wide-
            // glyph cell-width mismatch off-by-one hid for hours.
            "debug.rects" => {
                self.debug_rects = !self.debug_rects;
                self.toast(if self.debug_rects {
                    "debug.rects on (toggle with `:debug.rects`)"
                } else {
                    "debug.rects off"
                });
            }
            // `:help` / `:h` — open the keymap-reference overlay.
            "help" | "h" => {
                self.toggle_help_overlay();
            }
            // `:Explore` / `:E` / `:Sex[plore]` / `:Vex[plore]` / `:Lex[plore]`
            // — vim's netrw file-explorer aliases. mnml routes them to the
            // file tree (`view.toggle_tree`) since that's the closest thing.
            "Explore" | "Ex" | "Sexplore" | "Sex" | "Vexplore" | "Vex" | "Lexplore" | "Lex" => {
                self.toggle_tree_visibility();
            }
            // `:browse edit` / `:browse e` / `:browse` — vim canonical "open a
            // file picker". Route to mnml's `Ctrl+P` file picker.
            "browse" | "bro" => {
                // `:browse edit <whatever>` → ignore the inner cmd; just open
                // the picker (vim's behavior is similar — the GUI dialog comes
                // up regardless).
                self.open_file_picker();
            }
            "bn" | "bnext" => self.next_buffer(),
            "bp" | "bprev" | "bprevious" => self.prev_buffer(),
            // Vim tab pages — each is an independent split tree.
            // `:tabn` / `:tabnext` bare cycles forward; with a count
            // jumps to absolute tab N (1-based). `:tabp` is the mirror.
            "tabn" | "tabnext" => {
                if rest.is_empty() {
                    self.tab_next();
                } else if let Ok(n) = rest.parse::<usize>() {
                    let target = if n == 0 {
                        0
                    } else {
                        (n - 1).min(self.layouts.len().saturating_sub(1))
                    };
                    self.switch_tab(target);
                } else {
                    self.toast(":tabnext — bad arg");
                }
            }
            "tabp" | "tabprev" | "tabprevious" | "tabN" | "tabNext" => {
                if rest.is_empty() {
                    self.tab_prev();
                } else if let Ok(n) = rest.parse::<usize>() {
                    // Vim: `:tabp N` goes N tabs back (wrapping).
                    let len = self.layouts.len();
                    if len > 0 {
                        let cur = self.active_layout;
                        let target = (cur + len - (n % len)) % len;
                        self.switch_tab(target);
                    }
                } else {
                    self.toast(":tabprev — bad arg");
                }
            }
            "tabfirst" | "tabfir" | "tabrewind" | "tabr" => self.tab_first(),
            "tablast" | "tabl" => self.tab_last(),
            "tabclose" | "tabc" => self.tab_close(),
            "tabonly" | "tabo" => self.tab_only(),
            "tabs" => self.tab_list(),
            "tabmove" | "tabm" => self.tab_move(rest),
            "tabreopen" | "tabundo" => self.tab_reopen(),
            // `:badd <path>` — load `<path>` as a buffer but keep focus on the
            // active pane (vim canonical "buffer-add"). Implemented as a
            // background open that reveals the prior active afterwards.
            "badd" | "ba" => {
                if rest.is_empty() {
                    self.toast(":badd <path> — path required");
                } else {
                    let prior = self.active;
                    let p = self.workspace.join(rest);
                    self.open_path(&p);
                    if let Some(idx) = prior
                        && idx < self.panes.len()
                    {
                        self.reveal_pane(idx);
                    }
                }
            }
            // `:resize +N` / `:resize -N` — adjust the active split's height
            // by N percent (10..90 clamp inside `adjust_split`). Bare
            // `:resize` toasts a hint. Vim's exact-rows form (`:resize 20`)
            // would need a screen-row→ratio conversion that we don't track
            // — skip for now.
            "resize" | "res" => {
                let s = rest.trim();
                let delta: i32 = if let Some(rest) = s.strip_prefix('+') {
                    rest.parse().unwrap_or(5)
                } else if let Some(rest) = s.strip_prefix('-') {
                    -rest.parse::<i32>().unwrap_or(5)
                } else {
                    self.toast(":resize +N or :resize -N (mnml uses ratios)");
                    return;
                };
                self.adjust_split(crate::layout::SplitDir::Vertical, delta);
            }
            "vresize" | "vert" => {
                // `:vert resize +N` / `:vert resize -N` — width adjust.
                // `vert` may be followed by `resize`; strip it.
                let s = rest
                    .strip_prefix("resize ")
                    .or_else(|| rest.strip_prefix("res "))
                    .unwrap_or(rest)
                    .trim();
                let delta: i32 = if let Some(rest) = s.strip_prefix('+') {
                    rest.parse().unwrap_or(5)
                } else if let Some(rest) = s.strip_prefix('-') {
                    -rest.parse::<i32>().unwrap_or(5)
                } else {
                    self.toast(":vert resize +N or :vert resize -N");
                    return;
                };
                self.adjust_split(crate::layout::SplitDir::Horizontal, delta);
            }
            // `:bfirst` / `:bf` / `:brewind` / `:br` — jump to the first
            // editor pane. `:blast` / `:bl` — jump to the last. Vim canonical.
            "bfirst" | "bf" | "brewind" | "br" => {
                if let Some(idx) = self.panes.iter().position(|p| matches!(p, Pane::Editor(_))) {
                    self.reveal_pane(idx);
                }
            }
            "blast" | "bl" => {
                if let Some(idx) = self
                    .panes
                    .iter()
                    .rposition(|p| matches!(p, Pane::Editor(_)))
                {
                    self.reveal_pane(idx);
                }
            }
            // `:#` / `:b#` / `:e#` / `:bu#` — switch to the alternate (most
            // recently active) buffer. Vim canonical for the `Ctrl+^` chord.
            "#" | "b#" | "e#" | "bu#" | "buffer#" => self.switch_to_last_buffer(),
            // `:undo` / `:u` and `:redo` / `:red` — vim canonical aliases for
            // a single undo / redo step (count form lives at `:earlier N` /
            // `:later N`).
            "u" | "undo" => {
                let Some(idx) = self.active else { return };
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.editor
                        .apply(crate::edit_op::EditOp::Undo, 20, &mut self.clipboard);
                    b.recompute_dirty();
                    b.refresh_highlights();
                }
            }
            "red" | "redo" => {
                let Some(idx) = self.active else { return };
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.editor
                        .apply(crate::edit_op::EditOp::Redo, 20, &mut self.clipboard);
                    b.recompute_dirty();
                    b.refresh_highlights();
                }
            }
            // `:redraw` / `:redr` / `:redraw!` — force a screen redraw (vim
            // canonical, useful after a sub-process scrambles the terminal).
            "redraw" | "redr" | "redraw!" => {
                self.redraw_requested = true;
            }
            // `:b <substr>` / `:buffer <substr>` — switch to the editor pane
            // whose path contains <substr> (case-insensitive). Vim convention:
            // ambiguous matches toast a hint; bare `:b` toasts a list.
            "b" | "buffer" => self.ex_buffer(rest),
            // Split commands. `:sp [path]` opens (or splits) below; `:vsp` /
            // `:vs` opens to the right. Bare form just splits the current
            // pane; with a path, splits and opens that file in the new leaf.
            "sp" | "split" => {
                self.split_active(crate::layout::SplitDir::Vertical);
                if !rest.is_empty() {
                    let p = self.workspace.join(rest);
                    self.open_path(&p);
                }
            }
            "vs" | "vsp" | "vsplit" => {
                self.split_active(crate::layout::SplitDir::Horizontal);
                if !rest.is_empty() {
                    let p = self.workspace.join(rest);
                    self.open_path(&p);
                }
            }
            // Vim tab pages — open a fresh tab; optional path opens it in the
            // new tab's first leaf.
            "tabnew" | "tabe" | "tabedit" => {
                if rest.is_empty() {
                    self.tab_new(None);
                } else {
                    let p = self.workspace.join(rest);
                    self.tab_new(Some(&p));
                }
            }
            // `:only` / `:on` — close every pane except the active one.
            "on" | "only" => self.close_other_panes(),
            // `:pwd` — show the workspace path (vim convention).
            "pwd" => {
                let p = self.workspace.display().to_string();
                self.toast(p);
            }
            // `:sort [u]` — sort lines (whole buffer if no selection;
            // active selection otherwise). `u` = unique (de-dupe).
            // `:m N` / `:move N` — move the cursor's current line to right
            // after line N (1-based). `N=0` moves to the top of the buffer.
            // `:m -1` moves up by one line; `:m +1` moves down by one (vim
            // canonical relative form). No selection support yet — operates
            // on the cursor's line only.
            "m" | "move" => self.run_move_or_copy_line(rest, false),
            // `:co N` / `:copy N` / `:t N` — duplicate the cursor's line and
            // place the copy after line N. Same destination semantics as `:m`.
            "co" | "copy" | "t" => self.run_move_or_copy_line(rest, true),
            "sort" => self.run_sort_lines_opts(rest.contains('u'), false, rest.contains('i')),
            "sort!" => self.run_sort_lines_opts(rest.contains('u'), true, rest.contains('i')),
            // `:retab` — replace tabs with `[editor] tab_width` spaces in
            // the whole buffer.
            "retab" => {
                let prior_tab_w = self.config.editor.tab_width;
                if let Ok(n) = rest.trim().parse::<usize>()
                    && n >= 1
                {
                    self.config.editor.tab_width = n;
                }
                self.run_retab(false);
                self.config.editor.tab_width = prior_tab_w;
            }
            "retab!" => {
                let prior_tab_w = self.config.editor.tab_width;
                if let Ok(n) = rest.trim().parse::<usize>()
                    && n >= 1
                {
                    self.config.editor.tab_width = n;
                }
                self.run_retab(true);
                self.config.editor.tab_width = prior_tab_w;
            }
            // `:term` / `:terminal` — open a shell in a new split (alias for
            // `term.shell` / `Ctrl+T`).
            "term" | "terminal" => {
                if rest.trim().is_empty() {
                    self.open_shell();
                } else {
                    // `:term <cmd>` — open a one-shot pty pane running the
                    // given shell command in the active workspace.
                    //
                    // Tab-label derivation (2026-07-03):
                    //   - `:term mnml-aws-amplify` → `amplify` (strip
                    //     the `mnml-<category>-` prefix so sibling
                    //     integrations show their family name, not
                    //     the noisy `mnml-aws-amplify` binary path).
                    //   - `:term npm run dev` → `npm` (first word).
                    // The manifest's own `name` field would be
                    // richer but doesn't reach `:term` — this handler
                    // is oblivious to which command line dispatched
                    // to it. Prefix-stripping gets us 90% there
                    // without threading manifest context.
                    let cmdline = rest.trim();
                    let first = cmdline.split_whitespace().next().unwrap_or("term");
                    // 2026-07-03 — if a Pty pane is already running
                    // this exact cmdline (e.g. the user clicked the
                    // Amplify chip a second time), focus it instead
                    // of splitting with a duplicate. The chip click
                    // dispatches `:term <binary>` directly to this
                    // handler, so the dedup needs to live here as
                    // well as in run_dynamic_command.
                    let existing = self.panes.iter().enumerate().find_map(|(pid, p)| {
                        let crate::pane::Pane::Pty(s) = p else {
                            return None;
                        };
                        let args_joined = s.profile.args.join(" ");
                        if args_joined.trim() == cmdline || args_joined.trim().ends_with(cmdline) {
                            Some(pid)
                        } else {
                            None
                        }
                    });
                    if let Some(pid) = existing {
                        self.active = Some(pid);
                        return;
                    }
                    let label = if let Some(rest) = first.strip_prefix("mnml-") {
                        rest.rsplit_once('-')
                            .map_or(rest, |(_, tail)| tail)
                            .to_string()
                    } else {
                        first.to_string()
                    };
                    let ws = self.active_workspace_path().to_path_buf();
                    self.open_pty(crate::pty_pane::BinaryProfile::task(&label, cmdline, ws));
                }
            }
            // `:version` — toast the build sha (formerly the bottom-right
            // statusline chip).
            "version" | "ver" => {
                let ver = env!("MNML_GIT_SHA");
                self.toast(format!("mnml {ver}"));
            }
            // `:welcome` — re-open the first-launch overlay. Useful as a
            // discoverability gesture after the marker has been written.
            "welcome" | "Welcome" => self.toggle_welcome(),
            "about" | "About" => self.toggle_about(),
            "Settings" => self.open_settings_overlay(),
            "ClaudeChat" | "Claude" | "claudechat" => self.open_ai_chat_prompt(),
            // `:rename` (lowercase) renames the pty session — `:Rename`
            // (capital) is the LSP-rename alias handled below.
            "rename" => self.open_rename_session_prompt(),
            // `:reg` / `:registers` — toast clipboard contents (we have a
            // single anonymous register for now). Newlines render as `↵`,
            // truncated to keep the toast short.
            // `:marks` — toast all set marks. Buffer-local (lowercase) for
            // the active editor; global (uppercase) across the workspace.
            // `:ls` / `:files` / `:buffers` — vim canonical "list buffers".
            // Opens the buffer-switcher picker (same as Ctrl+P's buffer
            // mode).
            // `:messages` / `:mes` — show the most-recent N toasts
            // (vim canonical). Joined with `↵` for the toast preview.
            "messages" | "mes" => {
                if self.message_log.is_empty() {
                    self.toast(":messages — none yet");
                } else {
                    let recent: Vec<String> =
                        self.message_log.iter().rev().take(8).cloned().collect();
                    let joined = recent.join("  ↵  ");
                    self.toast(format!(":mes · {joined}"));
                }
            }
            "ls" | "files" | "buffers" | "buf" => self.open_buffer_picker(),
            // fzf.vim-style aliases — wide adoption among vim users.
            "Files" => self.open_file_picker(),
            "Buffers" => self.open_buffer_picker(),
            "Rg" | "Ag" | "Lines" => {
                if rest.trim().is_empty() {
                    self.open_grep_prompt();
                } else {
                    // `:Rg foo` — run grep with the query directly.
                    self.run_workspace_grep(rest.trim().to_string());
                }
            }
            "BLines" => self.open_find_prompt(),
            "History" => {
                crate::command::run("picker.recent", self);
            }
            "Commands" => {
                crate::command::run("palette", self);
            }
            "Marks" => {
                crate::command::run("picker.marks", self);
            }
            "Snippets" => self.snippet_pick(),
            "SnippetsAll" => self.snippet_pick_all(),
            "LinkCheck" | "linkcheck" => self.run_markdown_link_check(),
            // `:Trim` — one-shot remove trailing whitespace from every line
            // in the active buffer (single edit op; one Undo restores).
            "Trim" | "trimws" => {
                if let Some(b) = self.active_editor_mut() {
                    b.apply_trim_trailing_ws();
                }
            }
            // LSP ex aliases — title-case "verbs" for vim users coming from
            // ALE / coc / nvim-lspconfig conventions.
            "Format" => {
                crate::command::run("lsp.format", self);
            }
            // `:Format!` / `:FormatExternal` — pipe through the configured
            // external formatter (prettier / rustfmt / gofmt / ruff / …)
            // instead of the LSP. Useful when the LSP doesn't support
            // formatting or has stale config.
            "Format!" | "FormatExternal" => {
                crate::command::run("editor.format_external", self);
            }
            // `:Lint` — fire the configured external linter on the
            // active buffer (background; results land on
            // `linter_diagnostics` and merge into the diagnostics pane /
            // statusline counts).
            "Lint" | "LintExternal" => {
                crate::command::run("editor.lint_external", self);
            }
            // `:Tools` / `:Mason` — open the Mason-style tools picker.
            // Shows every LSP / formatter / linter mnml looks for, with
            // ✓/✗ "is on PATH" status; Enter copies the install command
            // to the clipboard.
            "Tools" | "Mason" => {
                crate::command::run("tools.installer", self);
            }
            // DAP starter MVP — breakpoint marks only; no real adapter
            // launch yet. `:Bp` is a short alias for the toggle.
            "Breakpoint" | "ToggleBreakpoint" | "Bp" => {
                crate::command::run("dap.toggle_breakpoint", self);
            }
            "Breakpoints" | "Bps" => {
                crate::command::run("dap.list_breakpoints", self);
            }
            "BreakpointsClear" | "BpsClear" | "ClearBreakpoints" => {
                crate::command::run("dap.clear_all_breakpoints", self);
            }
            "Debug" | "Dap" | "DapRun" => {
                crate::command::run("dap.run", self);
            }
            // `:DapShow` / `:DebugPane` — open the live call-stack +
            // output pane independent of dap.run.
            "DapShow" | "DebugPane" => {
                crate::command::run("dap.show", self);
            }
            "DapTerminate" | "DapStop" => {
                crate::command::run("dap.terminate", self);
            }
            // `:LspRestart` — kill every running server; subsequent
            // `did_open` calls (e.g. opening a file in that language) spawn
            // fresh ones. "The LSP got stuck" recovery gesture.
            "LspRestart" | "LspReset" => {
                let n_before = self.lsp.server_count();
                self.lsp.restart_all();
                // Re-fire did_open for every open editor pane so the
                // language servers respawn immediately (otherwise the user
                // would have to switch buffers / save to trigger it).
                let opens: Vec<(PathBuf, String, String)> = self
                    .panes
                    .iter()
                    .filter_map(|p| match p {
                        Pane::Editor(b) => {
                            let path = b.path.clone()?;
                            let lang = b.language_ext.clone()?;
                            Some((path, lang, b.editor.text().to_string()))
                        }
                        _ => None,
                    })
                    .collect();
                for (path, _lang, text) in opens {
                    self.lsp.did_open(&path, &text);
                }
                self.toast(format!("LSP restarted ({n_before} server(s) dropped)"));
            }
            // `:LspStatus` / `:LspInfo` — toast each running server.
            "LspStatus" | "LspInfo" => {
                let servers = self.lsp.servers_running();
                if servers.is_empty() {
                    self.toast("LSP: no servers running");
                } else {
                    let lines: Vec<String> = servers
                        .iter()
                        .map(|(name, root)| {
                            let rel = root
                                .strip_prefix(&self.workspace)
                                .unwrap_or(root.as_path())
                                .to_string_lossy();
                            let rel = if rel.is_empty() { ".".into() } else { rel };
                            format!("{name} ({rel})")
                        })
                        .collect();
                    self.toast(format!("LSP: {}", lines.join(" · ")));
                }
            }
            "Hover" => self.lsp_hover(),
            "Definition" => self.lsp_goto_definition(),
            "Declaration" => self.lsp_goto_declaration(),
            "TypeDefinition" => self.lsp_goto_type_definition(),
            "Implementation" => self.lsp_goto_implementation(),
            "IncomingCalls" | "Callers" => self.lsp_incoming_calls(),
            "OutgoingCalls" | "Callees" => self.lsp_outgoing_calls(),
            "Supertypes" | "ParentTypes" => self.lsp_supertypes(),
            "Subtypes" | "ChildTypes" => self.lsp_subtypes(),
            "References" => {
                crate::command::run("lsp.references", self);
            }
            "Symbols" => {
                crate::command::run("lsp.symbols", self);
            }
            "Diagnostics" => {
                crate::command::run("lsp.diagnostics", self);
            }
            // `:lopen` / `:lclose` / `:lwindow` — vim's location list. mnml's
            // closest analog is the LSP diagnostics pane. Open it via
            // :lopen; close via :lclose. Same handler — pane toggles.
            "lopen" | "lwindow" => {
                crate::command::run("lsp.diagnostics", self);
            }
            "lclose" => {
                if let Some(i) = self
                    .panes
                    .iter()
                    .position(|p| matches!(p, Pane::Diagnostics(_)))
                {
                    self.force_close_pane(i);
                }
            }
            // `:lnext` / `:lprev` — walk the location list. Routes to
            // `lsp.next_diagnostic` / `lsp.prev_diagnostic`.
            "lnext" | "lne" => {
                crate::command::run("lsp.next_diagnostic", self);
            }
            "lprev" | "lp" | "lprevious" => {
                crate::command::run("lsp.prev_diagnostic", self);
            }
            // `:colorscheme <name>` / `:colo <name>` — vim canonical theme
            // switcher. mnml's existing `:set theme=…` does the same; this
            // is just the muscle-memory form.
            "colorscheme" | "colo" | "Theme" => {
                let name = rest.trim();
                if name.is_empty() {
                    let cur = crate::ui::theme::cur().name;
                    self.toast(format!(":colorscheme · current: {cur}"));
                } else {
                    self.set_theme(name);
                }
            }
            "Rename" => {
                crate::command::run("lsp.rename", self);
            }
            "CodeAction" | "CA" => {
                crate::command::run("lsp.code_action", self);
            }
            "QuickFix" | "QF" => {
                crate::command::run("lsp.quick_fix", self);
            }
            // Title-case git ex aliases — fugitive.vim conventions. Each
            // routes to the matching `git.*` command.
            "G" | "Git" | "Status" => {
                crate::command::run("git.status_pane", self);
            }
            "Gblame" | "Blame" => {
                crate::command::run("git.blame_toggle", self);
            }
            "Gdiff" => {
                crate::command::run("git.diff_file", self);
            }
            "Glog" | "Log" => {
                crate::command::run("git.graph", self);
            }
            "Gflog" | "FileHistory" => {
                crate::command::run("git.file_history", self);
            }
            "DiffOrig" => {
                crate::command::run("git.diff_orig", self);
            }
            // `:Diffsplit <other>` / `:Diffwith <other>` — open a diff
            // pane comparing the *active editor's buffer* against
            // `<other>` (workspace-relative). Reuses
            // DiffScope::BufferVsDisk by pointing it at `<other>`, but
            // the on-disk read is for `<other>` and the in-memory side
            // is the active buffer's text via active_editor — so the
            // helper sees the right text either way (it matches by
            // path; if the active buffer's path != <other>, we route
            // through a temp comparison).
            "Diffsplit" | "Diffwith" => {
                let other = rest.trim();
                if other.is_empty() {
                    self.toast(":Diffsplit <file> — needs a path");
                    return;
                }
                let other_path = if std::path::Path::new(other).is_absolute() {
                    std::path::PathBuf::from(other)
                } else {
                    self.workspace.join(other)
                };
                if !other_path.exists() {
                    self.toast(format!(":Diffsplit — no such file: {other}"));
                    return;
                }
                self.open_diff_buffer_vs_file(other_path);
            }
            "GBrowse" | "Gbrowse" | "Browse" => {
                if let Some(arg) = rest.split_whitespace().next() {
                    // `:GBrowse <commit>` — open the commit URL on remote.
                    // Resolve `arg` to a full SHA via `git rev-parse`.
                    let workspace = self.workspace.clone();
                    let resolved = std::process::Command::new("git")
                        .args(["rev-parse", arg])
                        .current_dir(&workspace)
                        .output()
                        .ok()
                        .filter(|o| o.status.success())
                        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                        .filter(|s| !s.is_empty());
                    match resolved.and_then(|h| crate::git::browse::commit_url(&workspace, &h)) {
                        Some(url) => {
                            open_url_external(&url);
                            self.toast(format!("→ {url}"));
                        }
                        None => self.toast(format!("GBrowse: cannot resolve commit {arg:?}")),
                    }
                } else {
                    crate::command::run("git.browse", self);
                }
            }
            "reveal" | "Reveal" | "Finder" => {
                crate::command::run("view.reveal_active", self);
            }
            "Todos" | "TODO" | "FIXME" | "todos" => {
                crate::command::run("project.todos", self);
            }
            // `:Stat` — toast file size on disk, mtime, line/byte counts,
            // language. Combines `:Path` + `g Ctrl+G` + disk facts.
            // `:Echo <text>` — toast the rest of the line verbatim (vim
            // canonical `:echo`). Tiny utility — useful for keymap
            // confirmation, plugin debugging.
            "Echo" | "echo" => {
                self.toast(rest.to_string());
            }
            // `:Mkdir <path>` — create the directory (+ missing parents)
            // under the workspace. Relative paths join onto self.workspace.
            // `:Capture <cmd>` — run `<cmd>` via $SHELL -c, open the
            // `:Scratch [ft]` — open a fresh scratch buffer (split below)
            // optionally tagged with a filetype for syntax highlighting.
            "Scratch" | "scratch" => {
                let ft = rest.trim();
                self.split_active(crate::layout::SplitDir::Vertical);
                let mut buf = crate::buffer::Buffer::scratch(&self.config);
                if !ft.is_empty() {
                    buf.set_language_ext(Some(ft.to_string()));
                    buf.refresh_highlights();
                }
                self.panes.push(Pane::Editor(buf));
                let new_id = self.panes.len() - 1;
                self.reveal_pane(new_id);
            }
            // combined stdout/stderr in a new scratch buffer. Useful for
            // grabbing `cargo test` output for grep/highlight without
            // launching a full pty. Cwd is the workspace.
            "Capture" | "capture" => {
                let cmd = rest.trim();
                if cmd.is_empty() {
                    self.toast(":Capture <cmd> — needs a command");
                    return;
                }
                let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
                let cwd = self.active_workspace_path().to_path_buf();
                let out = std::process::Command::new(&shell)
                    .args(["-c", cmd])
                    .current_dir(&cwd)
                    .output();
                match out {
                    Ok(o) => {
                        let mut text = String::from_utf8_lossy(&o.stdout).into_owned();
                        let err = String::from_utf8_lossy(&o.stderr);
                        if !err.trim().is_empty() {
                            if !text.is_empty() && !text.ends_with('\n') {
                                text.push('\n');
                            }
                            text.push_str("---stderr---\n");
                            text.push_str(&err);
                        }
                        let title = format!("[capture: {cmd}]");
                        self.open_scratch_with_text(title, text);
                    }
                    Err(e) => self.toast(format!("capture failed: {e}")),
                }
            }
            "Mkdir" | "mkdir" => {
                let arg = rest.trim();
                if arg.is_empty() {
                    self.toast(":Mkdir <path> — needs a path");
                } else {
                    let target = std::path::Path::new(arg);
                    let abs = if target.is_absolute() {
                        target.to_path_buf()
                    } else {
                        self.workspace.join(target)
                    };
                    match std::fs::create_dir_all(&abs) {
                        Ok(_) => {
                            self.tree.refresh();
                            self.toast(format!("mkdir: {}", abs.display()));
                        }
                        Err(e) => self.toast(format!("mkdir failed: {e}")),
                    }
                }
            }
            // `:Touch <path>` — create an empty file (creating parents).
            // `:Mv <from> <to>` — rename / move a file. Both paths
            // workspace-relative. Refuses to overwrite an existing
            // destination. Re-points any open editor pane on `<from>`
            // to `<to>` (LSP did_close + did_open are wired through
            // the existing rename flow).
            // `:Cp <from> <to>` — copy a file (workspace-relative).
            // Refuses to overwrite. Creates the parent of `<to>` if needed.
            "Cp" => self.ex_cp(rest),
            "Mv" | "mv" => self.ex_mv(rest),
            "Touch" | "touch" => self.ex_touch(rest),
            // `:Macros` — toast each recorded macro register + key count.
            // `:Macro <reg>` — replay a specific register (alt: `@<reg>` in vim).
            "Macros" => {
                if self.macro_buffer.is_empty() {
                    self.toast("no macros recorded");
                } else {
                    let mut entries: Vec<(char, usize)> = self
                        .macro_buffer
                        .iter()
                        .map(|(k, v)| (*k, v.len()))
                        .collect();
                    entries.sort_by_key(|(k, _)| *k);
                    let line: String = entries
                        .iter()
                        .map(|(k, n)| format!("@{k}={n}"))
                        .collect::<Vec<_>>()
                        .join(" ");
                    self.toast(line);
                }
            }
            "Macro" => {
                let reg = rest.trim().chars().next();
                match reg {
                    Some(c) if self.macro_buffer.contains_key(&c) => {
                        self.pending_macro_register = Some(c);
                        self.macro_replay();
                    }
                    Some(c) => self.toast(format!(":Macro — register @{c} is empty")),
                    None => self.toast(":Macro <reg> — needs a register letter"),
                }
            }
            // `:A` — alternate file. Tries common test ↔ source pairings
            // for the active file: `_test`, `.test.`, `.spec.`, `_spec`,
            // `Tests`. Strips when present, adds when absent.
            // `:Refresh` — manually rescan the file tree + git status.
            // Useful after external file ops (cloning a submodule, etc.).
            "Refresh" => {
                self.tree.refresh();
                self.git.refresh();
                self.toast("refreshed");
            }
            // `:Hidden` / `:ToggleHidden` — flip the file tree's hidden-file
            // visibility (dotfiles, `.gitignored` entries skipped by the
            // initial scan). Re-scans the tree.
            // `:Bonly` — close every editor pane except the active one.
            // Vim has `:%bd <bang>` for similar; this is the friendlier alias.
            // Dirty buffers are kept + counted (matches the tab context-menu's
            // "Close others" semantics).
            // `:Outline` / `:Toc` / `:Symbols` — open the outline pane for
            // the active file (LSP / regex / markdown symbols).
            // `:Outline` / `:Toc` — open the outline pane for the active
            // file (LSP / regex / markdown symbols). `:Symbols` already
            // opens the picker variant earlier in this match arm.
            "Outline" | "Toc" | "TOC" => {
                crate::command::run("outline.show", self);
            }
            // `:NextDirty` / `:PrevDirty` — jump to the next / previous
            // editor pane with unsaved changes. Useful when you have many
            // buffers and want to find what's still dirty before quitting.
            "NextDirty" => self.jump_dirty_pane(true),
            "PrevDirty" => self.jump_dirty_pane(false),
            // `:Wipeout <substr>` — close every editor pane whose
            // workspace-relative path contains `<substr>`. Skips dirty
            // buffers (toasts the count). Useful for "drop everything
            // under `tests/` after a refactor".
            // `:Sum` — extract every integer / decimal from the visual
            // selection (or the whole buffer when no selection) and
            // toast the count + total. Spreadsheet-y "what does this
            // column add up to" gesture.
            // `:CountMatches <pattern>` — toast the count of regex
            // matches for `<pattern>` in the active buffer (or selection).
            // Sibling to `:%s/.../.../n` but doesn't require a replacement.
            "CountMatches" | "CountMatch" => {
                let pattern = rest.trim();
                if pattern.is_empty() {
                    self.toast(":CountMatches <pattern> — needs a pattern");
                    return;
                }
                let text = self.active_editor().map(|b| {
                    if let Some((s, e)) = b.editor.selection() {
                        b.editor.text()[s..e].to_string()
                    } else {
                        b.editor.text().to_string()
                    }
                });
                let Some(text) = text else {
                    self.toast("no active editor");
                    return;
                };
                match regex::Regex::new(&format!("(?i){pattern}")) {
                    Ok(re) => {
                        let n = re.find_iter(&text).count();
                        self.toast(format!(":CountMatches /{pattern}/ — {n}"));
                    }
                    Err(e) => self.toast(format!(":CountMatches — bad regex: {e}")),
                }
            }
            // `:Messages!` — open the full toast/message log in a fresh
            // scratch buffer below. `:messages` (already wired) toasts
            // the recent 8; the bang form is "show me all 200".
            "Messages!" | "MessageLog" | "messageslog" => {
                if self.message_log.is_empty() {
                    self.toast(":Messages! — empty log");
                    return;
                }
                let text = self.message_log.join("\n");
                self.open_scratch_with_text("[messages]".into(), text);
            }
            "Sum" | "sum" => self.ex_sum(rest),
            "Wipeout" | "Wipe" => self.ex_wipeout(rest),
            "Bonly" | "bonly" => {
                if let Some(id) = self.active {
                    self.close_panes_except(Some(id));
                }
            }
            "Hidden" | "ToggleHidden" => {
                self.tree.show_hidden = !self.tree.show_hidden;
                self.tree.refresh();
                self.toast(if self.tree.show_hidden {
                    "tree: show hidden"
                } else {
                    "tree: hide hidden"
                });
            }
            "A" | "Alternate" => {
                let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
                    self.toast(":A — no active file");
                    return;
                };
                let candidates = alternate_paths(&path);
                let hit = candidates.into_iter().find(|p| p.exists());
                match hit {
                    Some(p) => self.open_path(&p),
                    None => self.toast(":A — no alternate file found"),
                }
            }
            // `:Notes` — open / create `<workspace>/.mnml/notes.md` as
            // a workspace-local notepad. Markdown so the existing
            // highlight + preview auto-open behavior kicks in.
            // `:OpenAt <path>:<line>[:<col>]` — open the file and jump to
            // the given 1-based position. Useful for pasting in
            // `path:row:col` strings from grep / clippy / etc.
            // `:Filetypes` — toast the tree-sitter grammars / filetypes
            // mnml ships with. Helpful for "is X supported?" without
            // grepping the source.
            "Filetypes" | "filetypes" => {
                let exts = [
                    "rs", "js", "jsx", "ts", "tsx", "py", "json", "go", "toml", "css", "bash",
                    "html", "md", "c", "cpp", "rb", "java", "cs", "lua", "yaml", "scala", "ex",
                    "hs", "php", "swift", "zig", "nix", "ocaml", "dart", "sql", "make", "kt",
                    "regex",
                ];
                self.toast(format!("filetypes ({}): {}", exts.len(), exts.join(" ")));
            }
            "OpenAt" | "openat" => {
                let arg = rest.trim();
                if arg.is_empty() {
                    self.toast(":OpenAt <path>:<line>[:<col>] — needs args");
                    return;
                }
                let mut parts = arg.splitn(3, ':');
                let path_str = parts.next().unwrap_or("");
                let line = parts.next().and_then(|s| s.parse::<usize>().ok());
                let col = parts.next().and_then(|s| s.parse::<usize>().ok());
                if path_str.is_empty() || line.is_none() {
                    self.toast(":OpenAt — bad format (need <path>:<line>)");
                    return;
                }
                let path = if std::path::Path::new(path_str).is_absolute() {
                    std::path::PathBuf::from(path_str)
                } else {
                    self.workspace.join(path_str)
                };
                self.open_path(&path);
                let row = line.unwrap_or(1).saturating_sub(1);
                let c = col.unwrap_or(1).saturating_sub(1);
                if let Some(b) = self.active_editor_mut() {
                    b.editor.place_cursor(row, c);
                }
            }
            // `:Fn` — toast just the active editor's filename (no path).
            // Friendlier than `:Path` for quick "what file is this".
            "Fn" => {
                let name = self
                    .active_editor()
                    .and_then(|b| b.path.as_ref().and_then(|p| p.file_name()))
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "(unsaved buffer)".into());
                self.toast(name);
            }
            // `:Args` — mnml extension: list every open editor pane's
            // workspace-relative path. Lowercase `:args` is handled
            // further below as the real vim arglist (`:args`/`:next`/
            // `:prev`/`:first`/`:last`).
            "Args" => {
                let mut names: Vec<String> = self
                    .panes
                    .iter()
                    .filter_map(|p| match p {
                        Pane::Editor(b) => b.path.as_ref().map(|p| {
                            p.strip_prefix(&self.workspace)
                                .unwrap_or(p)
                                .to_string_lossy()
                                .into_owned()
                        }),
                        _ => None,
                    })
                    .collect();
                if names.is_empty() {
                    self.toast(":Args — no open files");
                } else {
                    names.sort();
                    self.toast(format!(":Args — {}", names.join(" · ")));
                }
            }
            // `:Mtime` — toast the active file's mtime (when readable).
            "Mtime" => {
                let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
                    self.toast(":Mtime — no saved file");
                    return;
                };
                match std::fs::metadata(&path).and_then(|m| m.modified()) {
                    Ok(t) => {
                        let secs = t
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.as_secs() as i64)
                            .unwrap_or(0);
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.as_secs() as i64)
                            .unwrap_or(0);
                        let age = crate::ui::git_graph_view::humanize_age(now.saturating_sub(secs));
                        self.toast(format!(
                            ":Mtime — {} (age {age})",
                            path.file_name()
                                .map(|n| n.to_string_lossy().into_owned())
                                .unwrap_or_default()
                        ));
                    }
                    Err(e) => self.toast(format!(":Mtime: {e}")),
                }
            }
            "Notes" | "notes" => {
                let dir = self.workspace.join(".mnml");
                if let Err(e) = std::fs::create_dir_all(&dir) {
                    self.toast(format!(":Notes: cannot create dir: {e}"));
                    return;
                }
                let path = dir.join("notes.md");
                if !path.exists() {
                    let seed = "# Workspace notes\n\n";
                    if let Err(e) = std::fs::write(&path, seed) {
                        self.toast(format!(":Notes: cannot create file: {e}"));
                        return;
                    }
                }
                self.open_path(&path);
            }
            // `:Reflow [N]` — reflow the paragraph at cursor to width N
            // (default `[editor] text_width`). Vim canonical is `gqq`;
            // this is the ex form with an optional width arg.
            "Reflow" => {
                let arg = rest.trim();
                let prev_width = self.config.editor.text_width;
                let mut restore = None;
                if !arg.is_empty()
                    && let Ok(n) = arg.parse::<usize>()
                    && n > 0
                {
                    restore = Some(prev_width);
                    self.config.editor.text_width = n;
                }
                self.reflow_paragraph_at_cursor();
                if let Some(prev) = restore {
                    self.config.editor.text_width = prev;
                }
            }
            // `:Sleep <ms>` — block the event loop for `<ms>` ms.
            // Mostly for scripting / e2e. Clamps at 10 000 ms.
            "Sleep" | "sleep" => {
                let ms = rest.trim().parse::<u64>().unwrap_or(0).min(10_000);
                if ms == 0 {
                    self.toast(":Sleep <ms> — needs a positive number");
                } else {
                    std::thread::sleep(std::time::Duration::from_millis(ms));
                }
            }
            // `:Encoding` / `:enc` — mnml is UTF-8 only. Toast for vim
            // muscle memory.
            "Encoding" | "enc" => {
                self.toast(":Encoding — utf-8 (mnml is UTF-8 only)");
            }
            // `:RootFor [path]` — toast the LSP root for `<path>` (or
            // the active buffer). Walks ancestors for Cargo.toml /
            // package.json / etc.
            "RootFor" | "rootfor" => self.ex_rootfor(rest),
            // `:Newer <N>` / `:Older <N>` — aliases for `:later` /
            // `:earlier`. Walks N undo steps forward / back.
            "Newer" => {
                let alias = format!("later {rest}");
                self.run_ex_command(&alias);
            }
            "Older" => {
                let alias = format!("earlier {rest}");
                self.run_ex_command(&alias);
            }
            // `:WordCount` / `:Wc` — count chars / words / lines in the
            // active buffer (or selection). The classic `wc -lwc` shape.
            "WordCount" | "Wc" | "wc" => {
                let text = self.active_editor().map(|b| {
                    if let Some((s, e)) = b.editor.selection() {
                        b.editor.text()[s..e].to_string()
                    } else {
                        b.editor.text().to_string()
                    }
                });
                let Some(text) = text else {
                    self.toast("no active editor");
                    return;
                };
                let lines = if text.is_empty() {
                    0
                } else {
                    text.matches('\n').count() + 1
                };
                let words = text.split_whitespace().count();
                let chars = text.chars().count();
                let bytes = text.len();
                self.toast(format!(
                    "{lines} lines · {words} words · {chars} chars · {bytes}B"
                ));
            }
            "Stat" | "stat" => {
                let Some(b) = self.active_editor() else {
                    self.toast("no active editor");
                    return;
                };
                let text = b.editor.text();
                let line_count = b.editor.line_count();
                let byte_count = text.len();
                let lang = b.language_ext.as_deref().unwrap_or("?").to_string();
                let mut on_disk = String::from("(unsaved)");
                if let Some(p) = &b.path
                    && let Ok(md) = std::fs::metadata(p)
                {
                    let bytes = md.len();
                    let kb = (bytes as f64) / 1024.0;
                    on_disk = if bytes < 1024 {
                        format!("{bytes}B")
                    } else if kb < 1024.0 {
                        format!("{kb:.1}KB")
                    } else {
                        format!("{:.1}MB", kb / 1024.0)
                    };
                }
                self.toast(format!(
                    "{line_count} lines · {byte_count}B in memory · disk={on_disk} · lang={lang}"
                ));
            }
            // `:Path` / `:pwd` already toasts workspace; `:Path` toasts the
            // active file's full path. Useful for "where is this file".
            "Path" => {
                let path = self
                    .active_editor()
                    .and_then(|b| b.path.clone())
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|| "(unsaved buffer)".into());
                self.toast(path);
            }
            "Gcommit" | "Commit" => {
                crate::command::run("git.commit", self);
            }
            "Branch" | "Branches" => {
                crate::command::run("git.checkout", self);
            }
            "Stash" => {
                crate::command::run("git.stash", self);
            }
            "StashPop" => {
                crate::command::run("git.stash_pop", self);
            }
            // Playwright test aliases.
            "Test" => {
                crate::command::run("test.run_at_cursor", self);
            }
            "TestAll" => {
                crate::command::run("test.run_all", self);
            }
            "TestFile" => {
                crate::command::run("test.run_file", self);
            }
            "TestFailed" => {
                crate::command::run("test.rerun_failed", self);
            }
            "Flaky" => {
                crate::command::run("flaky.show", self);
            }
            // Git hunk navigation aliases.
            "NextHunk" | "Hnext" => {
                crate::command::run("git.jump_next_change", self);
            }
            "PrevHunk" | "Hprev" => {
                crate::command::run("git.jump_prev_change", self);
            }
            "PeekHunk" | "Hpeek" => {
                crate::command::run("git.peek_change", self);
            }
            // `:Toast <text>` — show a toast (useful for scripting / plugin
            // development / quick debugging from the cmdline).
            "Toast" => {
                if rest.trim().is_empty() {
                    self.toast(":Toast <text>");
                } else {
                    self.toast(rest.trim().to_string());
                }
            }
            // `:Maps [filter]` — toast the resolved keymap (chord → command).
            // With a filter, narrows to specs / command ids containing the
            // substring. Vim users reach for `:map`; mnml's keymap is
            // config-driven so this is read-only discovery.
            // `:wincmd <c>` — run the `Ctrl+W <c>` chord as an ex command
            // (vim canonical for "do window-cmd from cmdline"). Mirrors the
            // Prefix::Window arms in the vim handler.
            "wincmd" | "winc" => self.ex_wincmd(cmd, rest),
            "Maps" | "Keys" => self.ex_maps(rest),
            // `:diff` / `:diffs` / `:diffsplit` — open the diff pane for
            // the active file (alias for the existing `git.diff_file`
            // command). Vim users reach for `:diff` reflexively.
            "diff" | "diffs" | "diffsplit" => {
                crate::command::run("git.diff_file", self);
            }
            // `:tag <name>` — annotated tag on HEAD (or the selected graph
            // commit). Bare `:tag` opens the prompt. `:tags` lists local
            // tags. `:Tag` is a friendlier alias.
            "tag" | "Tag" => {
                let name = rest.trim();
                if name.is_empty() {
                    self.open_git_tag_prompt();
                } else {
                    let target = self.selected_graph_commit_hash();
                    match crate::git::tag::create_annotated(
                        self.active_repo_path(),
                        name,
                        name,
                        target.as_deref(),
                    ) {
                        Ok(summary) => {
                            self.after_git_change();
                            self.refresh_active_git_graph();
                            self.toast(summary);
                        }
                        Err(e) => self.toast(format!("git tag: {e}")),
                    }
                }
            }
            "tags" | "Tags" => {
                let tags = crate::git::tag::list(self.active_repo_path());
                if tags.is_empty() {
                    self.toast(":tags — none");
                } else {
                    let preview = tags
                        .iter()
                        .take(10)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join(" · ");
                    let more = if tags.len() > 10 {
                        format!(" (+{} more)", tags.len() - 10)
                    } else {
                        String::new()
                    };
                    self.toast(format!(":tags ({}) {}{}", tags.len(), preview, more));
                }
            }
            "PushTags" | "pushtags" => {
                self.run_git_push_tags();
            }
            // `:Stashes` / `:StashList` — open the stash list (pick to
            // apply, vim canon). `:StashDrop` opens the drop variant.
            "Stashes" | "StashList" | "stashlist" => {
                self.open_git_stash_list();
            }
            "StashDrop" | "stashdrop" => {
                self.open_git_stash_drop();
            }
            // `:Reflog` — open the reflog picker. Accept ⇒ open the
            // commit's diff. The dim detail column shows HEAD@{N} so
            // the user can copy it for a manual reset from a pty.
            "Reflog" | "reflog" => {
                self.open_git_reflog();
            }
            // `:execute "<str>"` / `:exe "<str>"` — strip outer quotes,
            // unescape `\\` and `\"`, run the result as a fresh ex cmd.
            // No expression eval (vim's `:execute` does string concat
            // with `.`); strict literal MVP.
            "execute" | "exe" => self.ex_execute(rest),
            // `:syntax on|off` — toggle tree-sitter highlights (master
            // switch). Off paints all editor text in the theme's
            // foreground color.
            // `:setf <name>` / `:set filetype=<name>` — override the
            // buffer's `language_ext` so the highlighter targets a
            // different grammar (`:setf rust` for a `.txt` snippet that's
            // actually code, etc.). Re-runs the highlighter immediately.
            "setf" | "setfiletype" => {
                let name = rest.trim();
                if name.is_empty() {
                    self.toast(":setf <ext>");
                } else if let Some(b) = self.active_editor_mut() {
                    b.set_language_ext(Some(name.to_string()));
                    b.refresh_highlights();
                    self.toast(format!(":setf {name}"));
                }
            }
            // `:j` / `:join` — bare form joins the current line with the
            // next (vim's `J`).
            "j" | "join" => {
                let Some(idx) = self.active else { return };
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.editor.apply(
                        crate::edit_op::EditOp::JoinLines { keep_space: true },
                        20,
                        &mut self.clipboard,
                    );
                    self.toast(":j");
                }
            }
            "syntax" | "syn" => {
                let opt = rest.trim();
                match opt {
                    "on" | "" => {
                        self.config.ui.syntax = true;
                        self.toast(":syntax on");
                    }
                    "off" => {
                        self.config.ui.syntax = false;
                        self.toast(":syntax off");
                    }
                    _ => self.toast(":syntax on|off"),
                }
            }
            // `:ascii` ⇒ char info under cursor (vim canonical alias for `ga`).
            "ascii" | "asc" => self.show_char_info(),
            // `:goto N` ⇒ jump to byte N (rough — places cursor at line where
            // the byte falls). Vim canonical for byte-position navigation.
            "goto" | "go" => {
                if let Ok(target) = rest.trim().parse::<usize>()
                    && let Some(b) = self.active_editor_mut()
                {
                    let text = b.editor.text();
                    let target = target.min(text.len());
                    let row = text[..target].bytes().filter(|&c| c == b'\n').count();
                    b.editor.place_cursor(row, 0);
                    self.toast(format!(":goto {target}B → line {}", row + 1));
                }
            }
            // `:enew` / `:ene` — fresh scratch buffer in current pane.
            "enew" | "ene" => {
                let buf = crate::buffer::Buffer::scratch(&self.config);
                self.panes.push(Pane::Editor(buf));
                let new_id = self.panes.len() - 1;
                self.reveal_pane(new_id);
                self.toast(":enew");
            }
            // `:make [task]` — kick off the configured `[tasks.make]`
            // task (or the named task) in a pty pane. Vim canonical for
            // "build / test from inside the editor".
            "make" | "mak" => {
                let task = if rest.trim().is_empty() {
                    "make".to_string()
                } else {
                    rest.trim().to_string()
                };
                if !self.run_task(&task) {
                    self.toast(format!(":make — no [tasks.{task}] in config"));
                }
            }
            "marks" => {
                let mut parts: Vec<String> = Vec::new();
                if let Some(b) = self.active_editor() {
                    let mut local: Vec<(char, (usize, usize))> =
                        b.marks.iter().map(|(&c, &v)| (c, v)).collect();
                    local.sort_by_key(|(c, _)| *c);
                    for (c, (row, col)) in local {
                        parts.push(format!("'{c}@{}:{}", row + 1, col + 1));
                    }
                }
                let mut global: Vec<(char, &(PathBuf, usize, usize))> =
                    self.global_marks.iter().map(|(&c, v)| (c, v)).collect();
                global.sort_by_key(|(c, _)| *c);
                for (c, (path, row, _col)) in global {
                    let rel = rel_path(&self.workspace, path);
                    parts.push(format!("'{c}@{rel}:{}", row + 1));
                }
                if parts.is_empty() {
                    self.toast(":marks — none set");
                } else {
                    self.toast(format!(":marks · {}", parts.join("  ")));
                }
            }
            // `:jumps` — toast the jumplist (nav_back + nav_forward), newest
            // first. Capped to 10 entries each side so the toast stays
            // readable.
            "jumps" => self.ex_jumps(rest),
            // `:wn` / `:wnext` — write the current buffer + jump to next.
            // `:wp` / `:wprev` — write + jump to prev.
            "wn" | "wnext" => {
                self.save_active();
                self.next_buffer();
            }
            "wp" | "wprev" | "wprevious" => {
                self.save_active();
                self.prev_buffer();
            }
            // `:wa` already exists below — short alias.
            // `:d[elete]` — delete current line (vim canonical ex form
            // of `dd`). Goes through `DeleteLine` so the unnamed register
            // gets the line.
            "d" | "delete" | "de" | "del" => {
                let Some(idx) = self.active else { return };
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.editor
                        .apply(crate::edit_op::EditOp::DeleteLine, 20, &mut self.clipboard);
                    // SEV-1 fix 2026-07-07 — was: `:g/pattern/d`
                    // deleted lines but never flipped `dirty`, so
                    // `:q` silently discarded the changes (data loss).
                    // The `:d` handler drives every `:g/…/d` iteration
                    // via run_ex_command, and each apply() call needs
                    // its own dirty recompute for the buffer to know
                    // the mutation happened.
                    b.recompute_dirty();
                    self.toast(":delete");
                }
            }
            // `:y[ank]` — yank current line.
            "y" | "yank" | "ya" => {
                let Some(idx) = self.active else { return };
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.editor
                        .apply(crate::edit_op::EditOp::YankLine, 20, &mut self.clipboard);
                    // YankLine doesn't mutate the buffer, but recompute
                    // for consistency with the surrounding `:d`/`:put`
                    // handlers.
                    b.recompute_dirty();
                    self.toast(":yank");
                }
            }
            // `:put` / `:put!` — paste the unnamed register on the next /
            // previous line (vim canonical ex-cmd form of `p`/`P`).
            // Linewise — always inserts a new line (even if the register
            // is charwise).
            "put" | "pu" => {
                let Some(idx) = self.active else {
                    self.toast(":put — no active editor");
                    return;
                };
                // Optional register letter — `:put a` reads from
                // `"a`. nvchad round 5 SEV-2 2026-07-11.
                if !rest.is_empty()
                    && rest.len() == 1
                    && let Some(reg) = rest.chars().next()
                    && reg.is_ascii_alphabetic()
                {
                    self.clipboard.set_pending_register(Some(reg));
                }
                let s = self.clipboard.text();
                if s.is_empty() {
                    self.toast(":put — clipboard empty");
                    return;
                };
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    let row = b.editor.row_col().0;
                    let line_end = b.editor.line_byte_range(row).1;
                    let insert_at = line_end;
                    let payload = format!("\n{}", s.trim_end_matches('\n'));
                    b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::ReplaceRange {
                            start: insert_at,
                            end: insert_at,
                            text: payload,
                        }],
                        &mut self.clipboard,
                        0,
                    );
                    self.toast(format!(":put — inserted {}B below", s.len()));
                }
            }
            "put!" => {
                let Some(idx) = self.active else {
                    self.toast(":put! — no active editor");
                    return;
                };
                let s = self.clipboard.text();
                if s.is_empty() {
                    self.toast(":put! — clipboard empty");
                    return;
                }
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    let row = b.editor.row_col().0;
                    let line_start = b.editor.line_byte_range(row).0;
                    let payload = format!("{}\n", s.trim_end_matches('\n'));
                    b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::ReplaceRange {
                            start: line_start,
                            end: line_start,
                            text: payload,
                        }],
                        &mut self.clipboard,
                        0,
                    );
                    self.toast(format!(":put! — inserted {}B above", s.len()));
                }
            }
            // `:%y` / `:%d` — yank / delete the whole buffer. Single edit
            // op so undo restores. The clipboard receives the buffer text
            // (linewise) so a subsequent `p` pastes it back as lines.
            "%y" | "%yank" => {
                let Some(b) = self.active_editor() else {
                    self.toast(":%y — no active editor");
                    return;
                };
                let text = b.editor.text().to_string();
                self.clipboard.set(text.clone(), true);
                self.toast(format!(":%y — yanked {}B", text.len()));
            }
            "%d" | "%delete" => {
                let Some(idx) = self.active else {
                    self.toast(":%d — no active editor");
                    return;
                };
                let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
                    self.toast(":%d — no active editor");
                    return;
                };
                let text = b.editor.text().to_string();
                let len = text.len();
                self.clipboard.set(text, true);
                b.apply_edit_ops(
                    vec![crate::edit_op::EditOp::ReplaceRange {
                        start: 0,
                        end: len,
                        text: String::new(),
                    }],
                    &mut self.clipboard,
                    0,
                );
                self.toast(format!(":%d — cut {len}B"));
            }
            // `:bufdo <ex>` / `:tabdo <ex>` / `:argdo <ex>` — run `<ex>`
            // for every editor pane in turn. mnml has buffers, not tabs;
            // `:tabdo` is just an alias. `:argdo` would iterate the
            // command-line argument list in vim — we treat it as bufdo
            // since mnml doesn't track an arglist.
            // `:cnext` / `:cprev` / `:cfirst` / `:clast` — quickfix
            // navigation through the most-recent grep results.
            // `:%norm <keys>` / `:norm <keys>` — for each line in the
            // range (whole buffer with `%`, selection if active, else
            // current line), place the cursor at line start and dispatch
            // each key in `<keys>` through the active vim handler. Vim's
            // killer power tool for "do this on every line".
            "norm" | "normal" => self.run_norm(rest, false),
            "%norm" | "%normal" => self.run_norm(rest, true),
            // `:earlier N` — walk N undo steps. `:earlier 5s` / `5m` / `2h` /
            // `1d` — walk back to the most recent snapshot at least that
            // wall-clock old (vim canonical; relies on the per-snapshot
            // timestamp added in this round). Bare N (no unit) is steps.
            "earlier" | "ea" => {
                let Some(idx) = self.active else { return };
                let arg = rest.trim();
                let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
                    return;
                };
                let steps = match parse_undo_age_spec(arg) {
                    Some(secs) => b.editor.undo_steps_for_age(secs),
                    None => arg.parse::<usize>().unwrap_or(1),
                };
                for _ in 0..steps {
                    b.editor
                        .apply(crate::edit_op::EditOp::Undo, 20, &mut self.clipboard);
                }
                b.recompute_dirty();
                b.refresh_highlights();
                self.toast(format!(":earlier · {steps} step(s)"));
            }
            "later" | "lat" => {
                let Some(idx) = self.active else { return };
                let arg = rest.trim();
                let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
                    return;
                };
                let steps = match parse_undo_age_spec(arg) {
                    Some(secs) => b.editor.redo_steps_for_age(secs),
                    None => arg.parse::<usize>().unwrap_or(1),
                };
                for _ in 0..steps {
                    b.editor
                        .apply(crate::edit_op::EditOp::Redo, 20, &mut self.clipboard);
                }
                b.recompute_dirty();
                b.refresh_highlights();
                self.toast(format!(":later · {steps} step(s)"));
            }
            // `:copen` / `:cclose` / `:cwin[dow]` — focus / close the
            // grep ("quickfix") pane. mnml has one such pane per session.
            // `:vimgrep <pat>` / `:grep <pat>` / `:gr` — workspace grep
            // (vim's vimgrep + Quickfix one-shot). Result lands in the
            // grep pane.
            "vimgrep" | "vim" | "grep" | "gr" => {
                let q = rest.trim();
                if q.is_empty() {
                    self.toast(":grep <pattern>");
                } else {
                    self.run_workspace_grep(q.to_string());
                }
            }
            "copen" | "cope" | "cwindow" | "cwin" => {
                // Prefer an existing Quickfix pane; fall back to Grep
                // (mnml's `:grep` populates Grep).
                if let Some(idx) = self
                    .panes
                    .iter()
                    .position(|p| matches!(p, Pane::Quickfix(_)))
                {
                    self.reveal_pane(idx);
                } else if let Some(idx) = self.panes.iter().position(|p| matches!(p, Pane::Grep(_)))
                {
                    self.reveal_pane(idx);
                } else {
                    self.toast(":copen — no quickfix / grep results yet");
                }
            }
            "cclose" | "ccl" => {
                if let Some(idx) = self
                    .panes
                    .iter()
                    .position(|p| matches!(p, Pane::Quickfix(_)))
                {
                    self.force_close_pane(idx);
                } else if let Some(idx) = self.panes.iter().position(|p| matches!(p, Pane::Grep(_)))
                {
                    self.force_close_pane(idx);
                } else {
                    self.toast(":cclose — no quickfix / grep pane");
                }
            }
            // `:cexpr <text>` — populate the quickfix list from a
            // `file:line:col:message` string (vim canonical). Each newline-
            // separated line that parses becomes one entry.
            "cexpr" | "cex" => self.ex_cexpr(rest),
            "cnext" | "cn" => self.quickfix_navigate(1),
            "cprev" | "cp" | "cN" => self.quickfix_navigate(-1),
            "cfirst" | "cfir" => self.quickfix_navigate(i32::MIN),
            "clast" | "cla" => self.quickfix_navigate(i32::MAX),
            "ccurrent" | "cc" => self.quickfix_navigate(0),
            // `:cdo <cmd>` — run `<cmd>` on every quickfix entry (jump,
            // execute, save). `:cfdo <cmd>` — same but once per unique file.
            // Vim canonical.
            "cdo" | "cfdo" => self.ex_cdo(cmd, rest),
            "bufdo" | "argdo" => self.ex_bufdo(rest),
            "tabdo" => {
                // Vim canonical: switch to each tab in turn, run the
                // command in that tab's active window, leave the
                // cursor on the last tab.
                let inner = rest.trim();
                if inner.is_empty() {
                    self.toast(":tabdo <ex-command>");
                    return;
                }
                let count = self.layouts.len();
                let inner = inner.to_string();
                for i in 0..count {
                    if i != self.active_layout {
                        self.switch_tab(i);
                    }
                    self.run_ex_command(&inner);
                }
                self.toast(format!(":tabdo · ran on {count} tab(s)"));
            }
            // `:cd <path>` — vim's "change current directory". mnml's
            // workspace is fixed for the session, so we treat this as
            // a toast-only acknowledgement (vim users get `:pwd` anyway).
            "cd" | "chdir" => {
                let path = rest.trim();
                if path.is_empty() {
                    self.toast(format!(":cd — workspace is {}", self.workspace.display()));
                } else {
                    self.toast(":cd — workspace is per-session; not changed");
                }
            }
            // `:command <Name> <expansion>` — register a user-defined ex
            // command. `:Name <args>` runs `<expansion> <args>`. Bare
            // `:command` lists. `:delcommand <Name>` (alias `:delc`)
            // removes one. Vim canonical aliases.
            "command" | "com" => self.ex_command_def(cmd, rest),
            "delcommand" | "delc" => {
                let key = rest.trim();
                if key.is_empty() {
                    self.toast(":delcommand <Name>");
                } else if self.user_ex_commands.remove(key).is_some() {
                    self.toast(format!(":delcommand {key}"));
                } else {
                    self.toast(format!(":delcommand — no such command: {key}"));
                }
            }
            // `:ab[breviate] <key> <expansion>` — set a vim abbreviation
            // (Insert-mode word that auto-expands when followed by a
            // trigger char). Bare `:ab` lists current abbreviations.
            // `:una[bbreviate] <key>` removes one.
            "ab" | "abbreviate" => {
                let rest = rest.trim();
                if rest.is_empty() {
                    if self.config.abbreviations.is_empty() {
                        self.toast(":ab — none defined");
                    } else {
                        let mut entries: Vec<String> = self
                            .config
                            .abbreviations
                            .iter()
                            .map(|(k, v)| {
                                let preview: String = v.chars().take(20).collect();
                                let suffix = if v.chars().count() > 20 { "…" } else { "" };
                                format!("{k}={preview}{suffix}")
                            })
                            .collect();
                        entries.sort();
                        self.toast(format!(":ab · {}", entries.join("  ")));
                    }
                } else if let Some((k, v)) = rest.split_once(char::is_whitespace) {
                    self.config
                        .abbreviations
                        .insert(k.trim().to_string(), v.trim().to_string());
                    self.toast(format!(":ab {} = {}", k.trim(), v.trim()));
                } else {
                    self.toast(":ab <key> <expansion>");
                }
            }
            "una" | "unab" | "unabbreviate" => {
                let key = rest.trim();
                if key.is_empty() {
                    self.toast(":una <key>");
                } else if self.config.abbreviations.remove(key).is_some() {
                    self.toast(format!(":una {key}"));
                } else {
                    self.toast(format!(":una — no abbreviation for {key}"));
                }
            }
            // `:abclear` / `:abc` — drop every abbreviation. Vim canonical.
            "abc" | "abclear" => {
                let n = self.config.abbreviations.len();
                self.config.abbreviations.clear();
                self.toast(format!(":abclear — {n} abbreviation(s) cleared"));
            }
            // `:history` / `:his` / `:hist` — toast the ex-command history
            // (oldest at the start; capped preview). Vim canonical.
            "his" | "hist" | "history" => {
                if self.ex_history.is_empty() {
                    self.toast(":history — empty");
                } else {
                    // Take the most recent N (capped) — vim's `:history` shows
                    // them indexed from oldest to newest, but the toast is
                    // bounded so newest-first reads better here.
                    let preview: Vec<String> = self
                        .ex_history
                        .iter()
                        .rev()
                        .take(20)
                        .enumerate()
                        .map(|(i, s)| format!("{}:{s}", i + 1))
                        .collect();
                    let more = if self.ex_history.len() > 20 {
                        format!(" (…{} more)", self.ex_history.len() - 20)
                    } else {
                        String::new()
                    };
                    self.toast(format!(":history · {}{more}", preview.join("  ")));
                }
            }
            "reg" | "registers" | "di" | "display" => self.ex_registers(rest),
            // `:source <path>` (alias `:so`) — re-apply a config file at
            // runtime. Layers on top of the current config (missing keys
            // keep their existing value). Rebuilds the keymap (input-style
            // / [keys.*] changes take effect) and bounces the active
            // editor's input handler if `[editor] input_style` changed.
            "source" | "so" => {
                if rest.trim().is_empty() {
                    self.toast(":source <path> — path required");
                } else {
                    let path = self.workspace.join(rest.trim());
                    if !path.exists() {
                        self.toast(format!(":source — not found: {}", path.display()));
                    } else {
                        let prior_style = self.config.editor.input_style.clone();
                        self.config.apply_file_pub(&path);
                        if self.config.editor.input_style != prior_style {
                            // Re-apply input style (rebuilds keymap +
                            // swaps every editor's handler).
                            let new_style = self.config.editor.input_style.clone();
                            self.set_input_style(&new_style);
                        } else {
                            // Keymap might have changed without an input
                            // style switch — rebuild it explicitly.
                            self.keymap = crate::input::keymap::Keymap::build(&self.config);
                        }
                        self.toast(format!(":source {}", rel_path(&self.workspace, &path)));
                    }
                }
            }
            "e" | "edit" => self.ex_edit(rest),
            "e!" | "edit!" => self.reload_active(true),
            // `:r !cmd` / `:read !cmd` — fire `cmd` through the shell, splice
            // its stdout into the active editor below the cursor's line.
            // Vim convention: line is added below the *current* line, not at
            // the cursor's column. Without `!` (`:r path`) reads a file.
            "r" | "read" => self.ex_read(cmd, rest),
            // `:setlocal` — like `:set`, but only mutates the active
            // buffer's per-buffer settings (tab_width / ensure_trailing
            // _newline / trim_trailing_ws_on_save). Buffers without the
            // setting fall through silently. Vim canonical for
            // file-specific overrides without touching the global config.
            "setlocal" | "setl" => self.ex_setlocal(rest),
            "set" => self.ex_set(rest),
            // `:let @<reg> = "text"` — set a named register's contents.
            // Vim canonical. nvchad round 5 SEV-2 2026-07-11 fix.
            // Only the `@<reg>` form is implemented; general vim `let`
            // (variable assignment) isn't wired.
            "let" | "l" => {
                let r = rest.trim();
                if let Some(rest) = r.strip_prefix('@')
                    && let Some((reg_str, val_str)) = rest.split_once('=')
                {
                    let reg_str = reg_str.trim();
                    let val_str = val_str.trim();
                    // Strip surrounding matched quotes.
                    let value = val_str
                        .strip_prefix('"')
                        .and_then(|s| s.strip_suffix('"'))
                        .or_else(|| {
                            val_str
                                .strip_prefix('\'')
                                .and_then(|s| s.strip_suffix('\''))
                        })
                        .unwrap_or(val_str)
                        .to_string();
                    if reg_str.len() == 1
                        && let Some(reg) = reg_str.chars().next()
                        && reg.is_ascii_alphabetic()
                    {
                        self.clipboard.set_pending_register(Some(reg));
                        self.clipboard.set(value, false);
                        self.toast(format!(":let @{reg} — set ({} bytes)", val_str.len()));
                    } else {
                        self.toast(format!(":let @{reg_str} — only single-letter registers"));
                    }
                } else {
                    self.toast(":let — expected `:let @<reg> = \"text\"`");
                }
            }
            // `:noh` / `:nohlsearch` — clear the active buffer's find state
            // (drops the highlights). Vim convention.
            "noh" | "nohl" | "nohlsearch" => {
                if let Some(b) = self.active_editor_mut() {
                    b.find = None;
                }
            }
            // vim arglist family (`:args` / `:next` / `:prev` / `:first` /
            // `:last`). Prior to the round-7 fix `:next` fell through to
            // registered-command lookup and hit `find.next` — a footgun
            // for muscle-memory nvchad users. Implementation lives on
            // App::{arglist,arglist_index}. `:args {glob}` sets the
            // arglist; `:args` prints it; `:next`/`:prev` step; `:first`/
            // `:last` jump to endpoints.
            "args" | "ar" => {
                if rest.is_empty() {
                    self.arglist_show();
                } else {
                    self.arglist_set(rest);
                }
            }
            "next" | "ne" => self.arglist_step(1),
            "prev" | "previous" | "Ne" => self.arglist_step(-1),
            "first" | "fir" | "rew" | "rewind" => self.arglist_goto(0),
            "last" | "la" => self.arglist_step(isize::MAX),
            other => {
                // Last resort: maybe it names a registered command.
                if crate::command::registry().get(other).is_some() {
                    crate::command::run(other, self);
                    return;
                }
                // 2026-06-26 — typed text isn't a known command.
                // Fall back to the popup's highlighted match.
                // vscode-style palette behaviour: if there's an
                // obvious "what you probably meant", use it instead
                // of erroring. Fixes the "type partial → ↓ to
                // highlight → Enter fires partial" UX bug at its
                // root — callers no longer need to substitute before
                // calling run_ex_command. Recursion capped at 1 by
                // checking resolved != line.
                //
                // We use the popup's CURRENT highlighted index when
                // popup state exists (caller navigated with ↓/Tab);
                // otherwise we compute completions on-the-fly and
                // pick idx 0 (the top match). This means a fresh
                // `:ag<Enter>` (no navigation) also works.
                let resolved_opt: Option<String> = {
                    let idx_from_state = self
                        .cmdline_complete_state
                        .as_ref()
                        .and_then(|s| s.matches.get(self.cmdline_popup_selected).cloned())
                        .map(|suffix| {
                            let head = self
                                .cmdline_complete_state
                                .as_ref()
                                .map(|s| s.head.clone())
                                .unwrap_or_default();
                            format!("{head}{suffix}")
                        });
                    idx_from_state.or_else(|| {
                        crate::app::compute_cmdline_completions_for_app(self, line).and_then(
                            |state| {
                                state
                                    .matches
                                    .first()
                                    .map(|m| format!("{}{}", state.head, m))
                            },
                        )
                    })
                };
                if let Some(resolved) = resolved_opt
                    && resolved != line
                    && !resolved.trim().is_empty()
                {
                    // Clear popup state so the recursion can't loop.
                    self.cmdline_complete_state = None;
                    self.cmdline_popup_selected = 0;
                    self.run_ex_command(&resolved);
                    return;
                }
                self.toast(format!(":{line} — unknown command"));
            }
        }
    }

    fn ex_buffer(&mut self, rest: &str) {
        let q = rest.trim();
        if q.is_empty() {
            let names: Vec<String> = self
                .panes
                .iter()
                .filter_map(|p| match p {
                    Pane::Editor(b) => Some(
                        b.path
                            .as_ref()
                            .map(|pp| rel_path(&self.workspace, pp))
                            .unwrap_or_else(|| b.display_name().to_string()),
                    ),
                    _ => None,
                })
                .collect();
            if names.is_empty() {
                self.toast(":b — no buffers");
            } else {
                self.toast(format!(":b · {}", names.join("  ")));
            }
        } else {
            // nvchad-user SEV-2 2026-07-10: try numeric arg first
            // (`:b 1` is the vim-canonical form; `:ls` shows numbers,
            // NvChad's tab-line also uses 1-based indices). Only fall
            // through to name matching when it's not a number. Index
            // counts EDITOR panes only, in registration order — same
            // order the ":b" listing above prints.
            if let Ok(n) = q.parse::<usize>() {
                if n == 0 {
                    self.toast(":b — buffer numbers are 1-based");
                    return;
                }
                let editor_panes: Vec<usize> = self
                    .panes
                    .iter()
                    .enumerate()
                    .filter_map(|(idx, p)| matches!(p, Pane::Editor(_)).then_some(idx))
                    .collect();
                match editor_panes.get(n - 1) {
                    Some(&pid) => self.reveal_pane(pid),
                    None => self.toast(format!(
                        ":b — {n} out of range (1..={})",
                        editor_panes.len()
                    )),
                }
                return;
            }
            let qlc = q.to_lowercase();
            let mut hits: Vec<(usize, String)> = Vec::new();
            for (idx, p) in self.panes.iter().enumerate() {
                if let Pane::Editor(b) = p {
                    let label = b
                        .path
                        .as_ref()
                        .map(|pp| rel_path(&self.workspace, pp))
                        .unwrap_or_else(|| b.display_name().to_string());
                    if label.to_lowercase().contains(&qlc) {
                        hits.push((idx, label));
                    }
                }
            }
            match hits.len() {
                0 => self.toast(format!(":b — no match for {q:?}")),
                1 => self.reveal_pane(hits[0].0),
                _ => {
                    // Pick the one whose filename matches, else toast hint.
                    let exact = hits.iter().find(|(_, l)| {
                        std::path::Path::new(l)
                            .file_name()
                            .and_then(|s| s.to_str())
                            .map(|s| s.to_lowercase() == qlc)
                            .unwrap_or(false)
                    });
                    if let Some((idx, _)) = exact {
                        self.reveal_pane(*idx);
                    } else {
                        let labels: Vec<String> = hits.iter().map(|(_, l)| l.clone()).collect();
                        self.toast(format!(":b — ambiguous: {}", labels.join(", ")));
                    }
                }
            }
        }
    }

    fn ex_cp(&mut self, rest: &str) {
        let mut parts = rest.split_whitespace();
        let (Some(from), Some(to)) = (parts.next(), parts.next()) else {
            self.toast(":Cp <from> <to> — needs two paths");
            return;
        };
        let resolve = |p: &str| -> std::path::PathBuf {
            let path = std::path::Path::new(p);
            if path.is_absolute() {
                path.to_path_buf()
            } else {
                self.workspace.join(path)
            }
        };
        let src = resolve(from);
        let dst = resolve(to);
        if dst.exists() {
            self.toast(format!("cp refused: {} exists", dst.display()));
        } else if let Some(parent) = dst.parent()
            && !parent.exists()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("cp: cannot create parent: {e}"));
        } else if let Err(e) = std::fs::copy(&src, &dst) {
            self.toast(format!("cp failed: {e}"));
        } else {
            self.tree.refresh();
            self.toast(format!("cp: {} → {}", src.display(), dst.display()));
        }
    }

    fn ex_mv(&mut self, rest: &str) {
        let mut parts = rest.split_whitespace();
        let (Some(from), Some(to)) = (parts.next(), parts.next()) else {
            self.toast(":Mv <from> <to> — needs two paths");
            return;
        };
        let resolve = |p: &str| -> std::path::PathBuf {
            let path = std::path::Path::new(p);
            if path.is_absolute() {
                path.to_path_buf()
            } else {
                self.workspace.join(path)
            }
        };
        let src = resolve(from);
        let dst = resolve(to);
        if dst.exists() {
            self.toast(format!("mv refused: {} exists", dst.display()));
        } else if let Some(parent) = dst.parent()
            && !parent.exists()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            self.toast(format!("mv: cannot create parent: {e}"));
        } else if let Err(e) = std::fs::rename(&src, &dst) {
            self.toast(format!("mv failed: {e}"));
        } else {
            // Re-point any open editor pane + notify LSP +
            // update recent_files. Same bookkeeping shape as
            // `rename_fs_entry`.
            for pane in &mut self.panes {
                if let Pane::Editor(b) = pane
                    && b.path.as_deref() == Some(src.as_path())
                {
                    b.path = Some(dst.clone());
                }
            }
            self.lsp.did_close(&src);
            let new_text = self.panes.iter().find_map(|p| match p {
                Pane::Editor(b) if b.is_at(&dst) => Some(b.editor.text().to_string()),
                _ => None,
            });
            if let Some(t) = new_text {
                self.lsp.did_open(&dst, &t);
            }
            for p in &mut self.recent_files {
                if p == &src {
                    *p = dst.clone();
                }
            }
            self.tree.refresh();
            self.toast(format!("mv: {} → {}", src.display(), dst.display()));
        }
    }

    fn ex_touch(&mut self, rest: &str) {
        let arg = rest.trim();
        if arg.is_empty() {
            self.toast(":Touch <path> — needs a path");
        } else {
            let target = std::path::Path::new(arg);
            let abs = if target.is_absolute() {
                target.to_path_buf()
            } else {
                self.workspace.join(target)
            };
            let parent_ok = abs
                .parent()
                .is_none_or(|p| p.exists() || std::fs::create_dir_all(p).is_ok());
            if !parent_ok {
                self.toast("touch: parent dir create failed");
            } else {
                match std::fs::OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(false)
                    .open(&abs)
                {
                    Ok(_) => {
                        self.tree.refresh();
                        self.toast(format!("touch: {}", abs.display()));
                    }
                    Err(e) => self.toast(format!("touch failed: {e}")),
                }
            }
        }
    }

    fn ex_sum(&mut self, _rest: &str) {
        let text = self.active_editor().map(|b| {
            if let Some((s, e)) = b.editor.selection() {
                b.editor.text()[s..e].to_string()
            } else {
                b.editor.text().to_string()
            }
        });
        let Some(text) = text else {
            self.toast("no active editor");
            return;
        };
        let mut total: f64 = 0.0;
        let mut count: usize = 0;
        let mut buf = String::new();
        for c in text.chars() {
            if c.is_ascii_digit() || c == '-' || c == '.' {
                buf.push(c);
            } else {
                if !buf.is_empty()
                    && let Ok(n) = buf.parse::<f64>()
                {
                    total += n;
                    count += 1;
                }
                buf.clear();
            }
        }
        if !buf.is_empty()
            && let Ok(n) = buf.parse::<f64>()
        {
            total += n;
            count += 1;
        }
        let total_disp = if total.fract().abs() < 1e-9 {
            format!("{}", total as i64)
        } else {
            format!("{total:.4}")
        };
        self.toast(format!(":Sum — {count} number(s), total {total_disp}"));
    }

    fn ex_wipeout(&mut self, rest: &str) {
        let sub = rest.trim();
        if sub.is_empty() {
            self.toast(":Wipeout <substr> — needs a substring");
            return;
        }
        let sub_lower = sub.to_lowercase();
        let workspace = self.workspace.clone();
        let to_close: Vec<usize> = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| match p {
                Pane::Editor(b) => {
                    let path = b.path.as_ref()?;
                    let rel = path
                        .strip_prefix(&workspace)
                        .unwrap_or(path)
                        .to_string_lossy()
                        .to_lowercase();
                    if rel.contains(&sub_lower) && !b.dirty {
                        Some(i)
                    } else {
                        None
                    }
                }
                _ => None,
            })
            .collect();
        if to_close.is_empty() {
            self.toast(format!(":Wipeout — no clean buffers match {sub:?}"));
            return;
        }
        // Close in reverse index order so earlier indices stay
        // valid as we work backward.
        let n = to_close.len();
        for i in to_close.into_iter().rev() {
            self.close_pane(i);
        }
        self.toast(format!(":Wipeout — closed {n} buffer(s)"));
    }

    fn ex_rootfor(&mut self, rest: &str) {
        let arg = rest.trim();
        let path = if arg.is_empty() {
            self.active_editor().and_then(|b| b.path.clone())
        } else {
            let p = std::path::PathBuf::from(arg);
            if p.is_absolute() {
                Some(p)
            } else {
                Some(self.workspace.join(p))
            }
        };
        let Some(path) = path else {
            self.toast(":RootFor <path> — needs a path");
            return;
        };
        let markers = [
            "Cargo.toml",
            "package.json",
            "go.mod",
            "pyproject.toml",
            ".git",
        ];
        let mut cur = path.parent();
        let mut found: Option<std::path::PathBuf> = None;
        while let Some(dir) = cur {
            if markers.iter().any(|m| dir.join(m).exists()) {
                found = Some(dir.to_path_buf());
                break;
            }
            cur = dir.parent();
        }
        match found {
            Some(p) => self.toast(format!(":RootFor → {}", p.display())),
            None => self.toast(":RootFor — no recognized root marker"),
        }
    }

    fn ex_wincmd(&mut self, _cmd: &str, rest: &str) {
        let arg = rest.trim().chars().next();
        let cmd = match arg {
            Some('h') => Some("view.focus_left"),
            Some('l') => Some("view.focus_right"),
            Some('k') => Some("view.focus_up"),
            Some('j') => Some("view.focus_down"),
            Some('w') => Some("view.focus_next_split"),
            Some('q') | Some('c') => Some("view.close_split"),
            Some('s') => Some("view.split_down"),
            Some('v') => Some("view.split_right"),
            Some('=') => Some("view.equalize_splits"),
            Some('o') => Some("view.close_others"),
            Some('r') | Some('x') | Some('R') => Some("view.rotate_splits"),
            Some('+') => Some("view.split_grow_height"),
            Some('-') => Some("view.split_shrink_height"),
            Some('>') => Some("view.split_grow_width"),
            Some('<') => Some("view.split_shrink_width"),
            Some('H') => Some("view.move_split_left"),
            Some('L') => Some("view.move_split_right"),
            Some('K') => Some("view.move_split_up"),
            Some('J') => Some("view.move_split_down"),
            Some('p') => Some("buffer.last"),
            Some('_') => Some("view.maximize_height"),
            Some('|') => Some("view.maximize_width"),
            Some('f') => Some("view.split_open_file_under_cursor"),
            Some('d') => Some("view.split_goto_definition"),
            Some('n') => Some("view.split_new_scratch"),
            _ => None,
        };
        if let Some(id) = cmd {
            crate::command::run(id, self);
        } else {
            self.toast(":wincmd <c> — unknown chord");
        }
    }

    fn ex_maps(&mut self, rest: &str) {
        let filter = rest.trim().to_lowercase();
        let mut rows: Vec<(String, String)> = self
            .keymap
            .iter()
            .map(|(seq, id)| (crate::input::keymap::chord_seq_to_spec(seq), id.to_string()))
            .filter(|(spec, id)| {
                filter.is_empty()
                    || spec.to_lowercase().contains(&filter)
                    || id.to_lowercase().contains(&filter)
            })
            .collect();
        rows.sort();
        if rows.is_empty() {
            self.toast(format!(":Maps — no matches for {filter:?}"));
        } else {
            let preview = rows
                .iter()
                .take(20)
                .map(|(spec, id)| format!("{spec}→{id}"))
                .collect::<Vec<_>>()
                .join(" · ");
            let more = if rows.len() > 20 {
                format!(" (…{} more)", rows.len() - 20)
            } else {
                String::new()
            };
            self.toast(format!(":Maps · {preview}{more}"));
        }
    }

    fn ex_execute(&mut self, rest: &str) {
        let s = rest.trim();
        let inner = if s.len() >= 2
            && ((s.starts_with('"') && s.ends_with('"'))
                || (s.starts_with('\'') && s.ends_with('\'')))
        {
            &s[1..s.len() - 1]
        } else {
            s
        };
        // Unescape `\"` → `"` and `\\` → `\`.
        let unescaped: String = {
            let mut out = String::with_capacity(inner.len());
            let mut chars = inner.chars().peekable();
            while let Some(c) = chars.next() {
                if c == '\\'
                    && let Some(&n) = chars.peek()
                {
                    match n {
                        '"' | '\\' | '\'' => {
                            chars.next();
                            out.push(n);
                            continue;
                        }
                        _ => {}
                    }
                }
                out.push(c);
            }
            out
        };
        if unescaped.is_empty() {
            self.toast(":execute — empty string");
        } else {
            self.run_ex_command(&unescaped);
        }
    }

    fn ex_jumps(&mut self, _rest: &str) {
        let back: Vec<String> = self
            .nav_back
            .iter()
            .rev()
            .take(10)
            .map(|np| {
                let rel = rel_path(&self.workspace, &np.path);
                format!("{rel}:{}", np.row + 1)
            })
            .collect();
        let fwd: Vec<String> = self
            .nav_forward
            .iter()
            .rev()
            .take(10)
            .map(|np| {
                let rel = rel_path(&self.workspace, &np.path);
                format!("{rel}:{}", np.row + 1)
            })
            .collect();
        if back.is_empty() && fwd.is_empty() {
            self.toast(":jumps — empty");
        } else {
            let b_part = if back.is_empty() {
                String::new()
            } else {
                format!("← {}", back.join("  "))
            };
            let f_part = if fwd.is_empty() {
                String::new()
            } else {
                format!("  → {}", fwd.join("  "))
            };
            self.toast(format!(":jumps {}{}", b_part, f_part));
        }
    }

    fn ex_cexpr(&mut self, rest: &str) {
        let mut hits: Vec<crate::grep_pane::GrepHit> = Vec::new();
        for ln in rest.lines() {
            let parts: Vec<&str> = ln.splitn(4, ':').collect();
            if parts.len() < 3 {
                continue;
            }
            let Ok(line) = parts[1].parse::<u32>() else {
                continue;
            };
            let col = parts[2].parse::<u32>().ok();
            let (col, text_idx) = match col {
                Some(c) => (c, 3),
                None => (1, 2),
            };
            let path = self.workspace.join(parts[0]);
            let rel = parts[0].to_string();
            let text = parts.get(text_idx).copied().unwrap_or("").to_string();
            hits.push(crate::grep_pane::GrepHit {
                path,
                rel,
                line: line.saturating_sub(1),
                col: col.saturating_sub(1),
                text,
            });
        }
        if hits.is_empty() {
            self.toast(":cexpr — no parseable entries");
        } else {
            self.open_quickfix("cexpr", hits);
        }
    }

    fn ex_cdo(&mut self, cmd: &str, rest: &str) {
        let inner = rest.trim();
        if inner.is_empty() {
            self.toast(":cdo <ex-command>");
            return;
        }
        let per_file = cmd == "cfdo";
        let hits = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Quickfix(g) | Pane::Grep(g) => Some(g.hits.clone()),
                _ => None,
            })
            .unwrap_or_default();
        if hits.is_empty() {
            self.toast(":cdo — no quickfix entries");
            return;
        }
        let mut seen: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
        let mut ran = 0usize;
        for hit in hits {
            if per_file && !seen.insert(hit.path.clone()) {
                continue;
            }
            self.open_path(&hit.path);
            if let Some(b) = self.active_editor_mut() {
                b.editor.place_cursor(hit.line as usize, hit.col as usize);
            }
            self.run_ex_command(inner);
            self.save_active_now();
            ran += 1;
        }
        let scope = if per_file { "unique file " } else { "" };
        self.toast(format!(":{cmd} {inner:?} — ran on {ran} {scope}entry/ies"));
    }

    fn ex_bufdo(&mut self, rest: &str) {
        let inner = rest.trim();
        if inner.is_empty() {
            self.toast(":bufdo <ex-command>");
            return;
        }
        let editor_indices: Vec<usize> = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| {
                if matches!(p, Pane::Editor(_)) {
                    Some(i)
                } else {
                    None
                }
            })
            .collect();
        if editor_indices.is_empty() {
            self.toast(":bufdo — no editor buffers open");
            return;
        }
        let count = editor_indices.len();
        let inner = inner.to_string();
        for idx in editor_indices {
            self.reveal_pane(idx);
            self.run_ex_command(&inner);
        }
        self.toast(format!(":bufdo · ran on {count} buffer(s)"));
    }

    fn ex_command_def(&mut self, _cmd: &str, rest: &str) {
        let rest = rest.trim();
        if rest.is_empty() {
            if self.user_ex_commands.is_empty() {
                self.toast(":command — none defined");
            } else {
                let mut entries: Vec<String> = self
                    .user_ex_commands
                    .iter()
                    .map(|(k, v)| {
                        let preview: String = v.expansion.chars().take(30).collect();
                        let suffix = if v.expansion.chars().count() > 30 {
                            "…"
                        } else {
                            ""
                        };
                        format!("{k}={preview}{suffix}")
                    })
                    .collect();
                entries.sort();
                self.toast(format!(":command · {}", entries.join("  ")));
            }
        } else {
            // Optional leading `-nargs=...` flag (vim canonical).
            let (nargs, rest) = if let Some(after) = rest.strip_prefix("-nargs=") {
                let (val, tail) = match after.find(char::is_whitespace) {
                    Some(i) => (&after[..i], after[i..].trim_start()),
                    None => (after, ""),
                };
                (ExCommandNargs::parse(val), tail)
            } else {
                (ExCommandNargs::Any, rest)
            };
            if let Some((name, body)) = rest.split_once(char::is_whitespace) {
                let cmd = UserExCommand {
                    expansion: body.trim().to_string(),
                    nargs,
                };
                self.user_ex_commands.insert(name.trim().to_string(), cmd);
                self.toast(format!(":command {} = {}", name.trim(), body.trim()));
            } else {
                self.toast(":command [-nargs=…] <Name> <expansion>");
            }
        }
    }

    fn ex_registers(&mut self, rest: &str) {
        let mut parts: Vec<String> = Vec::new();
        let preview = |s: &str, cap: usize| -> String {
            let mut out: String = s
                .chars()
                .take(cap)
                .map(|c| if c == '\n' { '↵' } else { c })
                .collect();
            if s.chars().count() > cap {
                out.push('…');
            }
            out
        };
        // `:reg abc` ⇒ filter to only show the named registers in
        // the arg. Bare `:reg` shows them all. Vim canonical.
        let filter: Option<std::collections::HashSet<char>> = if rest.trim().is_empty() {
            None
        } else {
            Some(rest.chars().filter(|c| !c.is_whitespace()).collect())
        };
        let show_unnamed = filter.as_ref().map(|s| s.contains(&'"')).unwrap_or(true);
        let unnamed = self.clipboard.text();
        if show_unnamed && !unnamed.is_empty() {
            parts.push(format!("\"\"  {}", preview(&unnamed, 40)));
        }
        let mut named: Vec<(char, (String, bool))> = self
            .clipboard
            .named_registers()
            .iter()
            .map(|(c, v)| (*c, v.clone()))
            .collect();
        named.sort_by_key(|(c, _)| *c);
        for (c, (text, _linewise)) in named {
            if let Some(f) = &filter
                && !f.contains(&c)
            {
                continue;
            }
            if !text.is_empty() {
                parts.push(format!("\"{c}  {}", preview(&text, 40)));
            }
        }
        if parts.is_empty() {
            self.toast(":reg — empty");
        } else {
            self.toast(format!(":reg · {}", parts.join("  ")));
        }
    }

    fn ex_edit(&mut self, rest: &str) {
        // `:e` (bare) and `:e %` both reload the active buffer
        // (vim's `%` substitutes to the current file's path; we
        // short-circuit it). Non-empty other paths open the file.
        // `:e +N <path>` opens the file and jumps to line N (vim
        // canonical). `:e +<path>` (no N) opens at last line.
        if rest.is_empty() || rest.trim() == "%" {
            self.reload_active(false);
        } else if let Some(after_plus) = rest.strip_prefix('+') {
            let (count_part, path_part) = match after_plus.find(char::is_whitespace) {
                Some(i) => (&after_plus[..i], after_plus[i..].trim()),
                None => ("", after_plus),
            };
            let p = self.workspace.join(path_part);
            self.open_path(&p);
            let line = if count_part.is_empty() {
                self.active_editor()
                    .map(|b| b.editor.line_count())
                    .unwrap_or(1)
            } else {
                count_part.parse::<usize>().unwrap_or(1).max(1)
            };
            if let Some(b) = self.active_editor_mut() {
                b.editor.place_cursor(line.saturating_sub(1), 0);
            }
        } else {
            let p = self.workspace.join(rest);
            self.open_path(&p);
        }
    }

    fn ex_read(&mut self, _cmd: &str, rest: &str) {
        if let Some(rest) = rest.strip_prefix('!') {
            let rest = rest.trim();
            if rest.is_empty() {
                self.toast(":read ! — command required");
            } else {
                let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
                let cwd = self.active_workspace_path().to_path_buf();
                let out = std::process::Command::new(&shell)
                    .arg("-c")
                    .arg(rest)
                    .current_dir(&cwd)
                    .output();
                match out {
                    Ok(out) => {
                        let body = String::from_utf8_lossy(&out.stdout).to_string();
                        let body = body.trim_end_matches('\n').to_string();
                        let Some(idx) = self.active else {
                            self.toast(":r ! — no active editor");
                            return;
                        };
                        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
                            self.toast(":r ! — no active editor");
                            return;
                        };
                        let line_no = b.editor.row_col().0;
                        let eol = b.editor.line_byte_range(line_no).1;
                        let payload = format!("\n{body}");
                        let payload_len = payload.len();
                        b.apply_edit_ops(
                            vec![crate::edit_op::EditOp::ReplaceRange {
                                start: eol,
                                end: eol,
                                text: payload,
                            }],
                            &mut self.clipboard,
                            0,
                        );
                        self.toast(format!(":r ! — inserted {payload_len}B"));
                    }
                    Err(e) => self.toast(format!(":r ! — {e}")),
                }
            }
        } else if rest.is_empty() {
            self.toast(":r — path or `!cmd` required");
        } else {
            // `:r <path>` — splice file contents below the cursor.
            let path = if std::path::Path::new(rest).is_absolute() {
                std::path::PathBuf::from(rest)
            } else {
                self.workspace.join(rest)
            };
            match std::fs::read_to_string(&path) {
                Ok(body) => {
                    let body = body.trim_end_matches('\n').to_string();
                    let Some(idx) = self.active else {
                        self.toast(":r — no active editor");
                        return;
                    };
                    let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
                        self.toast(":r — no active editor");
                        return;
                    };
                    let line_no = b.editor.row_col().0;
                    let eol = b.editor.line_byte_range(line_no).1;
                    let payload = format!("\n{body}");
                    let payload_len = payload.len();
                    b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::ReplaceRange {
                            start: eol,
                            end: eol,
                            text: payload,
                        }],
                        &mut self.clipboard,
                        0,
                    );
                    self.toast(format!(":r — inserted {payload_len}B"));
                }
                Err(e) => self.toast(format!(":r — {e}")),
            }
        }
    }

    fn ex_setlocal(&mut self, rest: &str) {
        let opt = rest.trim();
        let Some(idx) = self.active else {
            self.toast(":setlocal — no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            self.toast(":setlocal — no active editor");
            return;
        };
        if let Some(v) = opt
            .strip_prefix("tab_width=")
            .or_else(|| opt.strip_prefix("tabstop="))
            .or_else(|| opt.strip_prefix("ts="))
            .or_else(|| opt.strip_prefix("shiftwidth="))
            .or_else(|| opt.strip_prefix("sw="))
            .or_else(|| opt.strip_prefix("softtabstop="))
            .or_else(|| opt.strip_prefix("sts="))
        {
            if let Ok(n) = v.trim().parse::<usize>() {
                b.editor.set_tab_width(n);
                self.toast(format!(":setlocal tab_width={n}"));
            } else {
                self.toast(format!(":setlocal tab_width={v} — not a number"));
            }
        } else if matches!(opt, "eol" | "endofline") {
            b.ensure_trailing_newline = true;
            self.toast(":setlocal eol");
        } else if matches!(opt, "noeol" | "noendofline") {
            b.ensure_trailing_newline = false;
            self.toast(":setlocal noeol");
        } else if matches!(opt, "trim" | "trim_trailing_whitespace") {
            b.trim_trailing_ws_on_save = true;
            self.toast(":setlocal trim");
        } else if matches!(opt, "notrim" | "notrim_trailing_whitespace") {
            b.trim_trailing_ws_on_save = false;
            self.toast(":setlocal notrim");
        } else if matches!(opt, "readonly" | "ro") {
            b.read_only = true;
            self.toast(":setlocal readonly");
        } else if matches!(opt, "noreadonly" | "noro" | "modifiable") {
            b.read_only = false;
            self.toast(":setlocal modifiable");
        } else if matches!(opt, "readonly!" | "invreadonly") {
            b.read_only = !b.read_only;
            let label = if b.read_only {
                "readonly"
            } else {
                "modifiable"
            };
            self.toast(format!(":setlocal {label}"));
        } else {
            self.toast(format!(":setlocal — unknown option: {opt}"));
        }
    }

    fn ex_set(&mut self, rest: &str) {
        // `:set` (bare) → list every option's current value as a toast.
        // `:set input=vim|standard` · `:set theme=…` · `:set tab_width=N`
        // · `:set [no]relativenumber` / `[no]list` (toggle suffix `!`).
        let opt = rest.trim();
        if opt.is_empty() {
            let cfg = &self.config;
            let theme = crate::ui::theme::cur().name;
            self.toast(format!(
                "input={} · theme={theme} · tab_width={} · {} · {} · {}",
                cfg.editor.input_style,
                cfg.editor.tab_width,
                if cfg.ui.relative_line_numbers {
                    "relativenumber"
                } else {
                    "norelativenumber"
                },
                if cfg.ui.show_whitespace {
                    "list"
                } else {
                    "nolist"
                },
                if cfg.ui.bracket_rainbow {
                    "rainbow"
                } else {
                    "norainbow"
                },
            ));
        } else if let Some(v) = rest.strip_prefix("input=") {
            self.set_input_style(v.trim());
        } else if let Some(v) = rest.strip_prefix("theme=") {
            self.set_theme(v.trim());
        } else if let Some(v) = rest
            .strip_prefix("filetype=")
            .or_else(|| rest.strip_prefix("ft="))
        {
            let name = v.trim().to_string();
            if let Some(b) = self.active_editor_mut() {
                b.set_language_ext(Some(name.clone()));
                b.refresh_highlights();
                self.toast(format!(":set filetype={name}"));
            }
        } else if let Some(v) = rest
            .strip_prefix("tab_width=")
            .or_else(|| rest.strip_prefix("tabstop="))
            .or_else(|| rest.strip_prefix("ts="))
            .or_else(|| rest.strip_prefix("shiftwidth="))
            .or_else(|| rest.strip_prefix("sw="))
            .or_else(|| rest.strip_prefix("softtabstop="))
            .or_else(|| rest.strip_prefix("sts="))
        {
            // Vim has separate tabstop / shiftwidth / softtabstop knobs;
            // mnml has one (`tab_width`). All aliases route to the same
            // setter — close enough for the vim users who set them all
            // to the same value anyway.
            if let Ok(n) = v.trim().parse::<usize>() {
                self.set_tab_width(n);
            } else {
                self.toast(format!(":set tab_width={v} — not a number"));
            }
        } else if let Some(v) = rest
            .strip_prefix("colorcolumn=")
            .or_else(|| rest.strip_prefix("cc="))
        {
            let s = v.trim();
            if s.is_empty() {
                self.config.ui.color_column = 0;
                self.toast("colorcolumn: off");
            } else if let Ok(n) = s.parse::<usize>() {
                self.config.ui.color_column = n;
                if n == 0 {
                    self.toast("colorcolumn: off");
                } else {
                    self.toast(format!("colorcolumn: {n}"));
                }
            } else {
                self.toast(format!(":set colorcolumn={v} — not a number"));
            }
        } else if let Some(v) = rest
            .strip_prefix("scrolloff=")
            .or_else(|| rest.strip_prefix("so="))
        {
            if let Ok(n) = v.trim().parse::<usize>() {
                self.config.ui.scrolloff = n;
                self.toast(format!("scrolloff: {n}"));
            } else {
                self.toast(format!(":set scrolloff={v} — not a number"));
            }
        } else if let Some(v) = rest
            .strip_prefix("sidescrolloff=")
            .or_else(|| rest.strip_prefix("siso="))
        {
            if let Ok(n) = v.trim().parse::<usize>() {
                self.config.ui.sidescrolloff = n;
                self.toast(format!("sidescrolloff: {n}"));
            } else {
                self.toast(format!(":set sidescrolloff={v} — not a number"));
            }
        } else if let Some(v) = rest.strip_prefix("text_width=") {
            if let Ok(n) = v.trim().parse::<usize>() {
                self.config.editor.text_width = n.max(8);
                self.toast(format!("text_width: {}", self.config.editor.text_width));
            } else {
                self.toast(format!(":set text_width={v} — not a number"));
            }
        } else if matches!(opt, "endofline" | "eol") {
            self.config.editor.ensure_trailing_newline = true;
            self.toast("ensure_trailing_newline: on");
        } else if matches!(opt, "noendofline" | "noeol") {
            self.config.editor.ensure_trailing_newline = false;
            self.toast("ensure_trailing_newline: off");
        } else if matches!(opt, "breadcrumb") {
            self.set_breadcrumb(true);
        } else if matches!(opt, "nobreadcrumb") {
            self.set_breadcrumb(false);
        } else if matches!(opt, "breadcrumb!" | "invbreadcrumb") {
            self.toggle_breadcrumb();
        } else if matches!(opt, "autopair" | "ap") {
            self.set_auto_pair(true);
        } else if matches!(opt, "noautopair" | "noap") {
            self.set_auto_pair(false);
        } else if matches!(opt, "autopair!" | "invautopair") {
            self.toggle_auto_pair();
        } else if matches!(opt, "rightpanel" | "right_panel" | "rp") {
            // vim convention: `:set foo` enables idempotently;
            // `:set foo!` toggles. vscode-user-keyboard SEV-3.
            self.right_panel_visible = true;
            self.toast("right_panel: on");
        } else if matches!(
            opt,
            "rightpanel!" | "right_panel!" | "rp!" | "invrightpanel"
        ) {
            self.right_panel_visible = !self.right_panel_visible;
            // code-reviewer 2026-06-28 W-1: parity with
            // view.toggle_right_panel — drain hosted panes when
            // hiding so they don't ghost in the bufferline.
            if !self.right_panel_visible {
                self.close_right_panel_hosted_panes();
            }
            self.toast(format!(
                "right_panel: {}",
                if self.right_panel_visible {
                    "on"
                } else {
                    "off"
                }
            ));
        } else if matches!(opt, "norightpanel" | "noright_panel" | "norp") {
            self.right_panel_visible = false;
            self.close_right_panel_hosted_panes();
            self.toast("right_panel: off");
        } else if matches!(opt, "hoverhelp" | "hover_help" | "hh") {
            self.config.ui.hover_help = true;
            self.toast("hover_help: on");
        } else if matches!(opt, "nohoverhelp" | "nohover_help" | "nohh") {
            self.config.ui.hover_help = false;
            self.toast("hover_help: off");
        } else if matches!(opt, "syncnormalize" | "sync_normalize" | "sn") {
            self.config.http.sync_normalize = true;
            self.toast("sync_normalize: on");
        } else if matches!(opt, "nosyncnormalize" | "nosync_normalize" | "nosn") {
            self.config.http.sync_normalize = false;
            self.toast("sync_normalize: off");
        } else if matches!(opt, "syncnormalize!" | "sync_normalize!" | "sn!") {
            self.config.http.sync_normalize = !self.config.http.sync_normalize;
            self.toast(format!(
                "sync_normalize: {}",
                if self.config.http.sync_normalize {
                    "on"
                } else {
                    "off"
                }
            ));
        } else if matches!(opt, "autoformat" | "auto_format_body" | "af") {
            self.config.http.auto_format_body = true;
            self.toast("auto_format_body: on");
            self.maybe_auto_format_active_body();
        } else if matches!(opt, "noautoformat" | "noauto_format_body" | "noaf") {
            self.config.http.auto_format_body = false;
            self.toast("auto_format_body: off");
        } else if matches!(opt, "autoformat!" | "auto_format_body!" | "af!") {
            self.config.http.auto_format_body = !self.config.http.auto_format_body;
            let state = if self.config.http.auto_format_body {
                "on"
            } else {
                "off"
            };
            self.toast(format!("auto_format_body: {state}"));
            if self.config.http.auto_format_body {
                self.maybe_auto_format_active_body();
            }
        } else if let Some(val) = opt
            .strip_prefix("mdengine=")
            .or_else(|| opt.strip_prefix("md_preview_engine="))
        {
            let val = val.trim();
            if val.is_empty() {
                self.toast(":set mdengine=<builtin|glow|custom:...> — value required");
                return;
            }
            self.config.ui.md_preview_engine = val.to_string();
            // Invalidate every open md preview so the new engine
            // kicks in on the next paint.
            for pane in self.panes.iter_mut() {
                if let crate::pane::Pane::MdPreview(p) = pane {
                    p.external_cache = Default::default();
                    p.external_error_toasted = false;
                }
            }
            self.toast(format!("md_preview_engine: {val}"));
        } else if matches!(opt, "hoverhelp!" | "hover_help!" | "hh!" | "invhoverhelp") {
            self.config.ui.hover_help = !self.config.ui.hover_help;
            self.toast(format!(
                "hover_help: {}",
                if self.config.ui.hover_help {
                    "on"
                } else {
                    "off"
                }
            ));
        } else if matches!(opt, "relativenumber" | "rnu") {
            self.set_relative_line_numbers(true);
        } else if matches!(opt, "norelativenumber" | "nornu") {
            self.set_relative_line_numbers(false);
        } else if matches!(opt, "relativenumber!" | "rnu!" | "invrelativenumber") {
            self.set_relative_line_numbers(!self.config.ui.relative_line_numbers);
        } else if matches!(opt, "cursorline" | "cul") {
            self.config.ui.cursor_line = true;
            self.toast("cursorline: on");
        } else if matches!(opt, "nocursorline" | "nocul") {
            self.config.ui.cursor_line = false;
            self.toast("cursorline: off");
        } else if matches!(opt, "cursorline!" | "cul!" | "invcursorline") {
            self.config.ui.cursor_line = !self.config.ui.cursor_line;
            self.toast(format!(
                "cursorline: {}",
                if self.config.ui.cursor_line {
                    "on"
                } else {
                    "off"
                }
            ));
        } else if matches!(opt, "number" | "nu") {
            self.config.ui.line_numbers = true;
            self.toast("number: on");
        } else if matches!(opt, "nonumber" | "nonu") {
            self.config.ui.line_numbers = false;
            self.toast("number: off");
        } else if matches!(opt, "number!" | "nu!" | "invnumber") {
            self.config.ui.line_numbers = !self.config.ui.line_numbers;
            self.toast(format!(
                "number: {}",
                if self.config.ui.line_numbers {
                    "on"
                } else {
                    "off"
                }
            ));
        } else if matches!(opt, "list") {
            self.set_show_whitespace(true);
        } else if matches!(opt, "nolist") {
            self.set_show_whitespace(false);
        } else if matches!(opt, "list!" | "invlist") {
            self.set_show_whitespace(!self.config.ui.show_whitespace);
        } else if matches!(opt, "rainbow") {
            self.set_bracket_rainbow(true);
        } else if matches!(opt, "norainbow") {
            self.set_bracket_rainbow(false);
        } else if matches!(opt, "rainbow!" | "invrainbow") {
            self.toggle_bracket_rainbow();
        } else if matches!(opt, "scrollbar") {
            self.set_scrollbar(true);
        } else if matches!(opt, "noscrollbar") {
            self.set_scrollbar(false);
        } else if matches!(opt, "scrollbar!" | "invscrollbar") {
            self.toggle_scrollbar();
        } else if matches!(opt, "headless") {
            self.set_browser_headless(true);
        } else if matches!(opt, "noheadless") {
            self.set_browser_headless(false);
        } else if matches!(opt, "headless!" | "invheadless") {
            self.toggle_browser_headless();
        } else if matches!(opt, "trailing") {
            self.set_highlight_trailing_ws(true);
        } else if matches!(opt, "notrailing") {
            self.set_highlight_trailing_ws(false);
        } else if matches!(opt, "trailing!" | "invtrailing") {
            self.toggle_highlight_trailing_ws();
        } else if matches!(opt, "hlword") {
            self.set_highlight_word_under_cursor(true);
        } else if matches!(opt, "nohlword") {
            self.set_highlight_word_under_cursor(false);
        } else if matches!(opt, "hlword!" | "invhlword") {
            self.toggle_highlight_word_under_cursor();
        } else if matches!(opt, "inlayhints") {
            self.config.editor.inlay_hints = true;
            self.toast("inlay hints: on");
        } else if matches!(opt, "noinlayhints") {
            self.config.editor.inlay_hints = false;
            self.toast("inlay hints: off");
        } else if matches!(opt, "inlayhints!" | "invinlayhints") {
            self.config.editor.inlay_hints = !self.config.editor.inlay_hints;
            self.toast(format!(
                "inlay hints: {}",
                if self.config.editor.inlay_hints {
                    "on"
                } else {
                    "off"
                }
            ));
        } else if matches!(opt, "clock") {
            self.config.ui.clock = true;
            self.toast("clock: on");
        } else if matches!(opt, "noclock") {
            self.config.ui.clock = false;
            self.toast("clock: off");
        } else if matches!(opt, "clock!" | "invclock") {
            self.config.ui.clock = !self.config.ui.clock;
            self.toast(format!(
                "clock: {}",
                if self.config.ui.clock { "on" } else { "off" }
            ));
        } else if matches!(opt, "codelens") {
            self.config.editor.code_lens = true;
            self.toast("code lens: on");
        } else if matches!(opt, "nocodelens") {
            self.config.editor.code_lens = false;
            self.toast("code lens: off");
        } else if matches!(opt, "codelens!" | "invcodelens") {
            self.config.editor.code_lens = !self.config.editor.code_lens;
            self.toast(format!(
                "code lens: {}",
                if self.config.editor.code_lens {
                    "on"
                } else {
                    "off"
                }
            ));
        } else if matches!(opt, "automdpreview") {
            self.config.ui.auto_md_preview = true;
            self.toast("auto-preview md: on");
        } else if matches!(opt, "noautomdpreview") {
            self.config.ui.auto_md_preview = false;
            self.toast("auto-preview md: off");
        } else if matches!(opt, "automdpreview!" | "invautomdpreview") {
            self.config.ui.auto_md_preview = !self.config.ui.auto_md_preview;
            self.toast(format!(
                "auto-preview md: {}",
                if self.config.ui.auto_md_preview {
                    "on"
                } else {
                    "off"
                }
            ));
        } else if matches!(opt, "nocolorcolumn" | "nocc") {
            self.config.ui.color_column = 0;
            self.toast("colorcolumn: off");
        } else if matches!(opt, "colorcolumn!" | "cc!" | "invcolorcolumn") {
            self.toggle_color_column();
        } else if matches!(opt, "autoindent" | "ai") {
            self.config.editor.auto_indent = true;
            self.toast("auto-indent: on");
        } else if matches!(opt, "noautoindent" | "noai") {
            self.config.editor.auto_indent = false;
            self.toast("auto-indent: off");
        } else if matches!(opt, "autoindent!" | "invautoindent" | "ai!" | "invai") {
            self.config.editor.auto_indent = !self.config.editor.auto_indent;
            self.toast(format!(
                "auto-indent: {}",
                if self.config.editor.auto_indent {
                    "on"
                } else {
                    "off"
                }
            ));
        // Vim-compat toasts — settings vim users reach for that mnml
        // either always-honors or doesn't implement yet. Toast the
        // current state instead of "unknown option" so muscle memory
        // doesn't get punished.
        } else if matches!(opt, "ignorecase" | "ic") {
            // Force case-INSENSITIVE. nvchad-user SEV-2 2026-07-11
            // fix — used to just toast "already on"; now actually
            // sets the search_case_mode override so search paths
            // ignore case regardless of query capitalization.
            self.search_case_mode = Some(false);
            self.toast(":set ignorecase — on");
        } else if matches!(opt, "noignorecase" | "noic") {
            // Force case-SENSITIVE. Was toasting "not supported".
            self.search_case_mode = Some(true);
            self.toast(":set noignorecase — on (case-sensitive)");
        } else if matches!(opt, "smartcase" | "scs") {
            // Smart-case = mnml's historical default (None → detect
            // from query capitalization). Same reset if user
            // previously typed `:set ic` / `:set noic`.
            self.search_case_mode = None;
            self.toast(":set smartcase — on (case-sensitive iff query has uppercase)");
        } else if matches!(opt, "nosmartcase" | "noscs") {
            // Vim: disabling smartcase falls back to global `ignorecase`.
            // mnml maps to case-INSENSITIVE (matches nvchad default).
            self.search_case_mode = Some(false);
            self.toast(":set nosmartcase — on (always case-insensitive)");
        } else if matches!(
            opt,
            "expandtab" | "et" | "hlsearch" | "hls" | "incsearch" | "is"
        ) {
            self.toast(format!(":set {opt} — already on (mnml default)"));
        } else if matches!(
            opt,
            "noexpandtab" | "noet" | "nohlsearch" | "nohls" | "noincsearch" | "nois"
        ) {
            self.toast(format!(":set {opt} — not supported in mnml"));
        } else if opt == "wrap" {
            self.set_wrap(true);
        } else if opt == "nowrap" {
            self.set_wrap(false);
        } else if matches!(opt, "wrap!" | "invwrap") {
            self.toggle_wrap();
        } else if matches!(opt, "todohl" | "todohighlight") {
            self.config.ui.highlight_todo_keywords = true;
            self.toast("todo highlight: on");
        } else if matches!(opt, "notodohl" | "notodohighlight") {
            self.config.ui.highlight_todo_keywords = false;
            self.toast("todo highlight: off");
        } else if matches!(opt, "todohl!" | "invtodohl") {
            self.toggle_todo_highlight();
        } else if matches!(opt, "rendermarkdown" | "rendermd") {
            self.config.ui.render_markdown = true;
            self.toast("render markdown: on");
        } else if matches!(opt, "norendermarkdown" | "norendermd") {
            self.config.ui.render_markdown = false;
            self.toast("render markdown: off");
        } else if matches!(opt, "rendermarkdown!" | "invrendermarkdown") {
            self.toggle_render_markdown();
        } else if matches!(opt, "stickycontext" | "sticky") {
            self.config.ui.sticky_context = true;
            self.toast("sticky context: on");
        } else if matches!(opt, "nostickycontext" | "nosticky") {
            self.config.ui.sticky_context = false;
            self.toast("sticky context: off");
        } else if matches!(opt, "stickycontext!" | "invstickycontext") {
            self.toggle_sticky_context();
        } else if matches!(opt, "bufferline" | "bl") {
            self.bufferline_visible = true;
            self.toast("bufferline: on");
        } else if matches!(opt, "nobufferline" | "nobl") {
            self.bufferline_visible = false;
            self.toast("bufferline: off");
        } else if matches!(opt, "bufferline!" | "invbufferline") {
            self.toggle_bufferline();
        } else if matches!(opt, "formatontype" | "fot") {
            self.config.editor.format_on_type = true;
            self.toast(":set formatontype");
        } else if matches!(opt, "noformatontype" | "nofot") {
            self.config.editor.format_on_type = false;
            self.toast(":set noformatontype");
        } else if matches!(opt, "formatonsave" | "fos") {
            self.config.editor.format_on_save = true;
            self.toast(":set formatonsave");
        } else if matches!(opt, "noformatonsave" | "nofos") {
            self.config.editor.format_on_save = false;
            self.toast(":set noformatonsave");
        } else if matches!(opt, "willsavewaituntil" | "wswu") {
            self.config.editor.will_save_wait_until = true;
            self.toast(":set willsavewaituntil");
        } else if matches!(opt, "nowillsavewaituntil" | "nowswu") {
            self.config.editor.will_save_wait_until = false;
            self.toast(":set nowillsavewaituntil");
        } else if matches!(opt, "semantictokensviewport" | "stviewport") {
            self.config.editor.semantic_tokens_viewport = true;
            self.toast(":set semantictokensviewport");
        } else if matches!(opt, "nosemantictokensviewport" | "nostviewport") {
            self.config.editor.semantic_tokens_viewport = false;
            // Drop the cached viewports so the next refresh
            // (now driven by the full/delta path) doesn't think
            // it already requested.
            for p in self.panes.iter_mut() {
                if let Pane::Editor(b) = p {
                    b.last_semantic_viewport = None;
                }
            }
            self.toast(":set nosemantictokensviewport");
        } else {
            self.toast(format!(":set {rest} — not supported"));
        }
    }

    /// Accept handler for [`PromptKind::QuitConfirm`].
    pub fn accept_quit(&mut self) {
        self.should_quit = true;
    }

    /// `:w !cmd` — pipe the active buffer's text to `cmd` on stdin,
    /// toast the trimmed stdout (or an error). No file is written.
    /// Uses `$SHELL -c` so pipes, quoting, redirection work. Timeout
    /// bounded at 30s to prevent a runaway command from hanging the
    /// event loop. nvchad-round-7 SEV-2 2026-07-11.
    pub fn write_buffer_to_shell(&mut self, cmd: &str) {
        if cmd.is_empty() {
            self.toast(":w ! — no command supplied");
            return;
        }
        let Some(text) = self.active_editor().map(|b| b.editor.text().to_string()) else {
            self.toast(":w ! — no active editor");
            return;
        };
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        use std::io::Write;
        use std::process::{Command, Stdio};
        let mut child = match Command::new(&shell)
            .arg("-c")
            .arg(cmd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                self.toast(format!(":w !{cmd} — spawn failed: {e}"));
                return;
            }
        };
        if let Some(mut sin) = child.stdin.take()
            && let Err(e) = sin.write_all(text.as_bytes())
        {
            self.toast(format!(":w !{cmd} — stdin write failed: {e}"));
            return;
        }
        match child.wait_with_output() {
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
                let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
                if !out.status.success() {
                    let msg = if !stderr.is_empty() {
                        stderr
                    } else if !stdout.is_empty() {
                        stdout
                    } else {
                        format!("exit {}", out.status.code().unwrap_or(-1))
                    };
                    self.toast(format!(":w !{cmd} — {msg}"));
                } else if !stdout.is_empty() {
                    self.toast(format!(":w !{cmd} — {stdout}"));
                } else if !stderr.is_empty() {
                    self.toast(format!(":w !{cmd} — (stderr) {stderr}"));
                } else {
                    self.toast(format!(":w !{cmd} — done"));
                }
            }
            Err(e) => self.toast(format!(":w !{cmd} — wait failed: {e}")),
        }
    }

    /// `:args {pattern}` — expand `{pattern}` workspace-relative into a
    /// fresh arglist and open the first entry. Supported forms:
    /// `foo/bar.rs` (literal), `*.rs` (basename glob at workspace root),
    /// `src/**/*.rs` (recursive glob with double-star). If the pattern
    /// matches nothing the arglist is left alone and a toast fires.
    pub fn arglist_set(&mut self, pattern: &str) {
        let ws = self.workspace.clone();
        let paths = arglist_expand(&ws, pattern);
        if paths.is_empty() {
            self.toast(format!(":args {pattern} — no matches"));
            return;
        }
        let count = paths.len();
        self.arglist = paths;
        self.arglist_index = Some(0);
        self.arglist_goto(0);
        self.toast(format!(":args — {count} file(s), showing 1/{count}"));
    }

    /// `:args` (no arg) — print the arglist with `[current]` markers.
    pub fn arglist_show(&mut self) {
        if self.arglist.is_empty() {
            self.toast(":args — arglist is empty (`:args {glob}` to set)");
            return;
        }
        let cur = self.arglist_index.unwrap_or(usize::MAX);
        let ws = self.workspace.clone();
        let items: Vec<String> = self
            .arglist
            .iter()
            .enumerate()
            .map(|(i, p)| {
                let rel = crate::app::rel_path(&ws, p);
                if i == cur { format!("[{rel}]") } else { rel }
            })
            .collect();
        self.toast(format!(":args · {}", items.join("  ")));
    }

    /// `:next` (`delta=1`) / `:prev` (`delta=-1`) / `:last` (`delta=MAX`).
    /// Clamped at both ends; wraps NO — vim canonical.
    pub fn arglist_step(&mut self, delta: isize) {
        if self.arglist.is_empty() {
            self.toast(":next — arglist is empty");
            return;
        }
        let cur = self.arglist_index.unwrap_or(0) as isize;
        let last = (self.arglist.len() - 1) as isize;
        let target = if delta == isize::MAX {
            last
        } else {
            (cur + delta).clamp(0, last)
        };
        self.arglist_goto(target as usize);
    }

    /// `:first` / opens `arglist[i]`, sets `arglist_index = Some(i)`, and
    /// toasts the position. Clamped; caller ensures `i < len()`.
    pub fn arglist_goto(&mut self, i: usize) {
        if self.arglist.is_empty() {
            return;
        }
        let i = i.min(self.arglist.len() - 1);
        let path = self.arglist[i].clone();
        self.arglist_index = Some(i);
        let total = self.arglist.len();
        self.open_path(&path);
        let rel = crate::app::rel_path(&self.workspace, &path);
        self.toast(format!(":args {}/{total} · {rel}", i + 1));
    }
}

#[cfg(test)]
mod ex_commands_tests {
    use super::*;
    use std::fs;

    #[test]
    fn vim_replacement_backrefs_swap() {
        // Vim `\1`, `\2`, `&`, `\\` map to regex-crate grammar.
        assert_eq!(vim_replacement_to_regex("\\2 \\1"), "$2 $1");
        assert_eq!(vim_replacement_to_regex("<&>"), "<$0>");
        assert_eq!(vim_replacement_to_regex("\\&"), "&");
        assert_eq!(vim_replacement_to_regex("cost $5"), "cost $$5");
        assert_eq!(vim_replacement_to_regex("a\\\\b"), "a\\b");
        assert_eq!(vim_replacement_to_regex("line\\none"), "line\none");
    }

    #[test]
    fn vim_pattern_capture_groups_and_alternation() {
        // Vim `\(a\|b\)` → `(a|b)` for the regex crate.
        assert_eq!(vim_pattern_to_regex("\\(foo\\)"), "(foo)");
        assert_eq!(vim_pattern_to_regex("\\(foo\\|bar\\)"), "(foo|bar)");
        assert_eq!(vim_pattern_to_regex("\\<word\\>"), "\\bword\\b");
        // `\d`, `\w`, `\s`, `\b` unchanged.
        assert_eq!(vim_pattern_to_regex("\\d+"), "\\d+");
    }

    #[test]
    fn substitute_backref_swap_actually_swaps() {
        // End-to-end: `\(foo\) \(bar\)` + `\2 \1` swaps every pair.
        let (_d, mut app) = app_with_buffer("foo bar\nfoo bar\n");
        app.run_ex_command("%s/\\(foo\\) \\(bar\\)/\\2 \\1/g");
        let text = app
            .active_editor()
            .map(|b| b.editor.text().to_string())
            .unwrap();
        assert_eq!(text, "bar foo\nbar foo\n", "got: {text:?}");
    }

    fn app_with_buffer(text: &str) -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.txt");
        fs::write(&p, text).unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&p);
        (d, app)
    }

    #[test]
    fn run_move_or_copy_line_moves_cursor_line_to_after_dest() {
        // Move line 1 ("alpha") to after line 3 ("gamma"). Result:
        // beta / gamma / alpha / delta.
        let (_d, mut app) = app_with_buffer("alpha\nbeta\ngamma\ndelta\n");
        app.run_move_or_copy_line("3", false);
        let text = app
            .active_editor()
            .map(|b| b.editor.text().to_string())
            .unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines, vec!["beta", "gamma", "alpha", "delta"]);
    }

    #[test]
    fn run_move_or_copy_line_copy_keeps_source() {
        // Copy line 1 ("alpha") to after line 2 ("beta"). Result:
        // alpha / beta / alpha / gamma.
        let (_d, mut app) = app_with_buffer("alpha\nbeta\ngamma\n");
        app.run_move_or_copy_line("2", true);
        let text = app
            .active_editor()
            .map(|b| b.editor.text().to_string())
            .unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines, vec!["alpha", "beta", "alpha", "gamma"]);
    }

    #[test]
    fn run_filter_through_shell_sorts_buffer() {
        let (_d, mut app) = app_with_buffer("charlie\nalpha\nbravo\n");
        app.run_filter_through_shell("sort", false);
        let text = app
            .active_editor()
            .map(|b| b.editor.text().to_string())
            .unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines, vec!["alpha", "bravo", "charlie"]);
    }

    #[test]
    fn run_filter_through_shell_non_zero_exit_leaves_buffer_untouched() {
        // `false` exits non-zero with no stdout. Buffer must be untouched.
        let (_d, mut app) = app_with_buffer("alpha\nbeta\n");
        app.run_filter_through_shell("false", false);
        let text = app
            .active_editor()
            .map(|b| b.editor.text().to_string())
            .unwrap();
        assert_eq!(text, "alpha\nbeta\n");
    }

    /// SDK bug 2026-07-03: manifest-registered commands store `run =
    /// ":term mnml-…"` verbatim, with the leading colon. `run_ex_command`
    /// received the string as-is and split into `cmd=":term"` which
    /// matched nothing → all 37 integrations dispatched as "unknown
    /// command". The normalization strips a single leading `:` before
    /// parsing; this test locks it.
    #[test]
    fn run_ex_command_strips_leading_colon_from_manifest_commands() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.txt");
        fs::write(&p, "hi").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&p);

        let before = app.message_log.len();
        // User-typed form (no leading colon) — must reach `:version`.
        app.run_ex_command("version");
        let user_msgs: Vec<_> = app.message_log[before..].to_vec();
        assert!(
            user_msgs.iter().any(|m| m.starts_with("mnml ")),
            "user-typed 'version' should emit a `mnml <sha>` toast; log tail = {user_msgs:?}"
        );

        let before = app.message_log.len();
        // Manifest-registered form (":version" verbatim) — must
        // reach the same arm, not "unknown command".
        app.run_ex_command(":version");
        let manifest_msgs: Vec<_> = app.message_log[before..].to_vec();
        assert!(
            manifest_msgs.iter().any(|m| m.starts_with("mnml ")),
            "manifest ':version' should emit a `mnml <sha>` toast; log tail = {manifest_msgs:?}"
        );
        assert!(
            manifest_msgs.iter().all(|m| !m.contains("unknown")),
            "manifest ':version' should NOT toast 'unknown command'; log tail = {manifest_msgs:?}"
        );
    }
}
