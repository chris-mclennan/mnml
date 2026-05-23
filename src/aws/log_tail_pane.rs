//! `Pane::LogTail` — a streaming, scrollable, per-line-classified log
//! viewer for CodeBuild CloudWatch streams. Sibling to the existing
//! pty-based log tail (`tail_selected_codebuild_logs`) but with two
//! advantages:
//!
//! * Per-line **status coloring** — ERROR / WARN / DEBUG / INFO lines
//!   get distinct theme colors so scrolling through long runs is much
//!   easier than reading uniform pty output.
//! * Scrollable buffer with `j`/`k`/`G`/`g`/`PgDn`/`PgUp` (no terminal
//!   passthrough getting in the way).
//!
//! Spawns `aws logs tail --follow ...` in a background thread; stdout
//! lines stream over an `mpsc` channel into the pane's local buffer.
//! `App::tick` drains the channel. Drop kills the child.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::thread::{self, JoinHandle};

/// One line's severity classification, used for coloring.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineSeverity {
    Error,
    Warn,
    Info,
    Debug,
    Plain,
}

impl LineSeverity {
    /// Classify a single line of log output. The match is case-sensitive
    /// for the canonical loglib-style tags, case-insensitive for the
    /// plain English variants. First match wins; conservative — we'd
    /// rather under-classify than mislabel.
    pub fn classify(line: &str) -> LineSeverity {
        // Most loggers print `[ERROR]` / `ERROR:` / `[WARN]` / etc.
        // We also catch lowercase Rust-panic style (`panicked at`).
        if line.contains("[ERROR]")
            || line.contains("ERROR:")
            || line.contains(" ERROR ")
            || line.contains("[FAIL]")
            || line.contains("FAIL:")
            || line.contains("Exception")
            || line.contains("panicked at")
            || line.contains("panic:")
        {
            LineSeverity::Error
        } else if line.contains("[WARN]")
            || line.contains("WARN:")
            || line.contains(" WARN ")
            || line.contains("[WARNING]")
            || line.contains("WARNING:")
        {
            LineSeverity::Warn
        } else if line.contains("[INFO]") || line.contains("INFO:") || line.contains(" INFO ") {
            LineSeverity::Info
        } else if line.contains("[DEBUG]") || line.contains("DEBUG:") || line.contains(" DEBUG ") {
            LineSeverity::Debug
        } else {
            LineSeverity::Plain
        }
    }
}

/// Per-line entry the pane holds.
#[derive(Debug, Clone)]
pub struct LogLine {
    pub text: String,
    pub severity: LineSeverity,
}

#[derive(Debug)]
pub struct LogTailPane {
    /// e.g. `logs · b3a47fc8…` (the stream name's prefix).
    pub title: String,
    /// CloudWatch log group + stream this tail is watching. Stashed so
    /// the renderer can show them in the header.
    pub log_group: String,
    pub log_stream: String,
    /// Most-recent lines first? No — append-only newest-last so the
    /// natural scroll position is at the bottom (`G`).
    pub lines: Vec<LogLine>,
    /// Top rendered row. `usize::MAX` ⇒ follow the tail.
    pub scroll: usize,
    /// Set by the worker thread when the child exits.
    pub exited: Arc<AtomicBool>,
    /// Set true to ask the worker to kill the child + bail.
    cancel: Arc<AtomicBool>,
    /// Per-line cap to keep memory bounded on long-running tails.
    capacity: usize,
    /// Background thread + child handle for cleanup.
    _reader: Option<JoinHandle<()>>,
    child: Option<Child>,
}

/// Channel item from the reader thread back to the App.
#[derive(Debug)]
pub enum LogTailEvent {
    /// One line of stdout (already trimmed of the trailing `\n`).
    Line(String),
    /// The aws process exited or was killed.
    Exited(i32),
    /// Spawn / pipe error.
    Failed(String),
}

const DEFAULT_CAPACITY: usize = 10_000;

