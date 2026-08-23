---
title: Sonos
description: A statusline speaker chip that controls your Sonos over its local API — and two ways to get this Mac's audio onto it, because macOS won't let an app pick an AirPlay target.
---

Sonos speakers run an open UPnP server on port 1400. No account, no cloud round-trip, no vendor SDK — transport, volume, favorites and grouping are all a plain HTTP POST away on your own network. mnml uses that to put a speaker chip on the statusline:

```
 󰓃          ← that's it. Same width, always.
```

The cluster is one chip wide and stays that way. The right lane is right-aligned, so anything that changes the chip's width slides every chip beside it — and doing that on hover reads as the strip twitching whenever the mouse crosses it. Room, track, volume and state live in the hover tooltip and the Info View panel instead, both of which draw *above* the statusline and move nothing.

The colour carries the state at a glance: **teal** while mnml is streaming this Mac's audio there, **white** while the speaker is playing something, **dim** while it's idle.

If you'd rather have the detail inline, `[sonos] chip_label` opts in:

| Value | Behaviour |
|---|---|
| `"never"` | Default. One chip, constant width. |
| `"hover"` | Grows `⏸ ⏭ Room · Track` while the pointer is on the cluster. Expansion grows *leftward* — the lane is right-aligned, so a pointer inside the cluster stays inside it. Growing rightward would shove the hovered chip out from under the cursor and oscillate. |
| `"always"` | Pins the full row open at a constant width. |

Note what the expanded form adds: the speaker's *own* play/pause. That is not a duplicate of the music cluster's transport one chip away — that one drives the **player** (mixr / Music / Spotify), this one drives the **speaker**, which is the only control that does anything when the Sonos is playing its own source (radio, TV, Spotify Connect) with no Mac player in the picture. Collapsed, the right-click menu is where it lives.

Four click targets in one cluster:

| Target | Click | Right-click |
|---|---|---|
| `󰓃` speaker | Send this Mac's audio to the room (toggle) | The full menu (below) |
| `⏸` / `▶` | Play / pause the room | The full menu |
| `⏭` | Next track | The full menu |
| `Room · Track` | Pick a room | The full menu |

The transport, skip and label targets exist only when `chip_label` expands the cluster; by default the speaker chip and the right-click menu are the whole surface. The skip glyph is additionally only drawn for a **queue**. A TV, line-in, AirPlay or radio source has nothing to skip to, so the button is left out rather than drawn and dead.

## What needs a Sonos, and what doesn't

Three separate capabilities live here, and only two of them need a Sonos:

| Capability | Needs a Sonos? |
|---|---|
| The chip — transport, volume, favorites, rooms, grouping | **Yes.** It speaks Sonos's own port-1400 UPnP API. |
| `audio.airplay_music` — hand Music.app to an AirPlay destination | **No.** Any AirPlay receiver Music.app can see: an Apple TV, a HomePod, an AirPlay TV, another Mac. |
| Streaming this Mac's audio | **Yes.** It works by telling a speaker to fetch a URL, which Sonos does and a plain AirPlay receiver does not. |

So the AirPlay hand-off is genuinely general-purpose; the rest is Sonos.

## Finding your speakers

On launch mnml sends one SSDP `M-SEARCH` broadcast for `ZonePlayer` devices, then asks whichever player answers for the household topology. That single answer names every room, which player coordinates which group, and which members are *satellites* — a bonded Sub or surround pair. Satellites are real devices but not places you can play to, so they never appear as rooms.

If nothing answers, the chip renders nothing at all. A machine with no Sonos on the network sees no dead furniture, and discovery retries quietly on a slow cadence, so plugging a speaker in later doesn't need a restart.

Some networks filter multicast (guest VLANs, a few mesh routers). Pin a player directly and SSDP is skipped:

```toml
[sonos]
host = "192.168.1.131"
```

## Getting this Mac's audio onto the speaker

This is the part macOS makes awkward, so it's worth being precise about why there are two mechanisms.

**macOS 26 exposes no API for choosing a system AirPlay output.** System Settings → Sound → Output lists only CoreAudio devices, and an AirPlay target isn't one until it's already connected. Control Center is the only AirPlay picker on the machine, and its accessibility tree is empty — it can be neither scripted nor inspected. So mnml routes around it two ways.

### Music.app → real AirPlay

Music.app has its own scriptable AirPlay device list, and it can be *set*. When Music.app is what's playing, clicking the speaker chip hands it straight over:

- Real AirPlay — no transcoding, no added latency, correct metadata on the speaker.
- Works cold. The target doesn't need to be connected first.
- Moves **Music.app's** audio only. Spotify, browsers and mixr keep playing wherever the system output points.

`audio.airplay_music` opens a picker over every destination Music.app can see — and it is deliberately **not** Sonos-specific. An Apple TV, a HomePod, an AirPlay television, another Mac: if Music.app lists it, this sends to it, with or without a Sonos anywhere on the network.

