---
title: Now-playing & transport
description: The bottom statusline's three-segment now-playing cluster — source-aware transport for mixr / Apple Music / Spotify, the preferred-music-app knob, and the mixr panel size chips.
---

The bottom statusline carries a small now-playing miniplayer on its right side. What looks like one chip is actually three concerns folded into the same surface: a **display** of what's playing right now, a **transport** (play/pause + skip) you can drive from a mouse click, and an entry point that **launches** or **fronts** whichever music app you're using.

It's deliberately the only such surface — mnml shows what an external player is doing, it doesn't bundle one. The data layer is pluggable (one source today is the sibling [mixr](https://mixr.sh) DJ app; two more are macOS Music and Spotify via AppleScript), and adding another is one sub-module plus one arm in `now_playing::poll`.

## Anatomy

When *anything* is playing — or just has a track loaded — the chip splits into three adjacent powerline segments on the right side of the statusline, immediately to the left of the LSP / clock / workspace cluster:

```
… [▶ / ⏸]  [⏭]  [Artist - Title]  LSP 4   14:22   ~/projects/mnml   rust
```

| Segment | Glyph | Action |
|---|---|---|
| Play / pause | `\u{f04b}` (play) when paused, `\u{f04c}` (pause) when playing | Source-aware toggle |
| Fast-forward | `\u{f051}` (step-forward) | Source-aware "skip" |
| Track text | — | Source-aware "activate the app" |

The glyphs are nerd-font codepoints, not raw Unicode `▶ / ⏸ / ⏭`. The 2026-06-17 reapply commit pinned them after a user-side font-fallback chain rendered the bare Unicode codepoints as invisible glyphs. The chip stays the same purple-on-`bg2` while paused so it doesn't look dim or disabled.

Each segment is its own click rect — registered into `app.rects.statusline_mixr_play_chip`, `statusline_mixr_ffwd_chip`, and `statusline_mixr_chip` respectively — so the click dispatcher in `tui.rs` can route each separately. Adjacent segments share the same background so the powerline `` arrows collapse and the cluster reads as one unit.

When nothing has been seen playing from any source, the cluster collapses to a single idle chip — `♪ mixr`, `♪ music`, or `♪ spotify` depending on your preferred app. The idle chip is grey (`theme::comment` on `bg2`) so it sits visually below the active form.

### Track text

The track-text segment caps at **28 characters** plus an ellipsis. For mixr, `np.track` already bakes "Artist - Title" into one string (`np.detail` is the bpm, not the artist). For macOS sources, the title lives in `np.track` and the artist in `np.detail` — they're joined as `Artist - Title` so the chip surfaces both. Whitespace is collapsed before truncation so a mid-string newline can't cut the chip short.

## Source-aware dispatch

The same three clicks behave differently depending on which player is currently feeding `app.now_playing`. The router reads `np.source` (the string the poller wrote) and forks:

| Source | Play / pause | Ffwd | Track text |
|---|---|---|---|
| `mixr` | `mixr --command pause` (IPC) | `mixr --command teleport` | `mixr.show` (cycle the docked panel) |
| `Music` | `osascript` — `tell application "Music" to playpause` | `tell application "Music" to next track` | `tell application "Music" to activate` |
| `Spotify` | `tell application "Spotify" to playpause` | `tell application "Spotify" to next track` | `tell application "Spotify" to activate` |
| *(idle)* | — | — | Activates `[ui] preferred_music_app` |

The mixr IPC route writes to `~/.mixr/command` (an atomic file write) which a running mixr instance polls. `teleport` is mixr's "jump on-beat to just before mix-out" — not literally "next track", but the equivalent affordance for a DJ-style deck.

Both routes spawn detached and swallow errors. A user without mixr installed, or without Music / Spotify running, won't get a toast complaining — the click just no-ops. That's deliberate: this is a passive chip, not a workflow surface.

### Why the macOS source is whitelisted

The AppleScript helper looks like this:

```rust
fn send_macos_player(app_name: &str, verb: &str) {
    let app = match app_name {
        s if s.eq_ignore_ascii_case("Music") => "Music",
        s if s.eq_ignore_ascii_case("Spotify") => "Spotify",
        _ => return,
    };
    let script = format!("tell application \"{app}\" to {verb}");
    // osascript -e <script>
}
```

The whitelist is a security boundary — `np.source` is set by the poller, but it's a `String` and conceivably a malformed snapshot could write anything into it. Treating it as untrusted means a bogus value can't smuggle arbitrary AppleScript into the `osascript -e` argv. Adding a new macOS source (e.g. Tidal, if its AppleScript dictionary supports it) is one match-arm plus one source sub-module.

## Source detection

Source picking is driven by `[ui] now_playing_source` (`"auto"` — default — / `"mixr"` / `"macos"`) and runs on a background `spawn_poller` thread:

```rust
pub fn poll(source: Source) -> Option<NowPlaying> {
    match source {
        Source::Mixr => mixr::poll(),
        Source::Macos => macos::poll(),
        Source::Auto => {
            let m = mixr::poll();
            if m.as_ref().is_some_and(|n| n.playing) {
                return m;
            }
            let mac = macos::poll();
            if mac.as_ref().is_some_and(|n| n.playing) {
                return mac;
            }
            m.or(mac)
        }
    }
}
```

The poller refreshes every 3 seconds and pushes snapshots over an `mpsc` channel that `App::drain_now_playing` consumes from the event loop. The render path never touches the file system or spawns `osascript` — the only thing the statusline draw reads is the `app.now_playing: Option<NowPlaying>` field.

`Source::Auto` is biased toward mixr because a mixr read is one cheap file open (`~/.mixr/quick.txt`) and a macOS read is an `osascript` subprocess. If both report idle, the chip prefers the mixr "idle" snapshot so users who run mixr see `♪ mixr` rather than `♪ music`.

Headless and `.test` runs never spawn the poller at all — `start_now_playing_poller` is called from the real terminal loop in `tui.rs` only. The chip renders in its idle form in those contexts.

### Stickiness layer

mixr writes `quick.txt` on every render cycle. During track transitions (and during brief dips of the `playing_active` flag the deck writes between buffers), the `playing=` field is briefly empty — even though audio is still coming out of the speakers. Without stickiness, each empty read flipped `app.now_playing.track` to `""` and the chip rendered as the idle `♪ mixr` form for a poll or two, then back to the track. User-reported as rapid flicker on 2026-06-17.

The fix lives in `App::merge_now_playing` — a 10-second TTL stickiness:

- A **mixr snapshot with a non-empty track** refreshes the sticky timestamp and is returned as-is.
- A **mixr snapshot with an empty track** *within 10 s of the last good read* keeps the previous track + detail strings and returns a merged snapshot.
- Past 10 s, the empty read passes through — the chip fades to `♪ mixr` because the deck genuinely has nothing loaded.

So the chip can "incorrectly" stay on a song for up to 10 seconds after a real queue-empty event. That's deliberate. The user-visible artifact of stickiness is bounded; the artifact of *not* having it was a chip flickering once per song.

## Preferred music app

```toml
# ~/.config/mnml/config.toml
[ui]
preferred_music_app = "mixr"   # or "music" or "spotify"
```

Two effects:

- **Idle chip label**. With nothing playing, the single chip reads `♪ mixr` / `♪ music` / `♪ spotify` so users who live in a particular app see their app's name.
- **Idle click**. Clicking the idle chip launches the preferred app — `mixr.show` for `mixr` (default), `osascript activate` for the macOS ones. This lets a Spotify user tap once to bring Spotify forward, instead of always landing on the mixr panel.

When something *is* playing, the click activates the source's own app regardless of the preferred-app pick. The preferred app is the idle fallback, not an override.

The matching row sits in `:settings` under `── UI ──` as **Preferred music app** with options `mixr` / `music` / `spotify`. Editable in the overlay; the change is in-memory until you save the overlay or write the TOML file.

## Mixr panel size chips

When mixr is hosted as a native panel inside mnml (the `mixr.show` palette command, the `♪ mixr` keyboard chord, or a click on the idle chip with `preferred_music_app = "mixr"`), it occupies a regular pane with a 1-row header. The header now carries three right-aligned chips for snapping the panel between its size states:

| Chip | Target size | Visible when |
|---|---|---|
| `⤢` grow | `Full` | Always shown unless already in `Full` |
| `⤡` shrink | `BottomStrip` | Only shown from `Full` (a `BottomStrip` can't shrink further without minimizing) |
| `–` minimize | `Minimized` | Always shown while the panel is visible |

Click handlers are registered into `app.rects.mixr_size_{grow,shrink,minimize}_button` and checked **before** the drag detector in `tui.rs`. The chips sit on the header's move-drag region, so without the early check a click would start a window drag instead of firing the chip. The chips are single-cell, painted from the right edge inward with a 1-cell gap between each — a narrow header collapses chips off the left edge before it eats the title.

The `–` minimize chip drops `panel.focused = false` so the keyboard cursor returns to the editor. The `⤢` grow and `⤡` shrink chips keep focus on the panel (you stayed inside mixr; the layout just resized).

The keyboard chord still cycles `Minimized → BottomStrip → Full → Minimized` via `mixr.show`. The transport chips on the statusline still work independently — both surfaces coexist. The chip cluster is the primary mouse affordance for sizing; `mixr.show` is the primary keyboard one.

## Real-world examples

**Spotify playing in the background, mnml in the foreground.**
Auto-source picks up Spotify (mixr is idle, macOS reports Spotify is playing). The cluster shows `[⏸] [⏭] [Daft Punk - One More Time]`. Click the pause segment — `osascript playpause` fires; Spotify pauses; on the next poll the chip flips to `[▶]`. Click the track text — Spotify activates and comes to the front. mnml keeps focus (the AppleScript `activate` is non-blocking).

**Mixr deck running on the second monitor.**
mixr's poller reads `~/.mixr/quick.txt` and reports the current track + bpm. Cluster shows `[⏸] [⏭] [Artist - Title]`. Click the ffwd segment — `mixr --command teleport` jumps the deck on-beat to just before mix-out. Click the track text — `mixr.show` cycles the mixr panel into mnml as a docked `BottomStrip`. Click the panel's `–` chip in the header and the panel minimises; the statusline chip keeps reporting the deck.

**Nothing playing, you live in Spotify.**
Set `preferred_music_app = "spotify"` in `:settings`. The idle chip reads `♪ spotify`. Tap it once — Spotify launches (or activates if already running). Hit play in Spotify; on the next 3-second poll the chip becomes the three-segment cluster.

**Mixr between songs.**
The deck briefly writes an empty track field as it loads the next file. Without the stickiness layer the chip would flash `♪ mixr` for a poll cycle, then `[⏸] [⏭] [Next Track]`. With it, the cluster keeps showing the previous track until either a fresh non-empty read replaces it or 10 seconds elapse with nothing.

## Limitations

- **No system-wide now-playing.** The public macOS `MediaPlayer` / `NowPlayable` APIs are write-side only (apps publish, but third parties can't read), and the private `MediaRemote` framework was tightened in 15.4. Per-app polling stays the strategy — mixr by file, Music / Spotify by AppleScript. Players outside that list (browser tabs, VLC, IINA, Plex, …) don't surface on the chip.
- **Browser audio (YouTube, SoundCloud, …) isn't covered.** A tab playing music isn't reachable from outside the browser process. There's no general-purpose hook here without a browser extension, which mnml deliberately doesn't ship.
- **Click-outside doesn't minimise the mixr panel.** The size chips (`–`, in particular) are the explicit affordance. The panel doesn't autohide when focus moves elsewhere — mixr keeps decoding audio even when minimised.
- **No right-click context menu on the cluster** (yet). Left-click on each segment is the only mouse affordance; the keyboard equivalents are `mixr.show` and mixr's own keymap when focused.
- **Three-second poll cadence.** Pause / play state updates lag the click by up to 3 s. The click itself fires immediately — only the *displayed* glyph waits for the next poll snapshot.

## Next

- [Settings & configuration](/manual/settings/) — `now_playing_source`, `preferred_music_app`, every UI knob
- [Activity bar](/manual/activity-bar/) — the icon rail's `mixr.show` chip
- [mixr — DJ app](https://mixr.sh) — the sibling that produces `~/.mixr/quick.txt`
- [tmnl — GPU terminal](https://tmnl.sh) — the bufferline-side mixr chip mirrors this same play/pause/teleport semantic when tmnl owns a mixr Native tab
- [Coming from VS Code](/manual/coming-from-vscode/) — other VS-Code-shaped chrome
