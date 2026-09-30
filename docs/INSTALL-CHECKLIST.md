# Per-OS install checklist

What a human — or a hunter agent — walks through on a **clean machine**
to decide whether mnml installs and runs there. One section per OS, each
a numbered list, each step saying what a pass looks like so "it seemed
fine" is never the answer.

This is a *first-run* checklist, not the verification gate. The gate
(`docs/CONTRIBUTING.md` → *The gate*) proves the code is right on a
machine that already works; this proves the machine gets there at all —
the font, the terminal, the PATH, the first frame, the session that
comes back.

Two ways to run it:

- **From a checkout** — `run.sh install` / `run.ps1 install`. This is
  the path that exists today and the one the VM guests use.
- **From a release** — `brew` / the installer script / `winget`. Marked
  *(published)* below; skip those steps until a release is cut.

Record the result as `step N: pass` / `step N: FAIL — <what happened>`.
A FAIL stops the section: the steps after it assume the ones before
passed.

---

## macOS (Apple silicon or Intel)

Reference platform. Everything here is expected to pass; a failure is a
regression, not a discovery.

1. **Prerequisites.** A terminal that speaks truecolor — ghostty is the
   first-party one, iTerm2 and WezTerm work, Terminal.app is the thin
   one. [Zig 0.16.0](https://ziglang.org/download/) exactly if you are
   installing from a checkout.
   *Pass:* `zig version` prints `0.16.0`.

2. **A Nerd Font.** `brew install --cask font-symbols-only-nerd-font`,
   then point the terminal's font (ghostty: `font-family`) at a full
   Nerd-Font-patched mono such as `JetBrainsMono Nerd Font Mono`. The
   symbols-only face has no letters and is never the primary font.
   *Pass:* `echo -e "\uf07b \ue0b0 \uf09b"` shows a folder, a powerline
   arrow and a logo — not three boxes.

3. **Install mnml.** From a checkout:
   ```sh
   ./run.sh install --dry-run     # the plan; changes nothing
   ./run.sh install
   ```
   *(published)* or the Homebrew tap / the installer script — both in
   `README.md` → *Install*.
   *Pass:* `install` ends with ``installed. `~/.local/bin/mnml` is the
   stable profile; `./run.sh` here is the dev one.``, and
   `~/.local/bin/mnml --version` prints
   `mnml <version> (stable profile)`. If it says `note: ~/.local/bin
   is not on your PATH`, add it and open a new shell.

4. **The symbols font.** `./run.sh install-font`, then **fully quit and
   reopen the terminal** (ghostty: Cmd+Q, not just the window). For
   ghostty also add
   `font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols` to
   `~/.config/ghostty/config`.
   *Pass:* the verb prints `merged` or names the copy, and after the
   restart step 8's terminal pane paints a hollow block cursor rather
   than `▯`.

5. **First launch.** `cd` to a git checkout of anything and run `mnml`.
   *Pass:* the first-launch wizard opens, titled **First-launch setup**,
   with eight numbered sections — *Nerd Font*, *Keyboard*, *Input
   style*, *Claude Code + Codex*, *AI billing preference*, *AI
   ghost-text*, *VSCode `code` shim*, *Integrations*. Answer the Nerd Font row
   (boxes: yes/no), press `Enter`. It must not reopen on the next
   launch.

6. **The file tree and a file.** `Ctrl+P`, type a filename, `Enter`.
   *Pass:* the file opens in the editor pane, syntax-highlighted, the
   statusline names it, the tree highlights its row.

7. **Edit and save.** Type a character, `Ctrl+S` (standard) or `:w`
   (vim).
   *Pass:* the modified marker clears; the file on disk changed.

8. **A terminal pane.** `:term`.
   *Pass:* a shell prompt appears in a pane below. `ls` renders in
   colour. The pane's cursor is a hollow block when the pane is not
   focused. `exit` shows `[exited 0]`.

9. **The Jira pane against the fake.** From the checkout (the fake is a
   test binary, built by `zig build`, and **not** something `install`
   copies — it lives in `zig-out/bin/`):
   ```sh
   ./zig-out/bin/mnml-fake-jira --url-file /tmp/jira-url &
   # the integration's own config: writes <data root>/integrations/jira/config.zon
   # (creating the directory) and prints its path. Set .email = "fake@acme.com".
   ./zig-out/bin/mnml-jira --write-config
   JIRA_BASE_URL=@/tmp/jira-url JIRA_API_TOKEN=fake-token mnml
   ```
   Open the INTEGRATIONS section and click the Jira chip.
   *Pass:* a tab of tickets from project `ENG` loads — twelve of them
   across an epic, a sprint and a backlog. No network was touched.

10. **Quit and come back.** `:q`, then `mnml` again in the same
    directory.
    *Pass:* the layout, the open files and the cursor positions are
    where you left them. The terminal is back to normal — cursor
    visible, no alt screen, `Ctrl+C` interrupts.

11. **`installed-status`.** `./run.sh installed-status`.
    *Pass:* the installed version, this tree's HEAD, the data root, and
    every `link:` line pointing into the prefix — **not** into a
    `zig-out`.

---

## Ubuntu (ARM64 or x86_64)

1. **Prerequisites.**
   ```sh
   sudo apt update && sudo apt install -y git curl unzip fontconfig
   ```
   A terminal: ghostty is the first-party one (build or download it);
   GNOME Terminal, Konsole and Alacritty all work. Zig 0.16.0 for a
   checkout install.
   *Pass:* `zig version` prints `0.16.0`; the terminal shows 24-bit
   colour (`printf '\e[38;2;255;100;0mX\e[0m\n'` is orange, not red).

2. **A Nerd Font.**
   ```sh
   mkdir -p ~/.local/share/fonts/nerd-symbols && cd $_
   curl -fsSLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip
   unzip -o NerdFontsSymbolsOnly.zip && rm NerdFontsSymbolsOnly.zip
   fc-cache -f
   ```
   Then set the terminal's font (or its fallback list) to include it.
   *Pass:* `fc-list | grep -i "symbols nerd"` lists it, and
   `echo -e "\uf07b \ue0b0"` shows glyphs rather than boxes.

3. **Install mnml.** From a checkout, `./run.sh install`.
   *(published)* or the Homebrew tap / the installer script
   (`README.md` → *Install*), or the `.deb` on the release
   (`sudo dpkg -i mnml-*.deb`).
   *Pass:* as macOS step 3. The default prefix is `~/.local`, so
   `~/.local/bin` must be on `PATH` — on a stock Ubuntu it is, once a
   login shell has seen the directory exist.

4. **The symbols font.** `./run.sh install-font` — the Linux font
   directory is `~/.local/share/fonts` (or `$XDG_DATA_HOME/fonts`).
   Restart the terminal.
   *Pass:* as macOS step 4. If the `.deb` installed it under
   `/usr/share/mnml/fonts`, that is *not* a user font directory —
   `install-font` (or a copy into `~/.local/share/fonts` plus
   `fc-cache -f`) is still the step.

5. **First launch.** Same as macOS step 5 — the same eight wizard
   sections.

6. **The file tree and a file.** Same as macOS step 6.

7. **Edit and save.** Same as macOS step 7.

8. **A terminal pane.** `:term`.
   *Pass:* a `bash` prompt in a pane below, colour intact, `exit` shows
   `[exited 0]`. Resize the window with a shell running — the pane
   follows (`SIGWINCH`).

9. **The Jira pane against the fake.** Same as macOS step 9.

10. **Quit and come back.** Same as macOS step 10.

11. **`installed-status`.** Same as macOS step 11.

12. **The gate, optionally.** `tools/linux/run.sh` runs the whole
    verification sequence in a container; `docs/CONTRIBUTING.md` →
    *Running the gate on Linux* has the details. Out of scope for a
    first-run check, but it is the thing that turns "it started" into
    "it works".

---

## Windows 11 (ARM64 or x86_64)

The one where things are expected to break — the Windows backends were
written without a Windows machine in the loop (`docs/WINDOWS.md`). Treat
every step as a question, and record the answer whether it passes or
not.

> **W-0 — before anything else, if you are installing from a checkout.**
> ```powershell
> zig build -Doptimize=ReleaseSafe
> pwsh -NoProfile -File tools\run-ps1-check.ps1
> ```
> `tools/run-ps1-check.ps1` has never been executed — there is no
> PowerShell on the author's Mac, so only the structure check
> (`tools/run-ps1-check.py`) has run against `run.ps1`. This is the
> first real run of both the check and the script. A failure here is a
> bug in `run.ps1`, not in your machine.
> *Pass:* `run-ps1-check: N passed, 0 failed`.

1. **Prerequisites.**
   - **Windows Terminal.** Classic conhost needs Windows 10 1809+ for
     VT processing and mnml refuses an older one with
     `NoVirtualTerminal`. Windows 11 ships Windows Terminal; make sure
     it is the default (Settings → Privacy & security → For developers
     → Terminal).
   - **Git for Windows** (`winget install Git.Git`) — `run.ps1` asks
     `git` what commit it is installing.
   - **Zig 0.16.0** for a checkout install
     (`winget install zig.zig`, or the zip from ziglang.org; confirm
     the version, winget can lag).
   *Pass:* `zig version` prints `0.16.0`; `git --version` answers;
   `$PSVersionTable.PSVersion` is 5.1 or 7.x.

   > ARM64 note: the shipped Windows binary is `x86_64-pc-windows-gnu`
   > and runs under emulation on ARM64 Windows. A checkout build with a
   > native ARM64 Zig is **not** a target this repo builds or tests —
   > build for `x86_64-windows-gnu` and let the emulator run it, or
   > record what a native attempt does.

2. **A Nerd Font.** Windows Terminal has *no* font-fallback list, so the
   profile's font face itself must be a full Nerd-Font-patched mono.
   ```powershell
   winget install --id DEVCOM.JetBrainsMonoNerdFont
   ```
   (or download `NerdFontsSymbolsOnly.zip`, but that face has no letters
   and cannot be the profile font). Then Windows Terminal → Settings →
   your profile → Appearance → Font face → `JetBrainsMono NFM`.
   *Pass:* in a fresh Windows Terminal tab,
   `[char]0xf07b` and `[char]0xe0b0` render as a folder and a powerline
   arrow, not as boxes:
   ```powershell
   [Console]::OutputEncoding = [Text.Encoding]::UTF8
   Write-Host ([char]0xf07b + ' ' + [char]0xe0b0)
   ```

3. **Install mnml.** From a checkout:
   ```powershell
   .\run.ps1 install -DryRun     # the plan; changes nothing
   .\run.ps1 install
   ```
   *(published)* or the winget package / the `irm … | iex` installer
   line — both spelled out in `README.md` → *Install*.
   *Pass:* `install` ends with `installed.` and
   `%LOCALAPPDATA%\Programs\mnml\bin\mnml.exe --version` prints
   `mnml <version> (stable profile)`. It prints the exact line to
   add the directory to your user PATH if it is not there — run it, then
   **open a new terminal**.
   *Things to record:* did the dirty-tree / Debug / foreign-binary
   refusals behave? Did `-DryRun` name every copy? Did
   `mnml-jira.exe --install` succeed (it writes three manifests,
   `<data root>\integrations\jira_work.zon`, `jira_fix_versions.zon`
   and `jira_boards.zon`) or warn?

4. **The symbols font.**
   ```powershell
   .\run.ps1 install-font
   ```
   It writes `%LOCALAPPDATA%\Microsoft\Windows\Fonts\MnmlSymbols.ttf`
   and registers it under
   `HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` — per
   user, no elevation. Then **close every Windows Terminal window and
   start it again**: it reads the font list at launch, and a new tab is
   not enough.
   *Pass:* `Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' |
   Select-Object 'MnmlSymbols (TrueType)'` shows the path, and after the
   restart step 8's unfocused terminal pane paints a hollow block
   cursor rather than `▯`.
   *Things to record:* Windows Terminal still has no fallback list, so
   MnmlSymbols only fills mnml's own `U+F1B00–U+F20FF` block. Nerd Font
   icons still come from the profile's font face (step 2). If mnml's own
   marks resolve but the Nerd Font icons do not, step 2 is the one that
   failed.

5. **First launch.**
   ```powershell
   cd C:\some\git\checkout
   mnml .
   ```
   *Pass:* the alt screen, the file tree, and the **First-launch setup**
   wizard with its eight sections — *Nerd Font*, *Keyboard*, *Input
   style*, *Claude Code + Codex*, *AI billing preference*, *AI
   ghost-text*, *VSCode `code` shim*, *Integrations*. No stray escape text for a frame
   before it paints (if there is, `applyTerminalQuirks` in
   `src/tui/caps.zig` is where a `WT_SESSION` correction goes).
   Answer the Nerd Font row, press `Enter`; it must not reopen next
   launch.
   *Things to record:* the *Keyboard* section probes `Ctrl+→` /
   `Ctrl+←` / `Option/Alt+→` / `Option/Alt+←`. Windows Terminal does not speak the
   kitty keyboard protocol, so chords only CSI u can distinguish will
   not register — note which of the four the section ticks.

6. **Where does it keep its state?**
   ```powershell
   .\run.ps1 profile
   ```
   *Pass:* `data:` under `%USERPROFILE%\.config\mnml` (stable) or
   `mnml-dev` (dev), `ipc:` the literal `<workspace>/.mnml/…` pattern, and `marker:`
   under `%TEMP%`. These are the `data_root.zig` USERPROFILE rung and
   the `%TEMP%` marker — the two Windows path decisions nothing on a Mac
   can confirm.

7. **The file tree and a file.** `Ctrl+P`, type a filename, `Enter`.
   Then click a tree row with the mouse, and drag a split.
   *Pass:* the file opens highlighted; the click selects the row the
   pointer is on; the drag moves the split. Windows Terminal translates
   the mouse to SGR reports; classic conhost delivers native records —
   both paths exist, only one will be exercised, so say which terminal
   you were in.

8. **A terminal pane (ConPTY).** This is the largest untested surface;
   `docs/WINDOWS.md` → *ConPTY* has the full list. The short version:
   ```
   :term                       cmd.exe prompt; dir, cls, color 0a, exit
   :term pwsh                  Get-ChildItem colours come through
   :term ping -n 3 127.0.0.1   output arrives as produced, then the exit
   :term cmd /c exit 3         shows [exited 3]
   ```
   Resize the pane with `pwsh` running; start
   `:term dir /s C:\Windows\System32` and close the pane mid-stream.
   *Pass:* every prompt renders, output streams rather than arriving in
   one lump, `$Host.UI.RawUI.WindowSize` follows a resize, and neither
   the close nor the UI hangs. A hang at the close is the
   `ClosePseudoConsole` question — record it precisely.

9. **The Jira pane against the fake.** The fake is a test binary that
   `zig build` puts in `zig-out\bin` and `install` does **not** copy, so
   this step runs from the checkout:
   ```powershell
   Start-Process .\zig-out\bin\mnml-fake-jira.exe -ArgumentList '--url-file',"$env:TEMP\jira-url"
   $env:JIRA_BASE_URL = "@$env:TEMP\jira-url"
   $env:JIRA_API_TOKEN = 'fake-token'
   # the integration's config, with .email = "fake@acme.com":
   .\zig-out\bin\mnml-jira.exe --write-config
   mnml .
   ```
   Open the INTEGRATIONS section and click the Jira chip.
   *Pass:* a tab of `ENG` tickets loads. Nothing left the loopback.
   *Things to record:* the integration is launched over a mount socket
   (`src/bridge/host.zig`, a Unix domain socket), and that has never
   bound on Windows (`docs/WINDOWS.md` → *Bridge mounts*). Say whether
   the pane painted, or what the chip said instead.

10. **Quit and come back.** `:q`, then `mnml .` again.
    *Pass:* the layout, the open files and the cursor positions come
    back. The console is back to normal: cursor visible, no alt screen,
    typing echoes, `Ctrl+C` interrupts.

11. **Redirected stdin, and a refused stdout.**
    ```powershell
    echo hi | mnml .          # must still take keys (it opens CONIN$)
    mnml . > out.txt          # must refuse: "stdout is not a terminal"
    ```
    *Pass:* exactly that.

12. **`installed-status`.** `.\run.ps1 installed-status`.
    *Pass:* the installed version, this tree's HEAD, the data root, and
    a `copy:` line per integration reading `= <prefix path>` rather than
    `DIFFERS`.

13. **Unit tests, if this is a dev guest.**
    ```powershell
    zig build test
    ```
    *Pass:* green, with the POSIX-only tests reporting SKIP.
    `docs/WINDOWS.md` → *Build + unit tests* lists exactly which skip.

---

## The UTM guests

The routine these checklists are written for: a long-lived guest per OS,
installed once, with a pristine snapshot to come back to so the
first-run experience can be checked again and again without reinstalling
the OS.

1. **Install the OS, nothing else.** Windows 11 Pro ARM (unactivated is
   fine — it only costs personalisation), Ubuntu ARM, or macOS.

2. **Snapshot it immediately**, before the first login customisation,
   named `pristine-<os>-<date>`. This is the one that never gets
   written to.

3. **Clone the pristine snapshot** for each pass — do not run the
   checklist on the snapshot itself. UTM: right-click the VM → Clone,
   or take a snapshot and work forward from it.

4. **Get the repo in.** A shared folder (UTM's SPICE/virtiofs mount) or
   a `git clone` over the guest's own network. A clone is the honest
   one: it proves nothing was carried in from the host by accident.

5. **Walk the section for that OS**, recording `pass` / `FAIL — …` per
   numbered step.

6. **Throw the clone away** and start from the pristine snapshot again
   for the next pass. Anything worth keeping is a note in the run
   record, not state in the guest.

7. **When the OS itself changes** — a Windows feature update, a new
   Ubuntu LTS — retake the pristine snapshot and keep the old one until
   a pass has run on the new one.

Nothing in these checklists depends on a real account, a real tracker or
a real repository: the Jira step runs against `mnml-fake-jira` on the
loopback, and every other step runs against a git checkout of anything.
Keep it that way — a guest that needs a credential to be checked is a
guest that stops being checked.

---

## Where the gaps are recorded

- `docs/WINDOWS.md` — what is implemented on Windows, what has been
  proven and how, and the list of known gaps. Every "things to record"
  above maps to an entry there.
- `docs/CONTRIBUTING.md` → *Daily driver + development on one machine* —
  what `install` / `install-font` / `installed-status` do and why they
  are separate verbs.
- `docs/RELEASE.md` — what a release carries, and which of these steps
  the published path replaces.