impl LogTailPane {
    /// Spawn `aws logs tail --follow ...` and start streaming lines via
    /// `tx`. Returns the pane (with the reader thread + child stashed
    /// for cleanup) and the receiver side of the channel.
    pub fn spawn(
        log_group: String,
        log_stream: String,
        aws_region: Option<String>,
        cwd: std::path::PathBuf,
    ) -> Result<(Self, Receiver<LogTailEvent>), String> {
        let (tx, rx) = channel::<LogTailEvent>();
        let mut args: Vec<String> = vec![
            "logs".into(),
            "tail".into(),
            "--follow".into(),
            "--log-group-name".into(),
            log_group.clone(),
            "--log-stream-names".into(),
            log_stream.clone(),
            // `--format short` strips the date prefix (we already know
            // these are recent + the line is short enough without it).
            "--format".into(),
            "short".into(),
        ];
        if let Some(r) = aws_region.clone() {
            args.push("--region".into());
            args.push(r);
        }
        let mut child = Command::new("aws")
            .args(&args)
            .current_dir(&cwd)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("spawn aws logs tail: {e}"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "no stdout pipe".to_string())?;
        let stderr = child.stderr.take();
        let exited = Arc::new(AtomicBool::new(false));
        let cancel = Arc::new(AtomicBool::new(false));
        let exited_for_thread = exited.clone();
        let cancel_for_thread = cancel.clone();
        let tx_err = tx.clone();
        // stderr reader — surface aws CLI errors as `Failed` events.
        if let Some(stderr) = stderr {
            thread::spawn(move || {
                let reader = BufReader::new(stderr);
                let mut combined = String::new();
                for line in reader.lines().map_while(Result::ok) {
                    if !line.is_empty() {
                        combined.push_str(&line);
                        combined.push('\n');
                    }
                }
                if !combined.is_empty() {
                    let _ = tx_err.send(LogTailEvent::Failed(combined));
                }
            });
        }
        let reader_handle = thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                if cancel_for_thread.load(Ordering::Relaxed) {
                    break;
                }
                match line {
                    Ok(l) => {
                        if tx.send(LogTailEvent::Line(l)).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            exited_for_thread.store(true, Ordering::Relaxed);
            let _ = tx.send(LogTailEvent::Exited(0));
        });
        let title = format!("logs · {}", &log_stream[..log_stream.len().min(8)]);
        Ok((
            LogTailPane {
                title,
                log_group,
                log_stream,
                lines: Vec::new(),
                scroll: usize::MAX,
                exited,
                cancel,
                capacity: DEFAULT_CAPACITY,
                _reader: Some(reader_handle),
                child: Some(child),
            },
            rx,
        ))
    }

    pub fn tab_title(&self) -> String {
        self.title.clone()
    }

    /// Push a new line, classify it, drop the oldest when over capacity.
    /// If the user is "following the tail" (`scroll == usize::MAX`), the
    /// renderer keeps showing the latest line.
    pub fn push_line(&mut self, text: String) {
        let severity = LineSeverity::classify(&text);
        self.lines.push(LogLine { text, severity });
        if self.lines.len() > self.capacity {
            let drop_n = self.lines.len() - self.capacity;
            self.lines.drain(..drop_n);
            // If scroll was a fixed line number, shift it.
            if self.scroll != usize::MAX {
                self.scroll = self.scroll.saturating_sub(drop_n);
            }
        }
    }
}

impl Drop for LogTailPane {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            // Don't block — just kick the child off.
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_picks_severity() {
        assert_eq!(
            LineSeverity::classify("[ERROR] something broke"),
            LineSeverity::Error
        );
        assert_eq!(
            LineSeverity::classify("WARNING: rate limit approaching"),
            LineSeverity::Warn
        );
        assert_eq!(
            LineSeverity::classify("[INFO] connected"),
            LineSeverity::Info
        );
        assert_eq!(
            LineSeverity::classify("[DEBUG] handshake bytes"),
            LineSeverity::Debug
        );
        assert_eq!(
            LineSeverity::classify("plain text with no tags"),
            LineSeverity::Plain
        );
        // Exception keyword in the middle of a stack trace still hits.
        assert_eq!(
            LineSeverity::classify("    at /usr/lib... raised Exception"),
            LineSeverity::Error
        );
        // panicked-at hits.
        assert_eq!(
            LineSeverity::classify("thread 'foo' panicked at src/lib.rs:42:5"),
            LineSeverity::Error
        );
    }

    #[test]
    fn push_line_classifies_and_caps_capacity() {
        // Use a constructor that doesn't shell out — fake the pane.
        let mut p = LogTailPane {
            title: "test".into(),
            log_group: "g".into(),
            log_stream: "s".into(),
            lines: Vec::new(),
            scroll: usize::MAX,
            exited: Arc::new(AtomicBool::new(false)),
            cancel: Arc::new(AtomicBool::new(false)),
            capacity: 3,
            _reader: None,
            child: None,
        };
        p.push_line("[ERROR] bad".into());
        p.push_line("[INFO] hi".into());
        p.push_line("plain".into());
        p.push_line("[WARN] mild".into());
        // Capacity 3 → first entry dropped.
        assert_eq!(p.lines.len(), 3);
        assert_eq!(p.lines[0].text, "[INFO] hi");
        assert_eq!(p.lines[2].severity, LineSeverity::Warn);
    }
}
