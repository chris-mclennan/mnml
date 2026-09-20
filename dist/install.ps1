# mnml installer for Windows — downloads the x86_64 release zip, checks its
# sha256, puts mnml.exe under %LOCALAPPDATA%\mnml\bin and adds that to the
# user PATH.
#
#   powershell -ExecutionPolicy Bypass -c "irm https://github.com/chris-mclennan/mnml-zig/releases/latest/download/mnml-installer.ps1 | iex"
#
# Environment (same names as install.sh):
#   MNML_VERSION       a tag without the v (0.3.0); default: the latest release
#   MNML_INSTALL_DIR   where mnml.exe goes; default: %LOCALAPPDATA%\mnml\bin
#   MNML_REPO          owner/repo on GitHub; default: chris-mclennan/mnml-zig
#   MNML_BASE_URL      full URL of the release's asset directory; overrides
#                      MNML_REPO + MNML_VERSION (mirrors, local testing)
#
# Windows PowerShell 5.1 and PowerShell 7 both run this. ARM64 Windows gets
# the x86_64 build (it runs under emulation; there is no native arm64 build).

$ErrorActionPreference = 'Stop'

$Repo = if ($env:MNML_REPO) { $env:MNML_REPO } else { 'chris-mclennan/mnml-zig' }
$Version = $env:MNML_VERSION
$InstallDir = if ($env:MNML_INSTALL_DIR) { $env:MNML_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'mnml\bin' }
$BaseUrl = $env:MNML_BASE_URL

$Triple = 'x86_64-pc-windows-gnu'
$Asset = "mnml-$Triple.zip"

if (-not $BaseUrl) {
    if ($Version) {
        $BaseUrl = "https://github.com/$Repo/releases/download/v$($Version.TrimStart('v'))"
    } else {
        $BaseUrl = "https://github.com/$Repo/releases/latest/download"
    }
}

# TLS 1.2 for Windows PowerShell 5.1, which still defaults to older protocols.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("mnml-install-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
    Write-Host "mnml: downloading $BaseUrl/$Asset"
    Invoke-WebRequest -Uri "$BaseUrl/$Asset" -OutFile (Join-Path $Tmp $Asset) -UseBasicParsing
    Invoke-WebRequest -Uri "$BaseUrl/$Asset.sha256" -OutFile (Join-Path $Tmp "$Asset.sha256") -UseBasicParsing

    $Expected = ((Get-Content (Join-Path $Tmp "$Asset.sha256") -Raw) -split '\s+')[0].ToLowerInvariant()
    $Actual = (Get-FileHash -Algorithm SHA256 (Join-Path $Tmp $Asset)).Hash.ToLowerInvariant()
    if ($Expected -ne $Actual) {
        throw "sha256 mismatch for ${Asset}: expected $Expected, got $Actual"
    }
    Write-Host 'mnml: sha256 verified'

    Expand-Archive -Path (Join-Path $Tmp $Asset) -DestinationPath $Tmp -Force
    $Exe = Get-ChildItem -Path $Tmp -Recurse -Filter 'mnml.exe' | Select-Object -First 1
    if (-not $Exe) { throw 'archive did not contain mnml.exe' }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $Target = Join-Path $InstallDir 'mnml.exe'
    # Copy beside, then rename: a running mnml keeps its old file handle.
    $Staged = Join-Path $InstallDir 'mnml.exe.tmp'
    Copy-Item -Path $Exe.FullName -Destination $Staged -Force
    Move-Item -Path $Staged -Destination $Target -Force
    $Shown = try { & $Target --version 2>$null } catch { 'mnml' }
    Write-Host "mnml: installed $Shown to $Target"

    # The curated Lua script set. The zip carries it as share\mnml\lua
    # beside mnml.exe; mnml looks there and one level up, so
    # ...\mnml\bin\mnml.exe finds ...\mnml\share\mnml\lua. Ours, not the
    # user's (installed scripts live under the data root), so an upgrade
    # replaces it wholesale; a failure here costs an empty Marketplace
    # tab, not the install.
    $LuaSrc = Join-Path $Exe.Directory.FullName 'share\mnml\lua'
    if (Test-Path $LuaSrc) {
        try {
            $ShareDir = Join-Path (Split-Path -Parent $InstallDir) 'share\mnml'
            New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null
            $LuaDst = Join-Path $ShareDir 'lua'
            if (Test-Path $LuaDst) { Remove-Item -Recurse -Force $LuaDst }
            Copy-Item -Path $LuaSrc -Destination $LuaDst -Recurse -Force
            Write-Host "mnml: script set installed to $LuaDst"
        } catch {
            Write-Host 'mnml: could not install the script set (the editor still runs)'
        }
    }

    # The mnml catalogue — the INTEGRATIONS section's Marketplace tab
    # default source. Laid beside the script set and probed the same way.
    $CatSrc = Join-Path $Exe.Directory.FullName 'share\mnml\marketplace.zon'
    if (Test-Path $CatSrc) {
        try {
            $ShareDir = Join-Path (Split-Path -Parent $InstallDir) 'share\mnml'
            New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null
            Copy-Item -Path $CatSrc -Destination (Join-Path $ShareDir 'marketplace.zon') -Force
            Write-Host "mnml: integration catalogue installed to $ShareDir\marketplace.zon"
        } catch {
            Write-Host 'mnml: could not install the integration catalogue (the Marketplace tab will be empty)'
        }
    }

    # MnmlSymbols.ttf, the face mnml's own marks are drawn from. Laid
    # beside the script set; the terminal still has to be told about it.
    $FontSrc = Join-Path $Exe.Directory.FullName 'share\mnml\fonts\MnmlSymbols.ttf'
    if (Test-Path $FontSrc) {
        try {
            $FontDir = Join-Path (Split-Path -Parent $InstallDir) 'share\mnml\fonts'
            New-Item -ItemType Directory -Path $FontDir -Force | Out-Null
            Copy-Item -Path $FontSrc -Destination (Join-Path $FontDir 'MnmlSymbols.ttf') -Force
            Write-Host "mnml: symbols font installed to $FontDir\MnmlSymbols.ttf"
        } catch {
            Write-Host "mnml: could not install the symbols font (mnml's own marks will show as ?)"
        }
    }

    # User-scope PATH — no elevation, takes effect in new shells.
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $OnPath = ($UserPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) }).Count -gt 0
        if (-not $OnPath) {
            $NewPath = if ($UserPath) { "$UserPath;$InstallDir" } else { $InstallDir }
            [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')
            Write-Host "mnml: added $InstallDir to your user PATH (open a new terminal to pick it up)"
        }
        if (($env:Path -split ';') -notcontains $InstallDir) { $env:Path = "$env:Path;$InstallDir" }
    } else {
        Write-Host "mnml: add $InstallDir to your PATH"
    }
} finally {
    Remove-Item -Path $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
