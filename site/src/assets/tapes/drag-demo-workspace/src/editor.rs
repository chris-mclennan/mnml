//! The Editor — single chokepoint for all buffer mutations.
//!
//! Storage is a plain `String` + byte cursor; every mutation goes
//! through `apply` so a rope can slide in later without touching
//! call sites.

use crate::edit_op::EditOp;

pub struct Editor {
    text: String,
    cursor: usize,
}

impl Editor {
    pub fn new() -> Self {
        Self {
            text: String::new(),
            cursor: 0,
        }
    }

    /// Apply a single edit op to the buffer. The one chokepoint —
    /// input handlers translate keys into EditOps, the editor
    /// executes them.
    pub fn apply(&mut self, op: EditOp) {
        match op {
            EditOp::Insert(s) => {
                self.text.insert_str(self.cursor, &s);
                self.cursor += s.len();
            }
            EditOp::Delete(n) => {
                let end = (self.cursor + n).min(self.text.len());
                self.text.drain(self.cursor..end);
            }
            EditOp::MoveCursor(delta) => {
                let new = (self.cursor as isize + delta).max(0) as usize;
                self.cursor = new.min(self.text.len());
            }
        }
    }
}