### Everything else → a local stream

For any other source, mnml becomes a radio station the Sonos tunes into:

```
system output ─▶ loopback device ─▶ ffmpeg (mp3) ─▶ mnml HTTP ─▶ Sonos
```

mnml points the system output at a loopback device, encodes that to mp3, serves it on an ephemeral local port, and tells the speaker to play the URL. Stopping the stream kills the encoder and hands your output device back, so you don't end up in System Settings wondering where the sound went.

Two things this needs:

- **ffmpeg** on `PATH` (`brew install ffmpeg`).
- **A loopback device.** Capturing system output is the one piece macOS won't provide. Install BlackHole once: `brew install --cask blackhole-2ch`. mnml matches any output device whose name contains "BlackHole", so the 2ch and 16ch builds both work.

And one trade-off, stated plainly: the Sonos buffers a couple of seconds. This is right for music and wrong for anything you're watching.

If mnml is killed while streaming, the output device is left pointing at the loopback and your Mac appears to have gone silent — nothing else on the machine explains that, so `audio.restore_output` puts it back on the built-in speakers, and the chip's right-click menu grows a **Put my audio back on this Mac** row whenever the output is parked on a loopback device.

:::note
ScreenCaptureKit can capture system audio without a driver on macOS 13+, at the cost of a Screen Recording grant. That's a cleaner path and a candidate for later; today the loopback device is what's wired up.
:::

## The right-click menu

Right-clicking anywhere on the cluster opens everything the chip can do, titled with the current room. The first row is a status read-out rather than an action:

```
Living Room
  sonos: Living Room — Burial — Archangel (playing) · vol 31
  Send this Mac's audio here
  Send Music.app here (AirPlay)…
  Pause
  Next track
  Previous track
  Volume + (now 31)
  Volume −
  Mute
  Favorites…
  Room…
  Group all rooms here
  Ungroup this room
  Copy what's playing
  Re-scan for speakers
  Hide chip
```

Room and grouping rows only appear in a household with more than one room.

## Rooms, groups and coordinators

Sonos refuses transport commands aimed at a speaker that's following another one, so mnml always sends them to the group's **coordinator**. Play/pause on a grouped room therefore controls the whole group, which is what you meant.

Volume is different: each speaker keeps its own level inside a group, so volume and mute are read from and written to the room named on the chip.

Picking a room with `sonos.rooms` (or a click on the label) also persists it, so the next launch starts where you left off.

## Favorites

`sonos.favorites` plays a Sonos favorite. Browsing the favorites list costs a round-trip, so the poll loop never does it speculatively — the first invocation loads the list and the second opens the picker. `sonos.reload_favorites` refreshes it.

Favorites come in two shapes and mnml handles both the way the Sonos app does: a single stream is set directly on the transport, while a container (a playlist, album or station list) clears the queue, enqueues, and points the transport at the queue.

## Palette commands

| Command | What it does |
|---|---|
| `sonos.play_pause` | Play / pause the active room |
| `sonos.next` / `sonos.previous` | Skip forward / back |
| `sonos.volume_up` / `sonos.volume_down` | ±5, clamped by the speaker |
| `sonos.mute` | Toggle mute |
| `sonos.rooms` | Pick a room (and remember it) |
| `sonos.favorites` | Play a Sonos favorite |
| `sonos.reload_favorites` | Re-browse the favorites list |
| `sonos.group_all` | Group every room onto this one |
| `sonos.ungroup` | Drop this room out of its group |
| `sonos.stream_mac_audio` | Send this Mac's audio to the speaker (toggle) |
| `audio.airplay_music` | Send Music.app to any AirPlay destination (no Sonos needed) |
| `audio.restore_output` | Put the system output back on the Mac's speakers |
| `sonos.copy_track` | Copy what's playing to the clipboard |
| `sonos.status` | Toast room / track / volume |
| `sonos.refresh` | Re-scan the network |
| `sonos.hide` | Hide the chip |

## Config

```toml
[sonos]
enabled = true            # master switch for the chip
host = "192.168.1.131"    # skip SSDP and talk to this player
room = "Living Room"      # which room to start on
poll_secs = 3             # transport refresh cadence (1-60)
chip_label = "never"      # room · track inline: never | hover | always
prefer_airplay = true     # Music.app → AirPlay, not the stream
```

`:set sonos` / `:set nosonos` / `:set sonos!` toggle the chip at runtime and persist the choice. The Settings overlay (`:settings`) carries the same two switches under a **Sonos** section.

## Nothing blocks a frame

Every network call happens on a worker thread. The render loop only reads the latest snapshot off a channel and pushes commands down another, so a sleeping speaker, a re-addressed player or a filtered network costs a toast — never a stalled frame. A player that stops answering drops the household and discovery starts again on its own.

Headless mode and the `.test` E2E runner deliberately never start the worker, so no SSDP broadcast or HTTP traffic happens in tests.
