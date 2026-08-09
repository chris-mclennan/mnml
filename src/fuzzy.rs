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
        {
            let i = found?;
            matched.push(i)
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
    // R6 R2 vscode-keyboard SEV-2 F2 2026-08-09 — exact-phrase
    // substring boost. When the user's original needle (before
    // separator stripping) appears as a case-insensitive substring
    // of the haystack AT A WORD BOUNDARY, add a flat +50 so it
    // outranks a shorter fuzzy match that just happens to share a
    // prefix bucket. Motivating case: palette search "hover-help"
    // ranked view.help above view.toggle_hover_help (whose title
    // literally contains "hover-help"). The word-boundary gate
    // preserves the existing boundary_bonus behavior — a mid-word
    // contiguous match doesn't get the boost.
    let needle_trim = needle.trim();
    if !needle_trim.is_empty() && needle_trim.len() <= haystack.len() {
        let needle_lower = needle_trim.to_lowercase();
        let haystack_lower = haystack.to_lowercase();
        // Substring must start at position 0 OR after a word-boundary
        // character in the ORIGINAL haystack (before lowercasing).
        let boundary_chars: &[char] = &['/', '_', '-', '.', ' ', ':'];
        let mut search_from = 0usize;
        while let Some(pos) = haystack_lower[search_from..].find(&needle_lower) {
            let abs_pos = search_from + pos;
            let at_boundary = abs_pos == 0
                || haystack[..abs_pos]
                    .chars()
                    .last()
                    .is_some_and(|c| boundary_chars.contains(&c));
            if at_boundary {
                score += 50;
                // R7 api-workflow SEV-2 F3 2026-08-09 — exact-token
                // boost. When the boundary-substring hit is also a
                // COMPLETE token in the haystack (followed by
                // end-of-string OR a non-identifier separator like
                // `.`, ` `, `:`, `-`, `/`), add a further +150 so a
                // full-id needle outranks a shorter fuzzy prefix hit.
                // Motivating case: query `integrations.refresh` was
                // firing `integrations.refresh_binary_cache` — both
                // haystacks satisfied the +50 (needle appears at a
                // boundary in both), and `_` counts as an identifier
                // continuation so it isn't a token terminator here.
                // The palette label format is
                // `"{group}  ·  {title}  ·  {id}"`, so the exact-id
                // needle lands at end-of-string and picks up the
                // full +200 (50+150).
                let end_abs = abs_pos + needle_lower.len();
                let terminates = end_abs == haystack.len()
                    || haystack[end_abs..]
                        .chars()
                        .next()
                        .is_some_and(|c| matches!(c, '.' | ' ' | ':' | '-' | '/'));
                if terminates {
                    score += 150;
                }
                break;
            }
            search_from = abs_pos + 1;
        }
    }
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

    #[test]
    fn exact_phrase_boost_at_word_boundary() {
        // R6 R2 vscode-keyboard F2. Needle "abc" appears as a
        // word-boundary substring in "prefix abc suffix" and gets
        // the boost. Same needle appears contiguously in
        // "xxxxxxxabc" but only mid-word — no boost. Both match
        // greedy-subsequence-wise; the boost is the ONLY differentiator
        // (haystack length + scatter identical enough).
        let a = fuzzy_match("abc", "some abc thing").unwrap().0;
        let b = fuzzy_match("abc", "somexabcthing").unwrap().0;
        assert!(
            a > b,
            "word-boundary substring must outrank mid-word substring: {a} vs {b}"
        );
    }

    #[test]
    fn exact_id_beats_prefix_of_longer_id() {
        // R7 api-workflow F3 2026-08-09. Palette label format:
        // `"{group}  ·  {title}  ·  {id}"`. Typing an EXACT id
        // (`integrations.refresh`) must outrank a fuzzy hit on a
        // longer id that shares the same prefix
        // (`integrations.refresh_binary_cache`). Both haystacks
        // contain the needle at a word boundary — the +50 boost
        // fires for both — the +150 exact-token gate is the
        // disambiguator (needle ends the string in the winner,
        // continues into `_` in the loser).
        let winner = fuzzy_match(
            "integrations.refresh",
            "integrations  ·  Integrations: re-scan manifests in .mnml/integrations/  ·  integrations.refresh",
        ).unwrap().0;
        let loser = fuzzy_match(
            "integrations.refresh",
            "integrations  ·  Integrations: refresh installed-binary detection  ·  integrations.refresh_binary_cache",
        ).unwrap().0;
        assert!(
            winner > loser,
            "exact-id match must outrank prefix-hit on longer id: {winner} vs {loser}"
        );
    }

    #[test]
    fn exact_phrase_boost_gated_on_word_boundary() {
        // "fk" appearing mid-word ("xafkx") should NOT get the
        // substring boost — the boundary_bonus test relies on
        // "foo_key" (word-start) beating "xafkx" (mid-word) even
        // though both contain the needle contiguously.
        let word_start = fuzzy_match("fk", "foo_key").unwrap().0;
        let mid_word = fuzzy_match("fk", "xafkx").unwrap().0;
        assert!(
            word_start > mid_word,
            "boundary_bonus test invariant must hold: {word_start} vs {mid_word}"
        );
    }
}
