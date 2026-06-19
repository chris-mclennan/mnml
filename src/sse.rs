//! Tiny Server-Sent Events parser. Both Anthropic and OpenAI stream
//! responses as SSE — `data: <json>` lines separated by blank lines,
//! with optional `event:` lines. We don't need full RFC compliance;
//! both providers stick to the simple subset.
//!
//! Shape per event:
//!
//! ```text
//! event: content_block_delta\n
//! data: {"type":"content_block_delta","delta":{"text":"hello"}}\n
//! \n
//! ```
//!
//! `Reader::events` yields one `Event { name, data }` per blank-line-
//! delimited block. The `data` field is the concatenation of all
//! `data:` lines (joined with `\n`); `name` is the last `event:` value
//! seen, or empty.
//!
//! OpenAI uses a special `[DONE]` payload to signal end-of-stream;
//! callers handle that themselves.

use std::io::{BufRead, BufReader, Read};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Event {
    pub name: String,
    pub data: String,
}

pub struct Reader<R: Read> {
    inner: BufReader<R>,
    pending: Event,
}

impl<R: Read> Reader<R> {
    pub fn new(inner: R) -> Self {
        Self {
            inner: BufReader::new(inner),
            pending: Event::default(),
        }
    }

    /// Read events one at a time. Returns Ok(None) at EOF.
    pub fn next_event(&mut self) -> std::io::Result<Option<Event>> {
        loop {
            let mut line = String::new();
            let n = self.inner.read_line(&mut line)?;
            if n == 0 {
                // EOF — flush any pending event.
                if self.pending != Event::default() {
                    let evt = std::mem::take(&mut self.pending);
                    return Ok(Some(evt));
                }
                return Ok(None);
            }
            // SSE uses `\n` or `\r\n`; trim either.
            while line.ends_with('\n') || line.ends_with('\r') {
                line.pop();
            }
            if line.is_empty() {
                // Blank line = dispatch event.
                if self.pending == Event::default() {
                    continue;
                }
                let evt = std::mem::take(&mut self.pending);
                return Ok(Some(evt));
            }
            if let Some(rest) = line.strip_prefix("event:") {
                self.pending.name = rest.trim_start().to_string();
            } else if let Some(rest) = line.strip_prefix("data:") {
                if !self.pending.data.is_empty() {
                    self.pending.data.push('\n');
                }
                self.pending.data.push_str(rest.trim_start());
            } else if line.starts_with(':') {
                // Comment / keepalive — ignore.
            } else {
                // Non-spec line — also ignore.
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn read_all(input: &str) -> Vec<Event> {
        let mut r = Reader::new(Cursor::new(input.as_bytes()));
        let mut out = Vec::new();
        while let Some(e) = r.next_event().unwrap() {
            out.push(e);
        }
        out
    }

    #[test]
    fn single_event_with_name_and_data() {
        let events = read_all("event: ping\ndata: hello\n\n");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].name, "ping");
        assert_eq!(events[0].data, "hello");
    }

    #[test]
    fn multiple_events_separated_by_blank_lines() {
        let input = "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n";
        let events = read_all(input);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].data, "1");
        assert_eq!(events[1].data, "2");
    }

    #[test]
    fn multi_data_lines_joined_with_newline() {
        let events = read_all("data: line one\ndata: line two\n\n");
        assert_eq!(events[0].data, "line one\nline two");
    }

    #[test]
    fn comments_and_keepalives_ignored() {
        let events = read_all(": comment\n: another\ndata: real\n\n");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "real");
    }

    #[test]
    fn handles_crlf_line_endings() {
        let events = read_all("event: x\r\ndata: y\r\n\r\n");
        assert_eq!(events[0].name, "x");
        assert_eq!(events[0].data, "y");
    }

    #[test]
    fn flushes_unterminated_event_at_eof() {
        let events = read_all("data: lonely");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "lonely");
    }

    #[test]
    fn empty_input_is_empty() {
        let events = read_all("");
        assert!(events.is_empty());
    }
}
