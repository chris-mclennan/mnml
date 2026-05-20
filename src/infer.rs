//! candle inference for quantized qwen2.5-coder — load the GGUF weights
//! + tokenizer, then run a fill-in-the-middle generation loop.
//!
//! FIM prompt shape (qwen2.5-coder):
//!   <|fim_prefix|> {prefix} <|fim_suffix|> {suffix} <|fim_middle|>
//! the model then generates the middle. Greedy decoding (argmax) — for
//! code completion determinism beats sampling diversity.

use std::path::Path;

use candle_core::quantized::gguf_file;
use candle_core::{Device, IndexOp, Tensor};
use candle_transformers::models::quantized_qwen2::ModelWeights;
use tokenizers::Tokenizer;

pub struct Model {
    weights: ModelWeights,
    tokenizer: Tokenizer,
    device: Device,
    fim_prefix: u32,
    fim_suffix: u32,
    fim_middle: u32,
    /// Tokens that end generation — EOS, FIM padding/sep, and the FIM
    /// markers themselves (the model occasionally re-emits one).
    stop_tokens: Vec<u32>,
}

impl Model {
    /// Load the quantized weights + tokenizer from disk. Blocking +
    /// CPU-bound — call on a worker thread.
    pub fn load(gguf: &Path, tokenizer_path: &Path) -> Result<Self, String> {
        let device = Device::Cpu;
        let mut file =
            std::fs::File::open(gguf).map_err(|e| format!("open gguf: {e}"))?;
        let content = gguf_file::Content::read(&mut file)
            .map_err(|e| format!("read gguf: {e}"))?;
        let weights = ModelWeights::from_gguf(content, &mut file, &device)
            .map_err(|e| format!("load weights: {e}"))?;
        let tokenizer = Tokenizer::from_file(tokenizer_path)
            .map_err(|e| format!("load tokenizer: {e}"))?;
        let tid = |s: &str| -> Result<u32, String> {
            tokenizer
                .token_to_id(s)
                .ok_or_else(|| format!("tokenizer missing special token {s}"))
        };
        let fim_prefix = tid("<|fim_prefix|>")?;
        let fim_suffix = tid("<|fim_suffix|>")?;
        let fim_middle = tid("<|fim_middle|>")?;
        let mut stop_tokens = Vec::new();
        for s in [
            "<|endoftext|>",
            "<|fim_pad|>",
            "<|file_sep|>",
            "<|fim_prefix|>",
            "<|fim_suffix|>",
            "<|fim_middle|>",
            "<|repo_name|>",
            "<|im_end|>",
        ] {
            if let Some(id) = tokenizer.token_to_id(s) {
                stop_tokens.push(id);
            }
        }
        Ok(Model {
            weights,
            tokenizer,
            device,
            fim_prefix,
            fim_suffix,
            fim_middle,
            stop_tokens,
        })
    }

    /// Generate up to `max_tokens` of completion for the cursor between
    /// `prefix` and `suffix`. Greedy decoding; stops at a stop token.
    pub fn complete(
        &mut self,
        prefix: &str,
        suffix: &str,
        max_tokens: usize,
    ) -> Result<String, String> {
        let pre = self
            .tokenizer
            .encode(prefix, false)
            .map_err(|e| format!("encode prefix: {e}"))?;
        let suf = self
            .tokenizer
            .encode(suffix, false)
            .map_err(|e| format!("encode suffix: {e}"))?;
        // <|fim_prefix|> prefix <|fim_suffix|> suffix <|fim_middle|>
        let mut tokens: Vec<u32> = Vec::with_capacity(pre.len() + suf.len() + 3);
        tokens.push(self.fim_prefix);
        tokens.extend_from_slice(pre.get_ids());
        tokens.push(self.fim_suffix);
        tokens.extend_from_slice(suf.get_ids());
        tokens.push(self.fim_middle);

        let prompt_len = tokens.len();
        // Prompt pass — feed the whole FIM prompt at position 0. (Each
        // completion re-fills the KV cache from 0; masked attention
        // means stale entries past the high-water mark are never read.)
        let input = Tensor::new(tokens.as_slice(), &self.device)
            .and_then(|t| t.unsqueeze(0))
            .map_err(|e| format!("prompt tensor: {e}"))?;
        let mut logits = self
            .weights
            .forward(&input, 0)
            .map_err(|e| format!("prompt forward: {e}"))?;

        let mut generated: Vec<u32> = Vec::new();
        for step in 0..max_tokens {
            let next = argmax_last(&logits)?;
            if self.stop_tokens.contains(&next) {
                break;
            }
            generated.push(next);
            let input = Tensor::new(&[next], &self.device)
                .and_then(|t| t.unsqueeze(0))
                .map_err(|e| format!("step tensor: {e}"))?;
            logits = self
                .weights
                .forward(&input, prompt_len + step)
                .map_err(|e| format!("step forward: {e}"))?;
        }
        let raw = self
            .tokenizer
            .decode(&generated, true)
            .map_err(|e| format!("decode: {e}"))?;
        Ok(trim_at_suffix(&raw, suffix))
    }
}

