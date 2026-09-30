<#
.SYNOPSIS
  run.sh's daily-driver verbs, for Windows.

.DESCRIPTION
  `run.sh` is bash, so on Windows the install has been by hand since the
  Windows backends landed (docs/WINDOWS.md, "Known gaps"). This is the
  twin of the four verbs that matter for living in mnml rather than
  developing it — install, install-font, installed-status, profile —
  with the same semantics, the same refusals and the same dry-run plan.

  It is NOT a twin of the whole script. The restart loop, `shot`,
  `headless`, `clean`, `menu` and the IPC verbs stay bash-only: they
  drive a running instance, and driving one is a separate pass.

  Three things differ from run.sh, because Windows differs:

    * `<data root>\bin\<name>.exe` is a COPY, not a symlink. A symlink
      needs Developer Mode or an elevated shell; `linkBeside` in
      src/config/seed.zig already falls back to copying for the same
      reason, so both halves agree.
    * `install-font` writes the per-user font directory
      (%LOCALAPPDATA%\Microsoft\Windows\Fonts) AND registers the face
      under HKCU. A file alone is not an installed font on Windows.
    * The prefix defaults to %LOCALAPPDATA%\Programs\mnml, not
      ~/.local — there is no ~/.local convention here, and Programs\ is
      where a per-user install belongs.

  Windows PowerShell 5.1 and PowerShell 7 both run this; no modules
  beyond what ships with the OS.

.PARAMETER Verb
  install | install-font | installed-status | profile | help

.PARAMETER Prefix
  Where `install` puts things. Default: $env:MNML_PREFIX, else
  $env:PREFIX, else %LOCALAPPDATA%\Programs\mnml.

.PARAMETER DryRun
  Print every step and change nothing. `install` and `install-font`.

.PARAMETER Force
  `install`: replace a PREFIX\bin\mnml.exe that does not answer
  `--version` as an mnml-zig.

.PARAMETER AllowDirty
  `install`: install from a dirty tree, or from a non-ReleaseSafe
  MNML_OPTIMIZE.

.EXAMPLE
  .\run.ps1 install -DryRun
.EXAMPLE
  .\run.ps1 install
.EXAMPLE
  .\run.ps1 install-font
.EXAMPLE
  .\run.ps1 installed-status

.NOTES
  Environment, the same names run.sh honours:
    MNML_ZIG        the zig to build with (default: `zig` on PATH)
    MNML_OPTIMIZE   the optimize mode (default ReleaseSafe; anything
                    else is refused without -AllowDirty)
    MNML_PREFIX / PREFIX   where `install` puts things
    MNML_PROFILE    which mnml `profile` reports on (default dev, the
                    way a launch from this tree runs)
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Verb = 'help',
    [string]$Prefix,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$AllowDirty
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero native exit code into a terminating
# error while $ErrorActionPreference is Stop. Every native call here
# reads $LASTEXITCODE itself — a `git status` in a non-repo and a
# `--version` probe of a foreign binary are both expected answers, not
# failures — so turn that off where the variable exists.
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# ── the tree, the tools, the names ──────────────────────────────────────

$Repo = $PSScriptRoot
$Zig = if ($env:MNML_ZIG) { $env:MNML_ZIG } else { 'zig' }
$Optimize = if ($env:MNML_OPTIMIZE) { $env:MNML_OPTIMIZE } else { 'ReleaseSafe' }

# 5.1 has no $IsWindows. $env:OS is set on every Windows since NT.
$OnWindows = ($env:OS -eq 'Windows_NT')
# The suffix the build puts on an executable. Derived rather than
# hard-coded so tools/run-ps1-check.ps1 can exercise the copy / manifest
# / plan logic on a non-Windows pwsh against a non-Windows build.
$ExeExt = if ($OnWindows) { '.exe' } else { '' }

if (-not $Prefix) {
    if ($env:MNML_PREFIX) { $Prefix = $env:MNML_PREFIX }
    elseif ($env:PREFIX) { $Prefix = $env:PREFIX }
    elseif ($env:LOCALAPPDATA) { $Prefix = Join-Path $env:LOCALAPPDATA 'Programs\mnml' }
    else { $Prefix = Join-Path $HOME '.local' }
}

function Log($Message) { Write-Host "[run.ps1] $Message" }
function Plan($Message) { Write-Host "  $Message" }

