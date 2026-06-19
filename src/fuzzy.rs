//! A small fuzzy subsequence matcher — good enough for the file picker and the
//! command palette. (If it ever needs to be smarter, swap in `nucleo`.)

/// Match `haystack` against `needle` (case-insensitive subsequence). Returns the
/// score (higher is better) and the matched char indices into `haystack` (for
/// highlighting), or `None` if `needle` isn't a subsequence. An empty `needle`
/// matches everything with score 0.
pub fn fuzzy_match(needle: &str, haystack: &str) -> Option<(i64, Vec<usize>)> {
    // 2026-06-19 — keyboard hunt SEV-2: a query like
    // `send_streaming` returned no matches against
    // `HTTP: send active request as a Server-Sent Events stream`
    // because the needle's `_` didn't appear in the haystack.
    // Normalize the needle by treating `_`, `-`, `.` as word
    // separators that match any whitespace OR the same char in
    // the haystack — but the simplest fix is to strip them: a
    // user typing the dotted id (`http.send_streaming`) reads as
    // `httpsendstreaming` against the haystack, which fuzzy-matches
    // both ids and titles. Common picker semantics.
    let needle_normalized: String = needle
        .chars()
        .filter(|c| !matches!(c, '_' | '-' | '.'))
        .collect();
    let nl: Vec<char> = needle_normalized
        .chars()
        .flat_map(|c| c.to_lowercase())
        .collect();
    if nl.is_empty() {
        return Some((0, Vec::new()));
    }
    let hchars: Vec<char> = haystack.chars().collect();
    let hlower: Vec<char> = haystack.chars().flat_map(|c| c.to_lowercase()).collect();
    // (lowercase folding can change length in pathological cases; clamp index use.)
    let n = hchars.len().min(hlower.len());

    // Greedy forward subsequence — fine for picker-sized inputs.
    let mut matched: Vec<usize> = Vec::with_capacity(nl.len());
    let mut hi = 0usize;
    for &nc in &nl {
        let mut found = None;
        while hi < n {
            if hlower[hi] == nc {
                found = Some(hi);
                hi += 1;
                break;
            }
            hi += 1;
        }
        match found {
            Some(i) => matched.push(i),
            None => return None,
        }
    }

    // Score: reward contiguity, word-boundary starts, camelHumps; penalize gaps,
    // long haystacks, and a late first match.
    let mut score: i64 = 0;
    let mut prev: Option<usize> = None;
    for &i in &matched {
        match prev {
            Some(p) if i == p + 1 => score += 15,
            Some(p) => score -= (i - p - 1) as i64,
            None => score += 5,
        }
        let boundary =
            i == 0 || matches!(hchars.get(i - 1), Some('/' | '_' | '-' | '.' | ' ' | ':'));
        if boundary {
            score += 12;
        }
        if hchars[i].is_uppercase() && i > 0 && hchars[i - 1].is_lowercase() {
            score += 8;
        }
        prev = Some(i);
    }
    score -= (hchars.len() as i64) / 8;
    score -= (matched.first().copied().unwrap_or(0) as i64) / 2;
    Some((score, matched))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_needle_matches() {
        assert!(fuzzy_match("", "anything").is_some());
    }
    #[test]
    fn non_subsequence_fails() {
        assert!(fuzzy_match("xyz", "abc").is_none());
    }
    #[test]
    fn case_insensitive_subsequence() {
        let (_, idx) = fuzzy_match("ab", "AxBy").unwrap();
        assert_eq!(idx, vec![0, 2]);
    }
    #[test]
    fn contiguous_beats_scattered() {
        let contiguous = fuzzy_match("main", "src/main.rs").unwrap().0;
        let scattered = fuzzy_match("main", "m_a_i_n.txt").unwrap().0;
        assert!(contiguous > scattered, "{contiguous} vs {scattered}");
    }
    #[test]
    fn boundary_bonus() {
        // "fk" should prefer "foo_key" (both at word starts) over "afkx" (mid-word)
        let a = fuzzy_match("fk", "foo_key").unwrap().0;
        let b = fuzzy_match("fk", "xafkx").unwrap().0;
        assert!(a > b, "{a} vs {b}");
    }
}