/// FIM models often don't stop cleanly — after filling the hole they
/// "rejoin" by re-emitting the code that already follows the cursor.
/// Cut the completion at the earliest point where it starts reproducing
/// the suffix.
///
/// Probes with leading *raw* substrings of the suffix (longest first,
/// so a longer rejoin context wins). Anchoring on the suffix's actual
/// bytes — including its leading `\n` — keeps a short probe like `\n}`
/// precise: it won't false-match a brace inside the legit completion.
/// Probes that are pure whitespace are skipped.
fn trim_at_suffix(completion: &str, suffix: &str) -> String {
    let mut out = completion;
    // Char-boundary-safe prefix lengths of the suffix, capped at 48.
    let cap: usize = suffix
        .char_indices()
        .nth(48)
        .map(|(i, _)| i)
        .unwrap_or(suffix.len());
    // Try decreasing prefix lengths; first (longest) match wins.
    let mut end = cap;
    while end >= 2 {
        let probe = &suffix[..end];
        if !probe.trim().is_empty()
            && let Some(idx) = out.find(probe)
        {
            out = &out[..idx];
            break;
        }
        // Step back to the previous char boundary.
        end -= 1;
        while end >= 2 && !suffix.is_char_boundary(end) {
            end -= 1;
        }
    }
    out.trim_end_matches([' ', '\t', '\n', '\r']).to_string()
}

#[cfg(test)]
mod tests {
    use super::trim_at_suffix;

    #[test]
    fn trims_at_suffix_rejoin() {
        // The model filled `a + b` then re-emitted the closing brace +
        // a whole extra fn — cut at the `\n}` that matches the suffix.
        let completion = "a + b\n}\n\nfn main() {\n    add(1, 2);\n}";
        let suffix = "\n}\n";
        assert_eq!(trim_at_suffix(completion, suffix), "a + b");
    }

    #[test]
    fn keeps_completion_with_no_overlap() {
        let completion = "let x = 1;";
        let suffix = "\nprintln!(\"done\");\n";
        assert_eq!(trim_at_suffix(completion, suffix), "let x = 1;");
    }

    #[test]
    fn whitespace_only_suffix_is_left_alone() {
        let completion = "foo()";
        // A pure-whitespace suffix yields no usable probe.
        assert_eq!(trim_at_suffix(completion, "\n   \n"), "foo()");
    }

    #[test]
    fn longer_probe_wins() {
        // Both `}` and `} else {` could match; the longer rejoin
        // context is the more confident cut point.
        let completion = "do_thing()\n} else {\n    other()";
        let suffix = "\n} else {\n    fallback()\n}";
        assert_eq!(trim_at_suffix(completion, suffix), "do_thing()");
    }
}

/// argmax over the vocab dimension of a logits tensor. Accepts either
/// `[batch, vocab]` (quantized models return last-token logits) or
/// `[batch, seq, vocab]` (take the final position).
fn argmax_last(logits: &Tensor) -> Result<u32, String> {
    let dims = logits.dims().len();
    let vocab_row = match dims {
        // [batch, vocab] → drop batch.
        2 => logits.squeeze(0).map_err(|e| e.to_string())?,
        // [batch, seq, vocab] → last seq position of batch 0.
        3 => {
            let seq = logits.dim(1).map_err(|e| e.to_string())?;
            logits
                .i((0, seq - 1))
                .map_err(|e| format!("slice last token: {e}"))?
        }
        n => return Err(format!("unexpected logits rank {n}")),
    };
    let idx = vocab_row
        .argmax(0)
        .map_err(|e| format!("argmax: {e}"))?;
    idx.to_scalar::<u32>()
        .map_err(|e| format!("argmax scalar: {e}"))
}