# Join three or more segments: Windows PowerShell 5.1's Join-Path takes
# exactly two.
function JoinPath {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Parts)
    $p = $Parts[0]
    for ($i = 1; $i -lt $Parts.Count; $i++) { $p = Join-Path $p $Parts[$i] }
    return $p
}

function BinPath($Name) { JoinPath $Repo 'zig-out' 'bin' ($Name + $ExeExt) }

# ── what an install carries ─────────────────────────────────────────────
# The host as `mnml.exe`, plus one binary per folder under integrations/
# named by its manifest's `.binary` line — the same rule run.sh's
# `shipped_integrations` applies, reading the same files. The test fakes
# (mnml-fake-*) are not integrations and never install; the SDK sample is
# a fixture, so its binary ships (the SDK docs run it) but its manifest
# is not registered — a "Sample" chip is not something an install should
# put on your rail.
function Get-ShippedIntegration {
    $found = @()
    $dir = Join-Path $Repo 'integrations'
    if (-not (Test-Path -LiteralPath $dir)) { return , $found }
    foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory | Sort-Object Name)) {
        $manifest = Join-Path $d.FullName 'manifest.zon'
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $text = Get-Content -LiteralPath $manifest -Raw
        $bin = [regex]::Match($text, '(?m)^\s*\.binary\s*=\s*"([^"]*)"').Groups[1].Value
        if (-not $bin) { continue }
        $cat = [regex]::Match($text, '(?m)^\s*\.category\s*=\s*"([^"]*)"').Groups[1].Value
        if (-not $cat) { $cat = 'integration' }
        $found += [pscustomobject]@{ Id = $d.Name; Binary = $bin; Category = $cat }
    }
    return , $found
}

