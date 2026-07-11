# [SEV-2] `:%s/…/…/g` uses literal-string matching — no regex support

## Reproduction

hello.txt:
```
line one
line two
```

Attempt 1 (Rust regex flavor):
```jsonl
{"cmd":"type","text":":%s/(one|two)/[$1]/g"}
{"cmd":"key","key":"enter"}
```
Bottom line: `:%s — no match for "(one|two)"`

Attempt 2 (`.` as any char):
```jsonl
{"cmd":"type","text":":%s/./X/g"}
{"cmd":"key","key":"enter"}
```
No change — no character in the file is a literal `.`.

Attempt 3 (vim capture flavor):
```jsonl
{"cmd":"type","text":":%s/^line \\(\\w*\\)/\\1_x/g"}
{"cmd":"key","key":"enter"}
```
No change; the literal find `^line \(\w*\)` isn't in the buffer.

Simple find (`:%s/line/LINE/g`) DOES work — it's just anything with a
regex meta-character that treats it as literal.

## Expected

Vim's default: `:s/foo/bar/g` uses regex. Meta-characters `^ $ . * \|`
(with `\|` for alternation, `\(...\)` for capture, `\1` etc for backref)
are honored, and PCRE-style `\v` "very magic" upgrades to modern regex.

## Actual

`src/app/ex_commands.rs:369-376` — `run_substitute` calls
`find_all_case_sensitive` (or `find_all_ci_ascii`), both of which are
byte-substring searches. No regex crate at the call site. The message
`no match for "(one|two)"` even echoes the raw pattern back with the
parens preserved — proof the input was never compiled as a regex.

## Source pointer

`src/app/ex_commands.rs:330-380` — the whole substitute path.

## Notes

Vim users type things like:
- `:%s/\s\+$//` (trim trailing whitespace) — mnml matches literal `\s\+$`
- `:%s/foo\(bar\|baz\)/qux/g` (alternation) — inert
- `:%s/^\d\+\./ROW/g` (leading number + dot) — inert
- `:g/^$/d` (delete blank lines via global) — untested, likely same shape

Even the classic "trim trailing whitespace" one-liner doesn't work. This
is a major "mnml doesn't understand vim" moment. Priority: swap in
`regex::Regex::new(&sub.find)` + `re.replace_all(scope, &sub.replace)`
with a case-insensitive builder path for the `/i` flag. Preserve the
literal fast-path if a compilation error occurs (`Err(_) ⇒ fall back to
find_all_case_sensitive`) so escape-free patterns keep working.
