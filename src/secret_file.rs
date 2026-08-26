//! Owner-only (0600) file writes for anything carrying a credential.
//!
//! mnml writes several files that contain, or can contain, secrets:
//! integration `[auth_values]` tokens, the cookie jar, HTTP request
//! history (resolved `Authorization` headers), agent transcripts
//! (verbatim shell commands), and the IPC channel's screen dump. All of
//! them went out at the process umask — 0644 on a stock macOS or Linux
//! box — so any local user or process could read them.
//!
//! The 0600 pattern already existed and was correct in `ai_usage.rs`;
//! this module generalises it so every secret-bearing write site can
//! share one audited implementation instead of re-deriving it.
//!
//! ## Why not just `set_permissions` after `fs::write`
//!
//! Create-then-chmod leaves the file readable for the window between
//! the two syscalls. Opening with `.mode(0o600)` closes that window for
//! newly-created files.
//!
//! But `.mode()` applies ONLY at creation: an existing 0644 file keeps
//! 0644, and open-with-mode silently does nothing. That's the case that
//! matters most in practice — everyone running mnml today already has
//! these files on disk, world-readable. So [`write_secret`] does both:
//! opens with 0600 (no window for new files) and, when the file already
//! existed, explicitly tightens it. The tighten introduces no new
//! exposure — the file was already permissive.
//!
//! Windows has no umask and no POSIX mode bits; these calls degrade to
//! a plain write there, matching the pre-existing `ai_usage` behaviour.

use std::io;
use std::path::Path;

/// Ensure `path` is owner-only, whether or not it already exists.
/// No-op on non-Unix. Best-effort: a permissions failure on a file we
/// just wrote shouldn't lose the user's data.
#[cfg(unix)]
pub fn tighten(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(path)?;
    let mut perms = meta.permissions();
    if perms.mode() & 0o077 != 0 {
        perms.set_mode(0o600);
        std::fs::set_permissions(path, perms)?;
    }
    Ok(())
}

#[cfg(not(unix))]
pub fn tighten(_path: &Path) -> io::Result<()> {
    Ok(())
}

/// Write `bytes` to `path`, truncating, with owner-only permissions.
///
/// Prefer this over `std::fs::write` for anything that can carry a
/// credential.
pub fn write_secret(path: &Path, bytes: &[u8]) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        // `existed` decides whether the `.mode()` below actually
        // applied: it is honoured on create and ignored otherwise.
        let existed = path.exists();
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        f.write_all(bytes)?;
        f.flush()?;
        drop(f);
        if existed {
            // Pre-existing file kept its old (likely 0644) mode.
            let _ = tighten(path);
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, bytes)
    }
}

/// Open `path` for appending with owner-only permissions, creating it
/// if absent. For append-mode logs (HTTP history) where rewriting the
/// whole file would be wasteful.
pub fn append_secret(path: &Path) -> io::Result<std::fs::File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let existed = path.exists();
        let f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(path)?;
        if existed {
            let _ = tighten(path);
        }
        Ok(f)
    }
    #[cfg(not(unix))]
    {
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
    }
}

/// Copy `from` to `to` and make the copy owner-only.
///
/// `std::fs::copy` propagates the SOURCE's permissions, so backing up
/// an already-0600 secret is safe — but backing up one that predates
/// this module would faithfully reproduce its 0644. Tightening
/// unconditionally makes the backup safe regardless of the original.
pub fn copy_secret(from: &Path, to: &Path) -> io::Result<u64> {
    let n = std::fs::copy(from, to)?;
    let _ = tighten(to);
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn mode_of(p: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    #[test]
    #[cfg(unix)]
    fn new_file_is_owner_only() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("secret.toml");
        write_secret(&p, b"token = \"abc\"").unwrap();
        assert_eq!(mode_of(&p), 0o600);
        assert_eq!(std::fs::read(&p).unwrap(), b"token = \"abc\"");
    }

    #[test]
    #[cfg(unix)]
    fn existing_world_readable_file_is_tightened() {
        // The case `.mode()` alone misses, and the one every current
        // mnml install is actually in.
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("secret.toml");
        std::fs::write(&p, b"old").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(mode_of(&p), 0o644, "precondition");

        write_secret(&p, b"new").unwrap();
        assert_eq!(mode_of(&p), 0o600);
        assert_eq!(std::fs::read(&p).unwrap(), b"new");
    }

    #[test]
    #[cfg(unix)]
    fn append_creates_owner_only_and_tightens_existing() {
        use std::io::Write;
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("history.jsonl");

        let mut f = append_secret(&p).unwrap();
        f.write_all(b"one\n").unwrap();
        drop(f);
        assert_eq!(mode_of(&p), 0o600);

        // Simulate a file left behind by an older mnml.
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644)).unwrap();
        let mut f = append_secret(&p).unwrap();
        f.write_all(b"two\n").unwrap();
        drop(f);
        assert_eq!(mode_of(&p), 0o600);
        // Append semantics preserved — the first line is still there.
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "one\ntwo\n");
    }

    #[test]
    #[cfg(unix)]
    fn copy_tightens_even_from_a_permissive_source() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("src.toml");
        let dst = d.path().join("dst.toml");
        std::fs::write(&src, b"token").unwrap();
        std::fs::set_permissions(&src, std::fs::Permissions::from_mode(0o644)).unwrap();

        copy_secret(&src, &dst).unwrap();
        assert_eq!(mode_of(&dst), 0o600, "copy must not inherit 0644");
        assert_eq!(std::fs::read(&dst).unwrap(), b"token");
    }

    #[test]
    #[cfg(unix)]
    fn tighten_leaves_already_private_files_alone() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("s");
        write_secret(&p, b"x").unwrap();
        tighten(&p).unwrap();
        assert_eq!(mode_of(&p), 0o600);
    }
}
