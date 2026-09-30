// The one place the site names the GitHub repository. Every GitHub URL,
// install line and download link on the site is built from REPO, and
// tools/cutover-check.sh's old-repo item greps site/ for a stale slug.
export const REPO = "chris-mclennan/mnml";

export const GITHUB = `https://github.com/${REPO}`;
export const RELEASES = `${GITHUB}/releases`;
export const LATEST_DOWNLOAD = `${RELEASES}/latest/download`;

// The Homebrew tap, as README.md has it.
export const BREW_INSTALL = "brew install chris-mclennan/tap/mnml";

// The installer one-liners, as README.md has them. They fetch the
// installer from releases/latest, so they never name a version.
export const INSTALLER_SH = `${LATEST_DOWNLOAD}/mnml-installer.sh`;
export const INSTALLER_PS1 = `${LATEST_DOWNLOAD}/mnml-installer.ps1`;
export const CURL_INSTALL = `curl --proto '=https' --tlsv1.2 -LsSf ${INSTALLER_SH} | sh`;
export const IRM_INSTALL = `powershell -ExecutionPolicy Bypass -c "irm ${INSTALLER_PS1} | iex"`;

export const editUrl = (p) => `${GITHUB}/edit/main/${p}`;
export const blobUrl = (p) => `${GITHUB}/blob/main/${p}`;
export const releaseUrl = (tag) => `${RELEASES}/tag/${tag}`;
export const assetUrl = (tag, name) => `${RELEASES}/download/${tag}/${name}`;
