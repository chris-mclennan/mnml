//! The signature-help popup — a small overlay showing the function prototype
//! you're typing inside, with the active parameter highlighted. Triggered
//! by typing `(` or `,` in insert mode (or via `lsp.signature_help`),
//! populated from `textDocument/signatureHelp` replies.
//!
//! Read-only — Esc dismisses, any cursor jump dismisses, a fresh reply
//! replaces. Multi-signature overload sets just show the active one (no
//! up/down cycle yet).

use crate::lsp::{SignatureHelp, SignatureInfo};

#[derive(Debug, Clone)]
pub struct SignaturePopup {
    pub signatures: Vec<SignatureInfo>,
    pub active: usize,
}

impl SignaturePopup {
    pub fn from_reply(sh: SignatureHelp) -> Option<SignaturePopup> {
        if sh.signatures.is_empty() {
            return None;
        }
        let active = sh.active_signature.min(sh.signatures.len() - 1);
        Some(SignaturePopup {
            signatures: sh.signatures,
            active,
        })
    }

    pub fn active_sig(&self) -> &SignatureInfo {
        &self.signatures[self.active]
    }

    /// Cycle to the next signature in an overload set (no-op when there's
    /// only one). Wraps. Wired through a future `lsp.signature_next` chord —
    /// the popup itself doesn't capture keys yet.
    pub fn cycle(&mut self) {
        if self.signatures.len() > 1 {
            self.active = (self.active + 1) % self.signatures.len();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sig(label: &str, params: &[(usize, usize)], active: Option<usize>) -> SignatureInfo {
        SignatureInfo {
            label: label.to_string(),
            parameters: params.to_vec(),
            active_parameter: active,
        }
    }

    #[test]
    fn from_reply_picks_active() {
        let sh = SignatureHelp {
            signatures: vec![
                sig("foo()", &[], None),
                sig("bar(x: int)", &[(4, 11)], Some(0)),
            ],
            active_signature: 1,
        };
        let p = SignaturePopup::from_reply(sh).unwrap();
        assert_eq!(p.active, 1);
        assert_eq!(p.active_sig().label, "bar(x: int)");
    }

    #[test]
    fn from_reply_empty_is_none() {
        let sh = SignatureHelp {
            signatures: vec![],
            active_signature: 0,
        };
        assert!(SignaturePopup::from_reply(sh).is_none());
    }

    #[test]
    fn cycle_wraps() {
        let sh = SignatureHelp {
            signatures: vec![sig("a", &[], None), sig("b", &[], None)],
            active_signature: 0,
        };
        let mut p = SignaturePopup::from_reply(sh).unwrap();
        p.cycle();
        assert_eq!(p.active, 1);
        p.cycle();
        assert_eq!(p.active, 0);
    }
}
