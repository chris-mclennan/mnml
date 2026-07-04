# External tools

The Integrations rail launches a small catalog of terminal tools directly
into a pty pane: htop, btop, iftop, and any others added to
`src/tools.rs::EXTERNAL_TOOLS`.

## Tools that need root

`iftop` (and future additions like `tcpdump` / `dtrace`) need packet-capture
privileges. mnml launches them under `sudo`, so you'll see a password prompt
each time the pty pane starts:

```
Password:
```

## Passwordless

If you use iftop often and don't want to type your password on each launch,
add a narrow sudoers.d rule that permits **only** that one binary without a
password.

macOS (Apple Silicon Homebrew):

```
echo "$USER ALL=(root) NOPASSWD: /opt/homebrew/sbin/iftop" | \
  sudo tee /etc/sudoers.d/mnml-iftop >/dev/null && \
  sudo chmod 440 /etc/sudoers.d/mnml-iftop
```

macOS (Intel Homebrew) — replace the path with `/usr/local/sbin/iftop`.

Linux — usually `/usr/sbin/iftop`. Verify with `which iftop`.

**One password prompt now, none afterwards.** The rule is scoped to that
exact binary, so every other `sudo` command still asks for your password.
Homebrew upgrades leave the symlink alone, so the rule survives
`brew upgrade iftop`.

To undo:

```
sudo rm /etc/sudoers.d/mnml-iftop
```

## Why not a wizard inside mnml?

Because mnml editing `/etc/sudoers.d/` sets a bad precedent — sudoers is a
security control, not something a text editor should be modifying on your
behalf. If you want the rule, run the one-liner above yourself.

## Alternative: BPF group (macOS)

iftop only needs `/dev/bpf*` access, not full root. If you have Wireshark
installed you already have its `ChmodBPF` LaunchDaemon; add yourself to the
`access_bpf` group and iftop skips sudo entirely:

```
sudo dseditgroup -o edit -a "$USER" -t user access_bpf
```

Log out + back in for group membership to take effect. Then update the
launcher in `src/tools.rs` to drop `needs_sudo: true` (or configure it per
your setup).
