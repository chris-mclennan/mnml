# build.ps1 — compile dist/msi/mnml.wxs into mnml-x86_64-pc-windows-gnu.msi.
#
#   dist\msi\build.ps1 -Zip zig-out\dist\mnml-x86_64-pc-windows-gnu.zip -Version 0.3.0
#   dist\msi\build.ps1 -BinDir zig-out\release\x86_64-pc-windows-gnu -Version 0.3.0
#
# Runs on windows-latest in release.yml, or on any Windows box with the
# .NET SDK. Installs the `wix` .NET tool (v5, pinned) if it is not on PATH —
# the runner images have moved WiX 3 around between versions, and a pinned
# dotnet tool is the same everywhere.
#
# An MSI ProductVersion is numeric major.minor.patch (each part < 65536), so a
# prerelease tag like 0.3.0-rc0 builds as 0.3.0; the full string is kept in
# the filename only when -KeepSuffix is given (winget wants the plain one).
[CmdletBinding()]
param(
    [string]$Zip,
    [string]$BinDir,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Out,
    [string]$WixVersion = '5.0.2',
    [switch]$KeepSuffix
)
$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Version = $Version.TrimStart('v')
$MsiVersion = ($Version -split '[-+]')[0]
if ($MsiVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Version '$Version' does not start with major.minor.patch" }
if (-not $Out) {
    $Out = if ($KeepSuffix) { "mnml-x86_64-pc-windows-gnu-$Version.msi" } else { 'mnml-x86_64-pc-windows-gnu.msi' }
}

if ($Zip) {
    $Extract = Join-Path ([IO.Path]::GetTempPath()) ("mnml-msi-" + [IO.Path]::GetRandomFileName())
    Expand-Archive -Path $Zip -DestinationPath $Extract -Force
    $Exe = Get-ChildItem -Path $Extract -Recurse -Filter 'mnml.exe' | Select-Object -First 1
    if (-not $Exe) { throw "$Zip has no mnml.exe" }
    $BinDir = $Exe.DirectoryName
}
if (-not $BinDir) { throw 'give -Zip or -BinDir' }
if (-not (Test-Path (Join-Path $BinDir 'mnml.exe'))) { throw "$BinDir has no mnml.exe" }

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    Write-Host "msi: installing wix $WixVersion (dotnet tool)"
    dotnet tool install --global wix --version $WixVersion | Out-Host
    $env:Path = "$env:Path;$(Join-Path $env:USERPROFILE '.dotnet\tools')"
}
wix --version | Out-Host

$BinDirAbs = (Resolve-Path $BinDir).Path
$OutAbs = [IO.Path]::GetFullPath($Out)
Write-Host "msi: mnml.exe from $BinDirAbs, ProductVersion $MsiVersion -> $OutAbs"
wix build -arch x64 -d "Version=$MsiVersion" -d "BinDir=$BinDirAbs" (Join-Path $Here 'mnml.wxs') -o $OutAbs
if ($LASTEXITCODE -ne 0) { throw "wix build failed ($LASTEXITCODE)" }

$Hash = (Get-FileHash -Algorithm SHA256 $OutAbs).Hash.ToLowerInvariant()
"$Hash  $(Split-Path -Leaf $OutAbs)" | Set-Content -NoNewline -Path "$OutAbs.sha256"
Write-Host "msi: $OutAbs ($((Get-Item $OutAbs).Length) bytes) sha256 $Hash"
