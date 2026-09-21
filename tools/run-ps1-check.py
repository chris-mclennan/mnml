#!/usr/bin/env python3
"""tools/run-ps1-check.py — what can be checked about run.ps1 without pwsh.

`tools/run-ps1-check.ps1` is the real check: it runs the verbs against a
throwaway repo and a throwaway prefix, the way `tools/run-sh-check.sh`
does for run.sh. It needs PowerShell. This machine has none — there is
no `pwsh` on the author's Mac and installing one is not on the table —
so the ps1 check is written for the Windows guest and CANNOT have been
run here.

What is left is structure, and this says so honestly rather than
pretending to be a test run:

  1. Balance. Braces, parentheses and brackets, counted with strings,
     here-strings and comments excluded, so an unclosed `if {` or a
     stray `)` is caught. The single most likely way a hand-written
     PowerShell file is broken without anyone noticing.
  2. Quoting. Every '…' and "…" closes; every @' / @" here-string has
     its terminator at the start of a line.
  3. Windows PowerShell 5.1. The 7-only spellings that would parse on
     the author's pwsh and fail on a stock Windows box: `??`, `?:`,
     `&&` / `||`, `$IsWindows`, `-Parallel`, `Join-Path
     -AdditionalChildPath`.
  4. The verbs. Each documented verb has a function and a dispatch arm,
     and every function is reachable.
  5. The refusals, the build lines, the font destination and the
     dry-run plan phrases the ps1 check greps for — a rename that
     silently unhooked the Windows check would otherwise only show up
     on the VM.

Exit 0 when everything holds. `--verbose` lists each check.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PS1 = REPO / "run.ps1"
CHECK_PS1 = REPO / "tools" / "run-ps1-check.ps1"
RUN_SH = REPO / "run.sh"

VERBS = ["install", "install-font", "installed-status", "profile"]

results: list[tuple[bool, str, str]] = []


def check(ok: bool, label: str, detail: str = "") -> None:
    results.append((bool(ok), label, detail))


# ── a PowerShell-aware scanner ──────────────────────────────────────────
# Enough of a tokenizer to tell code from text: line comments, block
# comments, single- and double-quoted strings (with PowerShell's doubled
# quote as the escape, and the backtick escape inside double quotes) and
# here-strings, whose terminator must start a line.


class ScanError(Exception):
    def __init__(self, line: int, message: str) -> None:
        super().__init__(message)
        self.line = line
        self.message = message


def code_only(text: str) -> str:
    """The source with every comment and string literal blanked out.

    Newlines are kept so reported line numbers stay true.
    """
    out: list[str] = []
    i = 0
    n = len(text)
    line = 1

    def at_line_start(pos: int) -> bool:
        j = pos - 1
        while j >= 0 and text[j] in " \t":
            j -= 1
        return j < 0 or text[j] == "\n"

    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            out.append("\n")
            i += 1
            continue
        # <# block comment #>
        if ch == "<" and text.startswith("<#", i):
            end = text.find("#>", i + 2)
            if end < 0:
                raise ScanError(line, "unterminated <# block comment")
            chunk = text[i : end + 2]
            line += chunk.count("\n")
            out.append("\n" * chunk.count("\n"))
            i = end + 2
            continue
        # here-string: @' … '@ or @" … "@, terminator at a line start
        if ch == "@" and i + 1 < n and text[i + 1] in "'\"":
            q = text[i + 1]
            term = "\n" + q + "@"
            end = text.find(term, i + 2)
            if end < 0:
                raise ScanError(line, f"unterminated here-string @{q}")
            chunk = text[i : end + len(term)]
            line += chunk.count("\n")
            out.append("\n" * chunk.count("\n"))
            i = end + len(term)
            continue
        # # line comment — but not inside a variable like $#, and not a
        # `#` that follows a word character (PowerShell allows it in a
        # bare word, which this file never uses).
        if ch == "#":
            end = text.find("\n", i)
            if end < 0:
                end = n
            i = end
            continue
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                if text[j] == "\n":
                    raise ScanError(line, "single-quoted string crosses a newline")
                j += 1
            else:
                raise ScanError(line, "unterminated single-quoted string")
            out.append(" " * (j - i + 1))
            i = j + 1
            continue
        if ch == '"':
            j = i + 1
            depth = 0
            while j < n:
                c = text[j]
                if c == "`":
                    j += 2
                    continue
                if c == "$" and j + 1 < n and text[j + 1] == "(":
                    depth += 1
                    j += 2
                    continue
                if c == ")" and depth > 0:
                    depth -= 1
                    j += 1
                    continue
                if c == '"' and depth == 0:
                    if j + 1 < n and text[j + 1] == '"':
                        j += 2
                        continue
                    break
                if c == "\n":
                    line += 1
                    out.append("\n")
                j += 1
            else:
                raise ScanError(line, "unterminated double-quoted string")
            i = j + 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def balance(code: str) -> tuple[bool, str]:
    pairs = {")": "(", "]": "[", "}": "{"}
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                return False, f"line {line}: a stray '{ch}' with nothing open"
            top, opened = stack.pop()
            if top != pairs[ch]:
                return False, f"line {line}: '{ch}' closes a '{top}' opened on line {opened}"
    if stack:
        top, opened = stack[-1]
        return False, f"'{top}' opened on line {opened} is never closed"
    return True, ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    if not PS1.is_file():
        print(f"run-ps1-check: no {PS1}", file=sys.stderr)
        return 64
    text = PS1.read_text(encoding="utf-8")

    # ── 1 + 2. balance and quoting ──────────────────────────────────
    try:
        code = code_only(text)
        check(True, "quoting: every string, here-string and block comment closes")
    except ScanError as e:
        check(False, "quoting: every string, here-string and block comment closes", f"line {e.line}: {e.message}")
        code = ""

    if code:
        ok, why = balance(code)
        check(ok, "balance: braces, parens and brackets pair up", why)

    # ── 3. Windows PowerShell 5.1 ───────────────────────────────────
    # Checked against the code, not the prose: the doc comment names
    # 5.1 and may quote what it refuses to use.
    seven_only = [
        (r"\?\?", "the null-coalescing operator `??` (PowerShell 7 only)"),
        (r"\)\s*\?\s*[^\s]+\s*:\s", "the ternary `? :` (PowerShell 7 only)"),
        (r"&&|\|\|", "the `&&` / `||` pipeline chain (PowerShell 7 only)"),
        (r"\$IsWindows\b", "$IsWindows (undefined in Windows PowerShell 5.1)"),
        (r"-Parallel\b", "ForEach-Object -Parallel (PowerShell 7 only)"),
        (r"-AdditionalChildPath\b", "Join-Path -AdditionalChildPath (PowerShell 6+ only)"),
        (r"\$\{[A-Za-z_][A-Za-z0-9_]*:-", "a bash ${VAR:-default} default"),
    ]
    for pattern, what in seven_only:
        hits = [
            code[:m.start()].count("\n") + 1
            for m in re.finditer(pattern, code)
        ]
        check(not hits, f"5.1: no {what}", f"line(s) {hits}" if hits else "")

    # ── 4. the verbs ────────────────────────────────────────────────
    functions = set(re.findall(r"(?m)^function\s+([A-Za-z][\w-]*)", text))
    dispatch = set(re.findall(r"(?m)^\s*'([a-z-]+)'\s*\{", text))
    for verb in VERBS:
        check(verb in dispatch, f"verb: `{verb}` has a dispatch arm")
    check("help" in dispatch, "verb: `help` has a dispatch arm")
    check("default" in text and "exit 2" in text, "verb: an unknown verb exits 2")
    for fn in sorted(functions):
        uses = len(re.findall(rf"\b{re.escape(fn)}\b", text))
        check(uses >= 2, f"function: {fn} is called somewhere", "declared but never used")

    params = re.search(r"(?s)^param\((.*?)\n\)", text, re.M)
    declared = set(re.findall(r"\$(\w+)", params.group(1))) if params else set()
    for p in ["Verb", "Prefix", "DryRun", "Force", "AllowDirty"]:
        check(p in declared, f"param: -{p} is declared")

    # ── 5. the semantics run.sh has, spelled for Windows ────────────
    needed = [
        ("-AllowDirty", "the dirty-tree / Debug escape hatch is named"),
        ("MNML_OPTIMIZE", "a non-ReleaseSafe build is refused by name"),
        ("-Force", "a foreign mnml.exe is refused unless -Force"),
        ("mnml-zig ", "the --version probe looks for the mnml-zig banner"),
        ("stable profile", "the install verifies the -Dinstall-names banner"),
        ("-Dinstall-names=true", "the build uses the shipped names"),
        ("jira-integration", "the Jira integration is built by name"),
        ("bitbucket-integration", "the Bitbucket integration is built by name"),
        ("font-merge", "install-font merges rather than overwrites"),
        ("-Dfont-in=", "the merge names its input"),
        ("-Dfont-out=", "the merge names its output"),
        ("Microsoft", "the font goes to the per-user Windows font dir"),
        (r"CurrentVersion\Fonts", "the face is registered under HKCU"),
        ("Backups", "the old face is backed up first"),
        ("MNML_DATA_ROOT", "the manifests are written into the stable data root"),
        ("--install", "each integration writes its own manifest"),
        ("marketplace", "share/ (the Marketplace source) is mentioned"),
    ]
    for needle, label in needed:
        check(needle in text, f"semantics: {label}")

    # The plan phrases tools/run-ps1-check.ps1 greps for. A rename here
    # unhooks the Windows check silently, so it is checked from both
    # ends: the phrase is in run.ps1, and the ps1 check looks for it.
    plan_phrases = ["would copy", "would run", "would skip", "would back up", "would register"]
    for phrase in plan_phrases:
        check(phrase in text, f"plan: run.ps1 prints '{phrase}'")
    if CHECK_PS1.is_file():
        check_text = CHECK_PS1.read_text(encoding="utf-8")
        for phrase in plan_phrases:
            check(phrase in check_text, f"plan: tools/run-ps1-check.ps1 asserts '{phrase}'")
        try:
            code_only(check_text)
            check(True, "tools/run-ps1-check.ps1: every string and here-string closes")
        except ScanError as e:
            check(False, "tools/run-ps1-check.ps1: every string and here-string closes", f"line {e.line}: {e.message}")
        ok, why = balance(code_only(check_text)) if "ScanError" not in str(type(check_text)) else (True, "")
        check(ok, "tools/run-ps1-check.ps1: braces, parens and brackets pair up", why)
    else:
        check(False, "tools/run-ps1-check.ps1 exists")

    # Windows has no bash twin of the restart loop, and run.ps1 does not
    # claim one. The three INSTALL verbs are the ones that must exist on
    # both sides — if run.sh drops or renames one, run.ps1's claim to be
    # "the same semantics" is stale. `profile` is deliberately not in
    # that list: it is run.ps1-only, a thin wrapper over the binary's
    # own `mnml profile`, which bash users invoke directly.
    for verb in VERBS:
        if verb == "profile":
            continue
        sh_verb = verb.replace("-", "_")
        if RUN_SH.is_file():
            sh = RUN_SH.read_text(encoding="utf-8")
            has = (f"\n  {verb})" in sh) or (f"do_{sh_verb}" in sh)
            check(has, f"parity: run.sh has `{verb}` too")

    passed = sum(1 for ok, _, _ in results if ok)
    failed = len(results) - passed
    for ok, label, detail in results:
        if args.verbose or not ok:
            mark = "ok  " if ok else "FAIL"
            print(f"  {mark} {label}")
            if detail and not ok:
                print(f"       {detail}")
    print(f"run-ps1-check.py: {passed} passed, {failed} failed")
    print("  (structure only — pwsh is not installed on this machine, so")
    print("   tools/run-ps1-check.ps1 has NOT been run. docs/INSTALL-CHECKLIST.md")
    print("   step W-0 runs it on the Windows guest.)")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
