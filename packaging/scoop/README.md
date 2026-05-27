# Scoop install (Windows)

mnml ships a [Scoop](https://scoop.sh) manifest so Windows users can install
the latest release with two commands:

```powershell
# One-time: tell Scoop where mnml's manifest lives.
scoop bucket add mnml https://github.com/chris-mclennan/mnml-rs
# Install (or upgrade).
scoop install mnml/mnml
```

Scoop will fetch the most recent `mnml-x86_64-pc-windows-msvc.zip` from the
GitHub releases page (built by `.github/workflows/release-artifacts.yml`),
verify its `.sha256` companion file, and drop `mnml.exe` onto `$PATH`.

## Bumping the manifest after a release

`autoupdate` already templates `$version` into the URL, so a maintainer can
run `scoop update mnml` locally and the manifest's `url` + `hash` fields
fill in from the latest GitHub release. Commit the result.

If you'd rather not maintain the manifest in this repo, move it to a
dedicated `scoop-bucket` repo and have users add that bucket instead — the
manifest itself is identical.

## Alternative: PowerShell installer

Users who don't have Scoop can run the bare `install.ps1` script from the
project root (planned), which downloads the same zip and unpacks it to
`%LOCALAPPDATA%\mnml\bin`.
