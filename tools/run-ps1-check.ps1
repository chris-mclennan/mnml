<#
  tools/run-ps1-check.ps1 — run.ps1's verbs against a throwaway repo and
  a throwaway prefix, the Windows twin of tools/run-sh-check.sh's
  section 8. Every path it touches is under one temp directory:

    MNML_PREFIX      the install prefix
    MNML_DATA_ROOT   the app's config — never %LOCALAPPDATA%\mnml
    MNML_ZIG         a fake `zig` that logs its argv and builds nothing,
                     which is how "the build path was taken" is observed
                     without a two-minute compile
    USERPROFILE      pointed at the tempdir for install-font's backups
    LOCALAPPDATA     pointed at the tempdir for the font destination

  What it proves, in order:

    1. `help` and an unknown verb: exit 0 and exit 2.
    2. `install -DryRun`: the plan names the host copy, each integration
       copy, the manifest write into the stable data root, the copy into
       <data root>\bin, and skips the sample; it changes nothing.
    3. The three refusals: a dirty tree, a non-ReleaseSafe
       MNML_OPTIMIZE, and a PREFIX\bin\mnml.exe that is not an
       mnml-zig — each exit 1, each with its escape hatch named, and
       the foreign binary left alone.
    4. A real install into the scratch prefix, with the REAL binaries
       that are already in zig-out (the compile is the fake zig; what
       is proved is everything around it): the host, an integration,
       share\, the manifest, the copy in the data root that matches the
       prefix's, and the sample's binary present with no manifest.
    5. `installed-status`: version, data root, and the copy reported as
       matching.
    6. `install-font -DryRun` both ways — nothing installed, and a face
       already there (merge + backup named) — then a real run where the
       fake zig produces no merged file: it must fail loudly, leave the
       installed face byte-for-byte as it was, and have taken the
       backup first.

  Run it from a checkout with zig-out\bin already built:

      zig build -Doptimize=ReleaseSafe
      pwsh -NoProfile -File tools\run-ps1-check.ps1

  Windows PowerShell 5.1 runs it too (`powershell -NoProfile -File …`).
  On a non-Windows pwsh it still exercises the copy / manifest / plan
  logic — run.ps1 derives the executable suffix rather than hard-coding
  `.exe` — and says which Windows-only assertions it skipped.
#>

[CmdletBinding()]
param([string]$Repo)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
$OnWindows = ($env:OS -eq 'Windows_NT')
$ExeExt = if ($OnWindows) { '.exe' } else { '' }
$RunPs1 = Join-Path $Repo 'run.ps1'
if (-not (Test-Path -LiteralPath $RunPs1)) {
    Write-Host "run-ps1-check: no $RunPs1"
    exit 64
}

$RealBin = Join-Path (Join-Path $Repo 'zig-out') (Join-Path 'bin' ('mnml-zig' + $ExeExt))
if (-not (Test-Path -LiteralPath $RealBin)) {
    Write-Host "run-ps1-check: build first: zig build -Doptimize=ReleaseSafe"
    exit 64
}