# Run a native program and hand back every stream as one string, with
# the exit code. `& exe 2>$null` is not reliable across 5.1 and 7 for
# native commands; this is.
function Invoke-Capture {
    param([string]$Exe, [string[]]$Arguments = @())
    $out = ''
    $code = 127
    try {
        $out = (& $Exe @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    catch { $out = "$_"; $code = 127 }
    return [pscustomobject]@{ Text = $out.Trim(); Code = $code }
}

# Run zig in the repo, echoing its output to the HOST rather than into
# the caller's pipeline: a function's uncaptured native output is part
# of what that function returns, and every verb here returns an exit
# code. Hands back zig's.
function Invoke-Zig {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $code = 127
    Push-Location $Repo
    try {
        & $Zig @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        $code = $LASTEXITCODE
    }
    catch { Log "$Zig could not run: $_" }
    finally { Pop-Location }
    return $code
}

# Is `$Path` an mnml-zig? `--version` says so; the Rust mnml and
# anything else on the machine do not.
function Test-IsOurs($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $r = Invoke-Capture -Exe $Path -Arguments @('--version')
    return ($r.Text -match '(?m)^mnml(-zig)? .*\((stable|dev) profile\)')
}

# Set an environment variable, or REMOVE it when the value is $null —
# `$env:X = $null` leaves an empty string behind, and "set but empty" is
# a different thing from "unset" to some readers.
function Set-Env {
    param([string]$Name, $Value)
    if ($null -eq $Value) { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
    else { Set-Item "Env:$Name" $Value }
}

# The installed mnml's data root for a profile — asked of the binary
# itself, so data_root.zig's ladder (%USERPROFILE% rung included) is
# never duplicated here. `$Profile` is an automatic variable in
# PowerShell, hence the name.
function Get-DataRoot {
    param([string]$Path, [string]$ProfileName = 'stable')
    $saved = $env:MNML_PROFILE
    $env:MNML_PROFILE = $ProfileName
    try { $r = Invoke-Capture -Exe $Path -Arguments @('profile') }
    finally { Set-Env 'MNML_PROFILE' $saved }
    $m = [regex]::Match($r.Text, '(?m)^data:\s*(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Copy `$Src` over `$Dst`. Staged beside, then moved into place: on
# Windows a RUNNING .exe cannot be overwritten, but it can be renamed
# out of the way, so the copy you are using right now keeps running and
# the new one lands anyway.
function Install-OneFile {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Src)) {
        Log "install: $Src is missing — did the build run?"
        return $false
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dst) | Out-Null
    $staged = "$Dst.new"
    Copy-Item -LiteralPath $Src -Destination $staged -Force
    if (Test-Path -LiteralPath $Dst) {
        $old = "$Dst.old"
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        try { Move-Item -LiteralPath $Dst -Destination $old -Force } catch { }
    }
    Move-Item -LiteralPath $staged -Destination $Dst -Force
    Remove-Item -LiteralPath "$Dst.old" -Force -ErrorAction SilentlyContinue
    Plan "$Src → $Dst"
    return $true
}

function Get-GitHead {
    $r = Invoke-Capture -Exe 'git' -Arguments @('-C', $Repo, 'rev-parse', '--short', 'HEAD')
    if ($r.Text -and $r.Code -eq 0) { return $r.Text } else { return 'unknown' }
}

function Get-GitDirty {
    $r = Invoke-Capture -Exe 'git' -Arguments @('-C', $Repo, 'status', '--porcelain')
    if ($r.Code -ne 0) { return @() }
    return @($r.Text -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 5)
}

# ── install ─────────────────────────────────────────────────────────────

function Invoke-Install {
    $say = if ($DryRun) { 'install --dry-run' } else { 'install' }

    # 1. A tree you can name. An install you cannot trace back to a
    #    commit is what makes "which mnml is this?" unanswerable.
    $head = Get-GitHead
    $dirty = Get-GitDirty
    if ($dirty.Count -gt 0 -and -not $AllowDirty) {
        Log "${say}: the tree is dirty — commit, stash, or pass -AllowDirty"
        foreach ($line in $dirty) { Write-Host "  $line" }
        return 1
    }
    # 2. ReleaseSafe. A Debug mnml is slow enough to be miserable all day.
    if ($Optimize -ne 'ReleaseSafe' -and -not $AllowDirty) {
        Log "${say}: MNML_OPTIMIZE=$Optimize — install a ReleaseSafe build, or pass -AllowDirty"
        return 1
    }
    # 3. Not over something that is not ours.
    $dest = JoinPath $Prefix 'bin' ('mnml' + $ExeExt)
    if ((Test-Path -LiteralPath $dest) -and -not (Test-IsOurs $dest) -and -not $Force) {
        Log "${say}: $dest exists and is not an mnml-zig (``$dest --version`` does not say so) — pass -Force to replace it"
        return 1
    }

    $built = BinPath 'mnml-zig'
    if ($DryRun) {
        Log "would build: $Zig build -Doptimize=ReleaseSafe -Dinstall-names=true"
        Log "would build: $Zig build -Doptimize=ReleaseSafe -Dinstall-names=true jira-integration bitbucket-integration"
    }
    else {
        Log 'building ReleaseSafe with the shipped names (-Dinstall-names)…'
        if ((Invoke-Zig 'build' '-Doptimize=ReleaseSafe' '-Dinstall-names=true') -ne 0) {
            Log "${say}: the build failed"; return 1
        }
        # The default install step already depends on both, but naming
        # them keeps the install honest if that ever changes: an
        # integration that silently stopped building would otherwise be
        # copied from a stale zig-out.
        if ((Invoke-Zig 'build' '-Doptimize=ReleaseSafe' '-Dinstall-names=true' 'jira-integration' 'bitbucket-integration') -ne 0) {
            Log "${say}: the integration build failed"; return 1
        }
        # 4. Verified: it runs, it says what it is, and it says it
        #    defaults to the stable profile — the point of -Dinstall-names.
        $ver = (Invoke-Capture -Exe $built -Arguments @('--version')).Text
        if ($ver -notmatch '(?m)^mnml(-zig)? .*\(stable profile\)') {
            Log "${say}: $built --version said ""$ver"" — refusing to install an unverified build"
            return 1
        }
        Log "verified: $ver"
    }

    # 5. The files.
    $dirtyNote = if ($dirty.Count -gt 0) { ', dirty' } else { '' }
    Log "${say}: prefix $Prefix (HEAD $head$dirtyNote)"
    $shipped = Get-ShippedIntegration
    if ($DryRun) {
        Plan "would copy   $built → $dest"
        foreach ($i in $shipped) {
            Plan ("would copy   " + (BinPath $i.Binary) + " → " + (JoinPath $Prefix 'bin' ($i.Binary + $ExeExt)))
        }
    }
    else {
        if (-not (Install-OneFile -Src $built -Dst $dest)) { return 1 }
        foreach ($i in $shipped) {
            $src = BinPath $i.Binary
            $dst = JoinPath $Prefix 'bin' ($i.Binary + $ExeExt)
            if (-not (Install-OneFile -Src $src -Dst $dst)) { return 1 }
        }
    }

    # share\: MnmlSymbols.ttf, the curated Lua script set, and
    # marketplace.zon — the INTEGRATIONS section's Marketplace default
    # source, which an installed mnml probes for at
    # <exe dir>\..\share\mnml\marketplace.zon. Without it the tab is
    # empty.
    $shareSrc = JoinPath $Repo 'zig-out' 'share'
    $shareDst = Join-Path $Prefix 'share'
    if (Test-Path -LiteralPath $shareSrc) {
        if ($DryRun) {
            foreach ($f in (Get-ChildItem -LiteralPath $shareSrc -Recurse -File)) {
                $rel = $f.FullName.Substring($shareSrc.Length).TrimStart('\', '/')
                Plan "would copy   zig-out\share\$rel → $(Join-Path $shareDst $rel)"
            }
        }
        else {
            New-Item -ItemType Directory -Force -Path $shareDst | Out-Null
            Copy-Item -Path (Join-Path $shareSrc '*') -Destination $shareDst -Recurse -Force
            Log "copied zig-out\share → $shareDst"
        }
    }
    elseif ($DryRun) {
        Plan '(no zig-out\share yet — the build makes it)'
    }

    # 6. The manifests, in the STABLE profile's data root, pointing at
    #    the binaries just installed. Each integration writes its own
    #    (`<binary> --install`), so the manifest and the binary cannot
    #    drift; <root>\bin\<name>.exe is then re-COPIED from PREFIX\bin
    #    — the Windows form of run.sh's relink, and the bug the verb
    #    exists to fix: a rebuild here used to move the integrations
    #    under the running installed mnml.
    $root = ''
    if ($DryRun) {
        if (Test-Path -LiteralPath $built) { $root = Get-DataRoot -Path $built -ProfileName 'stable' }
        if (-not $root) { $root = '(the stable data root)' }
    }
    else {
        $root = Get-DataRoot -Path $dest -ProfileName 'stable'
        if (-not $root) { Log "${say}: could not ask $dest for its data root"; return 1 }
    }
    Log "${say}: manifests → $root\integrations, copies → $root\bin"
    foreach ($i in $shipped) {
        $exe = JoinPath $Prefix 'bin' ($i.Binary + $ExeExt)
        $copy = JoinPath $root 'bin' ($i.Binary + $ExeExt)
        if ($i.Category -eq 'sample') {
            if ($DryRun) { Plan ("would skip   " + $i.Binary + " --install (a fixture, not a chip on your rail)") }
            continue
        }
        if ($DryRun) {
            Plan "would run    MNML_PROFILE=stable MNML_DATA_ROOT=$root $exe --install"
            Plan "would copy   $exe → $copy"
            continue
        }
        $savedProfile = $env:MNML_PROFILE
        $savedRoot = $env:MNML_DATA_ROOT
        $env:MNML_PROFILE = 'stable'
        $env:MNML_DATA_ROOT = $root
        try {
            $r = Invoke-Capture -Exe $exe -Arguments @('--install')
            if ($r.Code -ne 0) {
                Log ("  warning: " + $i.Binary + " --install failed (the binary is installed; its manifest is not)")
            }
        }
        finally {
            Set-Env 'MNML_PROFILE' $savedProfile
            Set-Env 'MNML_DATA_ROOT' $savedRoot
        }
        # A copy, not a symlink: a symlink needs Developer Mode or an
        # elevated shell, and mnml resolves either the same way.
        if (-not (Install-OneFile -Src $exe -Dst $copy)) { return 1 }
    }

    # 7. The font. mnml paints its own block (the tree connectors, the
    #    terminal mark, the unfocused pane's hollow cursor) out of
    #    MnmlSymbols, and a terminal only finds that file where Windows
    #    keeps fonts. That is a change outside PREFIX and outside the
    #    data root, so `install` only ever PRINTS it.
    Write-Host ''
    Write-Host '  the symbols font is installed separately — mnml''s own glyphs (the tree'
    Write-Host '  connectors, the terminal mark, the unfocused pane''s hollow cursor) need it'
    Write-Host '  in your per-user font directory and registered under HKCU, which this verb'
    Write-Host '  does not write to:'
    Write-Host ''
    Write-Host '      .\run.ps1 install-font'
    Write-Host ''
    Write-Host '  install-font MERGES with an already-installed MnmlSymbols rather than'
    Write-Host '  replacing it, so a face carrying glyphs this build has no source for keeps'
    Write-Host '  them. Windows Terminal reads the font list at launch — restart it after.'
    Write-Host ''

    if ($DryRun) {
        Log "${say}: nothing was changed"
        return 0
    }

    Log "installed. ``$dest`` is the stable profile; ``zig build`` here is the dev one."
    $binDir = Join-Path $Prefix 'bin'
    $userPath = ''
    if ($OnWindows) { $userPath = [Environment]::GetEnvironmentVariable('Path', 'User') }
    $onPath = $false
    if ($userPath) {
        $onPath = @($userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $binDir.TrimEnd('\')) }).Count -gt 0
    }
    if (-not $onPath) {
        Log "note: $binDir is not on your user PATH. To add it (new shells pick it up):"
        Write-Host "      [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';$binDir', 'User')"
    }
    return 0
}

# ── install-font ────────────────────────────────────────────────────────
# The one verb that writes outside the repo and outside PREFIX, which is
# why it is a verb of its own and not a step of `install`.
#
# It MERGES. An already-installed MnmlSymbols may carry codepoints this
# repo has no source for — the Rust-era integration chips, spinners and
# marks around U+F1C03…F1F00 — and copying over the file would take them
# away with no way back. `zig build font-merge` keeps every codepoint
# the installed file maps, replaces the ones this build bakes, adds the
# new ones, and drops an outline no cmap points at. The old file is
# copied to %USERPROFILE%\Backups\mnml-zig\fonts\ first, timestamped.
#
# A file is not an installed font on Windows: the face also has to be
# named under HKCU\…\Fonts. Per-user, so no elevation — the same shape
# first_launch_install.zig uses for the Nerd Font.

$FontRegKey = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$FontRegName = 'MnmlSymbols (TrueType)'

function Get-UserFontDir {
    if ($env:LOCALAPPDATA) { return (JoinPath $env:LOCALAPPDATA 'Microsoft' 'Windows' 'Fonts') }
    return (JoinPath $HOME '.local' 'share' 'fonts')
}

# The MnmlSymbols already on this machine, if any: the per-user copy
# first, then the machine-wide one. A machine-wide face is merged FROM
# but never written to — that needs elevation, and a per-user face wins
# for the user anyway.
function Find-InstalledFont($UserDest) {
    if (Test-Path -LiteralPath $UserDest) { return $UserDest }
    if ($env:WINDIR) {
        $machine = JoinPath $env:WINDIR 'Fonts' 'MnmlSymbols.ttf'
        if (Test-Path -LiteralPath $machine) { return $machine }
    }
    return ''
}

function Register-UserFont($Path) {
    if (-not $OnWindows) {
        Plan "(not Windows — skipping the HKCU registration of $Path)"
        return
    }
    if (-not (Test-Path -LiteralPath $FontRegKey)) {
        New-Item -Path $FontRegKey -Force | Out-Null
    }
    New-ItemProperty -Path $FontRegKey -Name $FontRegName -Value $Path `
        -PropertyType String -Force | Out-Null
    Plan "registered   $FontRegName → $Path"
}

function Invoke-InstallFont {
    $say = if ($DryRun) { 'install-font --dry-run' } else { 'install-font' }
    $dir = Get-UserFontDir
    $dest = Join-Path $dir 'MnmlSymbols.ttf'
    $home_ = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $backupDir = JoinPath $home_ 'Backups' 'mnml-zig' 'fonts'
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $source = Find-InstalledFont $dest

    if ($source) {
        Log "${say}: merging into the installed face at $source"
        if ($DryRun) {
            Plan "would back up $source → $(Join-Path $backupDir "MnmlSymbols-$stamp.ttf")"
            Plan "would run    $Zig build font-merge -Dfont-in=$source -Dfont-out=$dest.new"
            Plan "would move   $dest.new → $dest"
            Plan "would register $FontRegName → $dest"
            Log "${say}: nothing was changed"
            return 0
        }
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        $backup = Join-Path $backupDir "MnmlSymbols-$stamp.ttf"
        Copy-Item -LiteralPath $source -Destination $backup -Force
        Plan "backed up    $source → $backup"
        # Written through a temp file: a merge that fails must not leave
        # a half-font where a working one was.
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $staged = "$dest.new"
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        $code = Invoke-Zig 'build' 'font-merge' "-Dfont-in=$source" "-Dfont-out=$staged"
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $staged)) {
            Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
            Log "${say}: the merge failed — $dest is untouched (the backup is at $backup)"
            return 1
        }
        Move-Item -LiteralPath $staged -Destination $dest -Force
        Plan "merged       $dest"
    }
    else {
        $built = JoinPath $Repo 'zig-out' 'share' 'mnml' 'fonts' 'MnmlSymbols.ttf'
        Log "${say}: no MnmlSymbols installed — copying this build's"
        if ($DryRun) {
            Plan "would run    $Zig build font"
            Plan "would copy   zig-out\share\mnml\fonts\MnmlSymbols.ttf → $dest"
            Plan "would register $FontRegName → $dest"
            Log "${say}: nothing was changed"
            return 0
        }
        if ((Invoke-Zig 'build' 'font') -ne 0) { Log "${say}: the font build failed"; return 1 }
        if (-not (Test-Path -LiteralPath $built)) { Log "${say}: $built is missing after the build"; return 1 }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $built -Destination $dest -Force
        Plan "zig-out\share\mnml\fonts\MnmlSymbols.ttf → $dest"
    }

    Register-UserFont $dest
    Log "${say}: done."
    Write-Host ''
    Write-Host '  Windows Terminal reads the font list when it launches, so close every'
    Write-Host '  window and start it again — a new tab is not enough. Then check mnml''s'
    Write-Host '  own marks: the unfocused terminal pane''s hollow cursor should paint a'
    Write-Host '  block outline, not ▯. `:integrations.audit_glyphs` names the rest.'
    Write-Host ''
    Write-Host '  Windows Terminal has no font-fallback setting, so a profile whose font'
    Write-Host '  face is a plain mono still shows Nerd Font icons as boxes. Set Settings →'
    Write-Host '  your profile → Appearance → Font face to a full Nerd-Font-patched mono'
    Write-Host '  (CaskaydiaCove NFM, JetBrainsMono NFM) — never the symbols-only face,'
    Write-Host '  which has no letters. MnmlSymbols is only for mnml''s own U+F1B00–U+F20FF.'
    Write-Host ''
    return 0
}

# ── installed-status ────────────────────────────────────────────────────

function Invoke-InstalledStatus {
    $dest = JoinPath $Prefix 'bin' ('mnml' + $ExeExt)
    $head = Get-GitHead
    Write-Host "prefix:    $Prefix"
    if (-not (Test-Path -LiteralPath $dest)) {
        Write-Host "installed: nothing at $dest (.\run.ps1 install)"
        return 0
    }
    if (-not (Test-IsOurs $dest)) {
        Write-Host "installed: $dest is NOT an mnml-zig (``--version`` does not say so) — .\run.ps1 install -Force replaces it"
        return 0
    }
    Write-Host ("installed: " + (Invoke-Capture -Exe $dest -Arguments @('--version')).Text)
    $describe = (Invoke-Capture -Exe 'git' -Arguments @('-C', $Repo, 'describe', '--tags', '--always', '--dirty')).Text
    if (-not $describe) { $describe = $head }
    Write-Host "here:      $describe  (HEAD $head)"
    $root = Get-DataRoot -Path $dest -ProfileName 'stable'
    if (-not $root) { $root = '?' }
    Write-Host "data:      $root"
    $binDir = Join-Path $root 'bin'
    if (Test-Path -LiteralPath $binDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $binDir -File | Sort-Object Name)) {
            # run.sh reads a symlink's target here. Windows has a copy,
            # so the question "does this still come from the prefix?"
            # is answered by comparing it with the prefix's copy — a
            # stale one is exactly the bug the relink step exists for.
            $inPrefix = JoinPath $Prefix 'bin' $f.Name
            if (-not (Test-Path -LiteralPath $inPrefix)) {
                Write-Host "copy:      $($f.Name) — no $inPrefix to compare with (installed from somewhere else)"
                continue
            }
            $a = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $b = (Get-FileHash -LiteralPath $inPrefix -Algorithm SHA256).Hash
            if ($a -eq $b) { Write-Host "copy:      $($f.Name) = $inPrefix" }
            else { Write-Host "copy:      $($f.Name) DIFFERS from $inPrefix — re-run .\run.ps1 install" }
        }
    }
    return 0
}

# ── profile ─────────────────────────────────────────────────────────────
# Which mnml is this tree's build, and where does it keep everything?
# The answer comes from the binary (`mnml profile`) rather than being
# reconstructed here, so the %USERPROFILE% rung, the %TEMP% marker and
# the mailbox name are whatever the program actually resolves — which is
# the thing a first Windows session most wants to see confirmed.

function Invoke-Profile {
    $built = BinPath 'mnml-zig'
    if (-not (Test-Path -LiteralPath $built)) {
        Log "profile: no binary at $built — run ``zig build -Doptimize=ReleaseSafe`` first"
        return 1
    }
    $p = if ($env:MNML_PROFILE) { $env:MNML_PROFILE } else { 'dev' }
    Write-Host "binary:   $built"
    $saved = $env:MNML_PROFILE
    $env:MNML_PROFILE = $p
    try { $r = Invoke-Capture -Exe $built -Arguments @('profile') }
    finally { Set-Env 'MNML_PROFILE' $saved }
    Write-Host $r.Text
    if ($r.Code -ne 0) { return $r.Code }
    $installed = JoinPath $Prefix 'bin' ('mnml' + $ExeExt)
    if (Test-Path -LiteralPath $installed) {
        Write-Host ''
        Write-Host "installed mnml at $installed — .\run.ps1 installed-status for its side"
    }
    return 0
}

# ── help ────────────────────────────────────────────────────────────────

function Show-Help {
    @'
run.ps1 — run.sh's daily-driver verbs, for Windows.

  .\run.ps1 install [-Prefix DIR] [-DryRun] [-Force] [-AllowDirty]
      Install this build as the mnml you live in: a verified ReleaseSafe
      build of the host (as mnml.exe) and the shipped integrations to
      PREFIX\bin, zig-out\share to PREFIX\share, and each integration's
      manifest into the STABLE profile's data root with a copy of its
      binary at <data root>\bin — so a rebuild in this repo never moves
      the binaries under the running stable copy.
      Default prefix: %LOCALAPPDATA%\Programs\mnml.
      Refuses a dirty tree or a non-ReleaseSafe MNML_OPTIMIZE
      (-AllowDirty), and refuses to overwrite a PREFIX\bin\mnml.exe that
      is not an mnml-zig (-Force).

  .\run.ps1 install-font [-DryRun]
      Put MnmlSymbols.ttf in %LOCALAPPDATA%\Microsoft\Windows\Fonts and
      register it under HKCU (per-user, no elevation), MERGING with
      whatever face is already there so older codepoints survive. The
      old file is backed up to %USERPROFILE%\Backups\mnml-zig\fonts\
      first. `install` only prints this step.

  .\run.ps1 installed-status [-Prefix DIR]
      The installed mnml's version and prefix against this tree's HEAD,
      its stable data root, and whether each <data root>\bin copy still
      matches the one in the prefix.

  .\run.ps1 profile
      What this tree's build resolves for the current profile: data
      root, session file, IPC mailbox and the %TEMP% marker, straight
      from the binary. MNML_PROFILE picks the profile (default dev).

Environment: MNML_ZIG, MNML_OPTIMIZE, MNML_PREFIX / PREFIX, MNML_PROFILE.
The restart loop, headless, shot, clean and the IPC verbs are bash-only
(run.sh); docs/WINDOWS.md says what else is not proven on Windows yet.
'@ | Write-Host
}

# ── dispatch ────────────────────────────────────────────────────────────

switch ($Verb) {
    'install' { exit (Invoke-Install) }
    'install-font' { exit (Invoke-InstallFont) }
    'installed-status' { exit (Invoke-InstalledStatus) }
    'profile' { exit (Invoke-Profile) }
    'help' { Show-Help; exit 0 }
    '-h' { Show-Help; exit 0 }
    '--help' { Show-Help; exit 0 }
    default {
        Log "unknown verb: $Verb"
        Show-Help
        exit 2
    }
}
