//! Compute a GitHub / GitLab / Bitbucket web URL for the current file at a
//! given line. Used by `git.browse` (`:GBrowse` / fugitive convention).
//!
//! Reads the origin remote URL via `git config --get remote.origin.url`,
//! normalizes SSH/HTTPS forms, then composes a `<host>/<owner>/<repo>/blob/
//! <rev>/<rel>#L<line>` URL. The rev is `HEAD`'s short SHA so the link is
//! stable even after force-pushes. Selections render as `#L<lo>-L<hi>`.

use std::path::Path;
use std::process::Command;

/// Build the web URL for `rel_path` at the given 1-based line range. Returns
/// `None` if the remote isn't a recognized host or `git` isn't available.
pub fn url_for(workspace: &Path, rel_path: &str, line_lo: u32, line_hi: u32) -> Option<String> {
    let remote_url = git_config(workspace, "remote.origin.url")?;
    let (host, owner, repo) = parse_remote(&remote_url)?;
    let sha = git_rev_parse(workspace, "HEAD").unwrap_or_else(|| "main".into());
    let line_frag = if line_lo == line_hi {
        format!("#L{line_lo}")
    } else {
        format!("#L{line_lo}-L{line_hi}")
    };
    // Bitbucket uses `/src/<rev>/<path>#lines-N` rather than `/blob/<rev>/...`.
    // We support GitHub + GitLab (`blob`) and Bitbucket (`src`) — the most
    // common hosts. Anything else falls back to GitHub's shape.
    let path_segment = if host.ends_with("bitbucket.org") {
        format!("src/{sha}/{rel_path}")
    } else {
        format!("blob/{sha}/{rel_path}")
    };
    Some(format!(
        "https://{host}/{owner}/{repo}/{path_segment}{line_frag}"
    ))
}

/// Build the commit-URL for `hash` on the remote (no line range).
pub fn commit_url(workspace: &Path, hash: &str) -> Option<String> {
    let remote_url = git_config(workspace, "remote.origin.url")?;
    let (host, owner, repo) = parse_remote(&remote_url)?;
    // GitHub/GitLab/Bitbucket all use `/commit/<hash>` (Bitbucket also
    // accepts `/commits/<hash>` but `/commit/` redirects there). Simple.
    Some(format!("https://{host}/{owner}/{repo}/commit/{hash}"))
}

pub fn parse_remote(url: &str) -> Option<(String, String, String)> {
    // SSH: `git@github.com:owner/repo.git` or `git@github.com:owner/repo`.
    if let Some(rest) = url.strip_prefix("git@") {
        let (host, path) = rest.split_once(':')?;
        let (owner, repo) = path.split_once('/')?;
        let repo = repo.trim_end_matches(".git");
        return Some((host.to_string(), owner.to_string(), repo.to_string()));
    }
    // HTTPS: `https://github.com/owner/repo[.git]`.
    if let Some(rest) = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
    {
        // Drop any `<user>@` prefix on the host.
        let rest = rest.split_once('@').map(|(_, r)| r).unwrap_or(rest);
        let (host, path) = rest.split_once('/')?;
        let (owner, repo) = path.split_once('/')?;
        let repo = repo.trim_end_matches('/').trim_end_matches(".git");
        return Some((host.to_string(), owner.to_string(), repo.to_string()));
    }
    None
}

/// Map a host string (from `parse_remote`) to a nerd-font icon — used by
/// the statusline to show a GitHub / GitLab / Bitbucket / Azure DevOps
/// glyph alongside the branch name. Falls back to the generic git glyph
/// for unrecognized hosts.
pub fn provider_icon(host: &str) -> &'static str {
    let h = host.to_ascii_lowercase();
    if h.contains("github.com") {
        "\u{F09B}" //  nf-fa-github
    } else if h.contains("gitlab") {
        "\u{F296}" //  nf-fa-gitlab
    } else if h.contains("bitbucket") {
        "\u{E703}" //  nf-dev-bitbucket
    } else if h.contains("dev.azure.com") || h.contains("visualstudio.com") {
        "\u{F0805}" // 󰠅 nf-md-microsoft (closest available)
    } else {
        "\u{E702}" //  nf-dev-git (generic)
    }
}

/// Resolve the git-provider icon for `workspace` by reading
/// `remote.origin.url` and matching the host. Returns `None` when the
/// workspace isn't a git repo or has no `origin` remote.
pub fn provider_icon_for(workspace: &Path) -> Option<&'static str> {
    let url = git_config(workspace, "remote.origin.url")?;
    let (host, _, _) = parse_remote(&url)?;
    Some(provider_icon(&host))
}

pub fn git_config(workspace: &Path, key: &str) -> Option<String> {
    let out = Command::new("git")
        .args(["config", "--get", key])
        .current_dir(workspace)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if v.is_empty() { None } else { Some(v) }
}

fn git_rev_parse(workspace: &Path, rev: &str) -> Option<String> {
    let out = Command::new("git")
        .args(["rev-parse", rev])
        .current_dir(workspace)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if v.is_empty() { None } else { Some(v) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_ssh_remote() {
        let (h, o, r) = parse_remote("git@github.com:rust-lang/rust.git").unwrap();
        assert_eq!(h, "github.com");
        assert_eq!(o, "rust-lang");
        assert_eq!(r, "rust");
    }

    #[test]
    fn parse_https_remote() {
        let (h, o, r) = parse_remote("https://github.com/rust-lang/rust").unwrap();
        assert_eq!(h, "github.com");
        assert_eq!(o, "rust-lang");
        assert_eq!(r, "rust");
    }

    #[test]
    fn parse_https_with_user() {
        let (h, o, r) = parse_remote("https://user@gitlab.com/group/proj.git").unwrap();
        assert_eq!(h, "gitlab.com");
        assert_eq!(o, "group");
        assert_eq!(r, "proj");
    }
}