$script:Pass = 0
$script:Fail = 0
function Ok($Label) { $script:Pass++; Write-Host "  ok   $Label" }
function Bad($Label, $Detail) {
    $script:Fail++
    Write-Host "  FAIL $Label"
    if ($Detail) { Write-Host "       $Detail" }
}
function Check($Label, $Condition, $Detail) {
    if ($Condition) { Ok $Label } else { Bad $Label $Detail }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("run-ps1-check-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

# Everything the script or the app could write, redirected under $Tmp.
$SavedEnv = @{}
foreach ($k in @('MNML_PREFIX', 'PREFIX', 'MNML_DATA_ROOT', 'MNML_ZIG', 'MNML_OPTIMIZE',
                 'USERPROFILE', 'LOCALAPPDATA', 'HOME', 'XDG_CONFIG_HOME')) {
    $SavedEnv[$k] = [Environment]::GetEnvironmentVariable($k)
}
function Restore-Env {
    foreach ($k in $SavedEnv.Keys) {
        if ($null -eq $SavedEnv[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$k" $SavedEnv[$k] }
    }
}

try {
    $DataRoot = Join-Path $Tmp 'data'
    $FakeHome = Join-Path $Tmp 'home'
    $LocalApp = Join-Path $Tmp 'localappdata'
    New-Item -ItemType Directory -Path $DataRoot, $FakeHome, $LocalApp -Force | Out-Null
    $env:MNML_DATA_ROOT = $DataRoot
    $env:USERPROFILE = $FakeHome
    $env:LOCALAPPDATA = $LocalApp
    $env:HOME = $FakeHome
    Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:MNML_OPTIMIZE -ErrorAction SilentlyContinue
    Remove-Item Env:PREFIX -ErrorAction SilentlyContinue

    # A fake zig: logs its argv, builds nothing.
    $ZigLog = Join-Path $Tmp 'zig.log'
    if ($OnWindows) {
        $FakeZig = Join-Path $Tmp 'fakezig.cmd'
        Set-Content -LiteralPath $FakeZig -Encoding ASCII -Value @"
@echo off
echo %* >> "$ZigLog"
exit /b 0
"@
    }
    else {
        $FakeZig = Join-Path $Tmp 'fakezig'
        Set-Content -LiteralPath $FakeZig -Value "#!/bin/sh`necho `"`$*`" >> `"$ZigLog`"`n"
        & chmod +x $FakeZig
    }
    $env:MNML_ZIG = $FakeZig

    # A throwaway repo: run.ps1, a zig-out that is the real one (so the
    # binaries exist), and two integration manifests.
    $Fake = Join-Path $Tmp 'repo'
    New-Item -ItemType Directory -Path $Fake -Force | Out-Null
    Copy-Item -LiteralPath $RunPs1 -Destination (Join-Path $Fake 'run.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $Repo 'zig-out') -Destination (Join-Path $Fake 'zig-out') -Recurse -Force
    $Ints = Join-Path $Fake 'integrations'
    New-Item -ItemType Directory -Path (Join-Path $Ints 'jira'), (Join-Path $Ints 'sample') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path (Join-Path $Ints 'jira') 'manifest.zon') -Value @'
.{
    .id = "jira_work",
    .label = "Jira",
    .binary = "mnml-jira",
    .category = "tracker",
}
'@
    Set-Content -LiteralPath (Join-Path (Join-Path $Ints 'sample') 'manifest.zon') -Value @'
.{
    .id = "sample",
    .label = "Sample",
    .binary = "mnml-sample",
    .category = "sample",
}
'@
    & git init -q $Fake 2>&1 | Out-Null
    Push-Location $Fake
    & git add -A 2>&1 | Out-Null
    & git -c user.email=t@t -c user.name=t commit -qm init 2>&1 | Out-Null
    Pop-Location

    $FakeRunPs1 = Join-Path $Fake 'run.ps1'
    $PrefixOk = Join-Path $Tmp 'prefix'
    $PrefixDry = Join-Path $Tmp 'prefix-dry'
    $PrefixForeign = Join-Path $Tmp 'prefix-foreign'

    # Invoke run.ps1 as a child process so every stream lands in one
    # string and an `exit` in it does not end this script.
    $Shell = (Get-Process -Id $PID).Path
    function Run-Verb {
        param([string[]]$Arguments)
        $all = @('-NoProfile', '-NonInteractive', '-File', $FakeRunPs1) + $Arguments
        $text = (& $Shell @all 2>&1 | Out-String)
        return [pscustomobject]@{ Text = $text; Code = $LASTEXITCODE }
    }

    Write-Host "run-ps1-check: $FakeRunPs1 (prefix $PrefixOk)"

    # ── 1. help, and an unknown verb ────────────────────────────────
    $r = Run-Verb @('help')
    Check 'help: exit 0' ($r.Code -eq 0) $r.Text
    Check 'help: names every verb' (($r.Text -match 'install-font') -and ($r.Text -match 'installed-status') -and ($r.Text -match 'paths')) $r.Text
    $r = Run-Verb @('nonsense')
    Check 'an unknown verb exits 2' ($r.Code -eq 2) $r.Text

    # ── 2. install -DryRun ──────────────────────────────────────────
    $r = Run-Verb @('install', '-DryRun', '-Prefix', $PrefixDry)
    Check 'install -DryRun: exit 0' ($r.Code -eq 0) $r.Text
    Check 'install -DryRun: names the host copy' ($r.Text -match [regex]::Escape("would copy   $RealBin")) $r.Text
    Check 'install -DryRun: names the host destination' ($r.Text -match [regex]::Escape((Join-Path (Join-Path $PrefixDry 'bin') ('mnml' + $ExeExt)))) $r.Text
    Check 'install -DryRun: names the integration copy' ($r.Text -match [regex]::Escape((Join-Path (Join-Path $PrefixDry 'bin') ('mnml-jira' + $ExeExt)))) $r.Text
    Check 'install -DryRun: names the manifest write into the data root' ($r.Text -match [regex]::Escape("would run    MNML_DATA_ROOT=$DataRoot")) $r.Text
    Check 'install -DryRun: names the copy into the data root' ($r.Text -match [regex]::Escape((Join-Path (Join-Path $DataRoot 'bin') ('mnml-jira' + $ExeExt)))) $r.Text
    Check 'install -DryRun: the sample is a fixture, not a chip' ($r.Text -match 'would skip   mnml-sample --install') $r.Text
    Check 'install -DryRun: names install-font as the font step' ($r.Text -match '\.\\run\.ps1 install-font') $r.Text
    Check 'install -DryRun: changed nothing' (-not (Test-Path -LiteralPath $PrefixDry)) ''
    Check 'install -DryRun: built nothing' (-not (Test-Path -LiteralPath $ZigLog)) ''

    # ── 3. the three refusals ───────────────────────────────────────
    Set-Content -LiteralPath (Join-Path $Fake 'dirty.txt') -Value 'scratch'
    $r = Run-Verb @('install', '-DryRun', '-Prefix', $PrefixOk)
    Check 'install: a dirty tree is refused (exit 1)' ($r.Code -eq 1) $r.Text
    Check 'install: says which file is dirty' ($r.Text -match 'dirty\.txt') $r.Text
    Check 'install: names -AllowDirty' ($r.Text -match '-AllowDirty') $r.Text
    $r = Run-Verb @('install', '-DryRun', '-AllowDirty', '-Prefix', $PrefixOk)
    Check 'install: -AllowDirty gets past it' ($r.Code -eq 0) $r.Text
    Remove-Item -LiteralPath (Join-Path $Fake 'dirty.txt') -Force

    $env:MNML_OPTIMIZE = 'Debug'
    $r = Run-Verb @('install', '-DryRun', '-Prefix', $PrefixOk)
    Check 'install: a Debug build is refused (exit 1)' ($r.Code -eq 1) $r.Text
    Check 'install: says why' ($r.Text -match 'MNML_OPTIMIZE=Debug') $r.Text
    Remove-Item Env:MNML_OPTIMIZE -ErrorAction SilentlyContinue

    $ForeignBin = Join-Path $PrefixForeign 'bin'
    New-Item -ItemType Directory -Path $ForeignBin -Force | Out-Null
    $Foreign = Join-Path $ForeignBin ('mnml' + $ExeExt)
    if ($OnWindows) {
        Copy-Item -LiteralPath "$env:WINDIR\System32\where.exe" -Destination $Foreign -Force
    }
    else {
        Set-Content -LiteralPath $Foreign -Value "#!/bin/sh`necho `"mnml: unknown flag: `$*`" >&2`nexit 1`n"
        & chmod +x $Foreign
    }
    $Before = (Get-FileHash -LiteralPath $Foreign -Algorithm SHA256).Hash
    $r = Run-Verb @('install', '-DryRun', '-Prefix', $PrefixForeign)
    Check 'install: will not overwrite a binary that is not an mnml-zig (exit 1)' ($r.Code -eq 1) $r.Text
    Check 'install: says -Force is the way' ($r.Text -match '-Force') $r.Text
    Check 'install: left the foreign binary alone' ((Get-FileHash -LiteralPath $Foreign -Algorithm SHA256).Hash -eq $Before) ''

    # ── 4. a real install ───────────────────────────────────────────
    $r = Run-Verb @('install', '-Prefix', $PrefixOk)
    Check 'install: exit 0' ($r.Code -eq 0) $r.Text
    Check 'install: verified the build before copying' ($r.Text -match 'verified: mnml-zig ') $r.Text
    Check 'install: asked zig for a ReleaseSafe build with the shipped names' ((Test-Path -LiteralPath $ZigLog) -and ((Get-Content -LiteralPath $ZigLog -Raw) -match '-Dinstall-names=true')) ''
    Check 'install: built the two shipped integrations by name' ((Test-Path -LiteralPath $ZigLog) -and ((Get-Content -LiteralPath $ZigLog -Raw) -match 'jira-integration') -and ((Get-Content -LiteralPath $ZigLog -Raw) -match 'bitbucket-integration')) ''
    $InstalledMnml = Join-Path (Join-Path $PrefixOk 'bin') ('mnml' + $ExeExt)
    Check 'install: the host landed as PREFIX\bin\mnml' (Test-Path -LiteralPath $InstalledMnml) ''
    $v = (& $InstalledMnml --version 2>&1 | Out-String)
    Check 'install: PREFIX\bin\mnml --version says what it is' ($v -match '(?m)^mnml(-zig)? 0\.[3-9]') $v
    Check 'install: the integration landed too' (Test-Path -LiteralPath (Join-Path (Join-Path $PrefixOk 'bin') ('mnml-jira' + $ExeExt))) ''
    Check 'install: the font came with it' (Test-Path -LiteralPath (Join-Path $PrefixOk 'share\mnml\fonts\MnmlSymbols.ttf')) ''
    Check 'install: the integration catalogue came with it' (Test-Path -LiteralPath (Join-Path $PrefixOk 'share\mnml\marketplace.zon')) ''
    Check 'install: the manifest went to the stable data root' (Test-Path -LiteralPath (Join-Path $DataRoot 'integrations\jira_work.zon')) ''
    $RootCopy = Join-Path (Join-Path $DataRoot 'bin') ('mnml-jira' + $ExeExt)
    $PrefixCopy = Join-Path (Join-Path $PrefixOk 'bin') ('mnml-jira' + $ExeExt)
    Check 'install: the data root holds a copy of the integration' (Test-Path -LiteralPath $RootCopy) ''
    if (Test-Path -LiteralPath $RootCopy) {
        $a = (Get-FileHash -LiteralPath $RootCopy -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath $PrefixCopy -Algorithm SHA256).Hash
        Check 'install: the data root copy is the prefix one, not a zig-out one' ($a -eq $b) ''
    }
    Check 'install: the sample binary ships, its manifest does not' ((Test-Path -LiteralPath (Join-Path (Join-Path $PrefixOk 'bin') ('mnml-sample' + $ExeExt))) -and -not (Test-Path -LiteralPath (Join-Path $DataRoot 'integrations\sample.zon'))) ''
    Check 'install: never wrote the OS font directory' (-not (Test-Path -LiteralPath (Join-Path $LocalApp 'Microsoft\Windows\Fonts\MnmlSymbols.ttf'))) ''

    # ── 5. installed-status ─────────────────────────────────────────
    $r = Run-Verb @('installed-status', '-Prefix', $PrefixOk)
    Check 'installed-status: names the installed version' ($r.Text -match '(?m)^installed: mnml-zig ') $r.Text
    Check 'installed-status: names the data root' ($r.Text -match [regex]::Escape("data:      $DataRoot")) $r.Text
    Check 'installed-status: reports the copy as matching the prefix' ($r.Text -match [regex]::Escape("copy:      mnml-jira$ExeExt = $PrefixCopy")) $r.Text
    $r = Run-Verb @('installed-status', '-Prefix', (Join-Path $Tmp 'nothing-here'))
    Check 'installed-status: an empty prefix says so' ($r.Text -match 'installed: nothing at ') $r.Text

    # ── 6. install-font ─────────────────────────────────────────────
    $FontDir = Join-Path $LocalApp 'Microsoft\Windows\Fonts'
    $FontDest = Join-Path $FontDir 'MnmlSymbols.ttf'
    $r = Run-Verb @('install-font', '-DryRun')
    Check 'install-font -DryRun: exit 0 with nothing installed' ($r.Code -eq 0) $r.Text
    Check 'install-font -DryRun: says there is no face to merge with' ($r.Text -match 'no MnmlSymbols installed') $r.Text
    Check 'install-font -DryRun: names the destination' ($r.Text -match [regex]::Escape($FontDest)) $r.Text
    Check 'install-font -DryRun: names the HKCU registration' ($r.Text -match 'would register MnmlSymbols \(TrueType\)') $r.Text
    Check 'install-font -DryRun: wrote nothing' (-not (Test-Path -LiteralPath $FontDest)) ''

    New-Item -ItemType Directory -Path $FontDir -Force | Out-Null
    Set-Content -LiteralPath $FontDest -Value 'not really a font, but a file that is in the way'
    $FontBefore = (Get-FileHash -LiteralPath $FontDest -Algorithm SHA256).Hash
    $r = Run-Verb @('install-font', '-DryRun')
    Check 'install-font -DryRun: exit 0 with a face installed' ($r.Code -eq 0) $r.Text
    Check 'install-font -DryRun: merges rather than overwrites' ($r.Text -match [regex]::Escape("font-merge -Dfont-in=$FontDest")) $r.Text
    Check 'install-font -DryRun: names the backup' ($r.Text -match 'would back up .*MnmlSymbols-') $r.Text
    Check 'install-font -DryRun: still wrote nothing' ((Get-FileHash -LiteralPath $FontDest -Algorithm SHA256).Hash -eq $FontBefore) ''

    # For real. The fake zig builds nothing, so the merge produces no
    # file — the failure this must survive: the installed face is left
    # exactly as it was and the backup is already on disk.
    $r = Run-Verb @('install-font')
    Check 'install-font: a merge that produces no file fails loudly' ($r.Code -ne 0) $r.Text
    Check 'install-font: and leaves the installed face untouched' ((Get-FileHash -LiteralPath $FontDest -Algorithm SHA256).Hash -eq $FontBefore) ''
    Check 'install-font: the backup was taken before the merge ran' ((Test-Path -LiteralPath (Join-Path $FakeHome 'Backups\mnml-zig\fonts')) -and @(Get-ChildItem -LiteralPath (Join-Path $FakeHome 'Backups\mnml-zig\fonts') -Filter 'MnmlSymbols-*.ttf').Count -gt 0) ''
    Check 'install-font: no half-written .new is left behind' (-not (Test-Path -LiteralPath "$FontDest.new")) ''
    Check 'install-font: asked zig for the merge' ((Get-Content -LiteralPath $ZigLog -Raw) -match 'font-merge') ''
    if (-not $OnWindows) {
        Write-Host '  skip the HKCU registration assertions (not Windows)'
    }
}
finally {
    Restore-Env
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "run-ps1-check: $script:Pass passed, $script:Fail failed"
if ($script:Fail -ne 0) { exit 1 }
exit 0
