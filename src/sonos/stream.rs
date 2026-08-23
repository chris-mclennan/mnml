// 2026-08-22 — everything in this file except `Session::start`'s
// non-macOS Err-stub is macOS-only. On Linux + Windows CI those
// helpers become dead code and clippy `-D warnings` fails the run
// (broke `main` overnight on 32613577355). Silence dead_code on
// non-macOS builds file-wide rather than sprinkle 7 attrs.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

//! Sending *this Mac's* audio to a Sonos, without AirPlay.
//!
//! macOS 26 has no programmatic way to pick an AirPlay target: the
//! Sound settings pane lists only CoreAudio devices, and Control
//! Center — the sole AirPlay picker — exposes an empty accessibility
//! tree, so it can be neither scripted nor inspected. A Sonos does
//! however play any HTTP audio stream on command, and mnml can be that
//! server:
//!
//! ```text
//!   system output ─▶ loopback device ─▶ ffmpeg (mp3) ─▶ mnml HTTP ─▶ Sonos
//! ```
//!
//! The loopback device is the one piece macOS won't provide: capturing
//! system output needs either a virtual audio driver (BlackHole) or
//! ScreenCaptureKit. BlackHole is a one-time install and needs no
//! Screen Recording grant, so it's the path taken here.
//!
//! Trade-off, stated plainly: the Sonos buffers a couple of seconds, so
//! this is right for music and wrong for anything you're watching.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Substring identifying the loopback output device. Matches
/// "BlackHole 2ch" and "BlackHole 16ch" alike.
pub const LOOPBACK_NAME: &str = "blackhole";

/// What to tell the user when the loopback driver is missing. Carried
/// here so the toast, the hover help and the manual can't drift.
pub const INSTALL_HINT: &str =
    "install the loopback driver first: brew install --cask blackhole-2ch";

/// mp3 bitrate for the stream. 256k is transparent enough for a
/// speaker and small enough to never trouble a LAN.
const BITRATE: &str = "256k";

/// A running stream: the HTTP server, its ffmpeg children, and the
/// output device to hand back when it stops.
pub struct Session {
    /// Port the local HTTP server is listening on.
    port: u16,
    /// This Mac's address on the interface that reaches the player.
    host_ip: String,
    /// Set on [`Session::stop`]; every thread watches it.
    shutdown: Arc<AtomicBool>,
    /// ffmpeg processes, one per connected client, killed on stop.
    children: Arc<Mutex<Vec<Child>>>,
    /// Output device to restore, so stopping the stream gives the user
    /// their speakers back without a trip to System Settings.
    previous_output: Option<u32>,
}

impl Session {
    /// The URI to hand the player. The `x-rincon-mp3radio://` scheme is
    /// what tells Sonos to treat it as a live stream rather than a file.
    pub fn sonos_uri(&self) -> String {
        format!(
            "x-rincon-mp3radio://{}:{}/mnml.mp3",
            self.host_ip, self.port
        )
    }

    /// False once [`Session::stop`] has run.
    pub fn is_alive(&self) -> bool {
        !self.shutdown.load(Ordering::Relaxed)
    }

    /// Stop streaming: close the server, kill the encoders, and put the
    /// system output back where it was.
    pub fn stop(self) {
        self.shutdown.store(true, Ordering::Relaxed);
        // Unblock the accept loop so the server thread can notice the
        // shutdown flag and exit.
        let _ = TcpStream::connect(("127.0.0.1", self.port));
        if let Ok(mut children) = self.children.lock() {
            for mut child in children.drain(..) {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        #[cfg(target_os = "macos")]
        if let Some(id) = self.previous_output {
            let _ = super::coreaudio::set_default_output(id);
        }
    }

    /// Start capturing and serving. `player_host` is the Sonos, used
    /// only to work out which local interface it will reach us on.
    #[cfg(target_os = "macos")]
    pub fn start(_room: &str, player_host: &str) -> Result<Self, String> {
        let device = super::coreaudio::find_output(LOOPBACK_NAME)
            .ok_or_else(|| format!("no loopback audio device found — {INSTALL_HINT}"))?;
        let ffmpeg = ffmpeg_bin().ok_or("ffmpeg not found on PATH")?;
        let index = avfoundation_index(&ffmpeg, &device.name)?;
        let host_ip = local_ip_towards(player_host)
            .ok_or("could not work out this Mac's address on the network")?;
        let listener = TcpListener::bind(("0.0.0.0", 0))
            .map_err(|e| format!("could not open a local stream port: {e}"))?;
        let port = listener
            .local_addr()
            .map_err(|e| format!("could not read the stream port: {e}"))?
            .port();

        // Switch the system output *after* everything else has
        // succeeded, so a failed start never leaves the Mac silent.
        let previous_output = super::coreaudio::default_output().map(|d| d.id);
        super::coreaudio::set_default_output(device.id)?;

        let shutdown = Arc::new(AtomicBool::new(false));
        let children: Arc<Mutex<Vec<Child>>> = Arc::new(Mutex::new(Vec::new()));
        serve(listener, ffmpeg, index, shutdown.clone(), children.clone());
        Ok(Session {
            port,
            host_ip,
            shutdown,
            children,
            previous_output,
        })
    }

    /// Non-macOS builds compile but decline: the capture half is
    /// CoreAudio-specific.
    #[cfg(not(target_os = "macos"))]
    pub fn start(_room: &str, _player_host: &str) -> Result<Self, String> {
        Err("streaming this Mac's audio to a Sonos is macOS-only today".to_string())
    }
}

/// Accept connections and stream mp3 to each, one encoder per client.
///
/// A fresh ffmpeg per connection is deliberate: Sonos reconnects when
/// it re-buffers, and a per-client encoder makes that a no-op instead
/// of a shared-pipe ownership problem.
fn serve(
    listener: TcpListener,
    ffmpeg: PathBuf,
    index: String,
    shutdown: Arc<AtomicBool>,
    children: Arc<Mutex<Vec<Child>>>,
) {
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            if shutdown.load(Ordering::Relaxed) {
                break;
            }
            let Ok(conn) = conn else { continue };
            let (ffmpeg, index) = (ffmpeg.clone(), index.clone());
            let (shutdown, children) = (shutdown.clone(), children.clone());
            std::thread::spawn(move || {
                pump(conn, &ffmpeg, &index, &shutdown, &children);
            });
        }
    });
}

/// Serve one client: read (and discard) its request, write stream
/// headers, then copy encoder output until either side gives up.
fn pump(
    mut conn: TcpStream,
    ffmpeg: &PathBuf,
    index: &str,
    shutdown: &Arc<AtomicBool>,
    children: &Arc<Mutex<Vec<Child>>>,
) {
    // Drain the request line/headers. Sonos sends a normal GET; we
    // don't route on it, but leaving it unread can wedge the socket.
    let mut scratch = [0u8; 1024];
    let _ = conn.read(&mut scratch);
    // HTTP/1.0 + no Content-Length is the classic shoutcast shape: an
    // endless body the client reads until close.
    let headers = "HTTP/1.0 200 OK\r\n\
Content-Type: audio/mpeg\r\n\
Cache-Control: no-cache, no-store\r\n\
icy-name: mnml — this Mac\r\n\
Connection: close\r\n\r\n";
    if conn.write_all(headers.as_bytes()).is_err() {
        return;
    }
    let Ok(mut child) = Command::new(ffmpeg)
        .args(encoder_args(index))
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn()
    else {
        return;
    };
    let Some(mut out) = child.stdout.take() else {
        let _ = child.kill();
        return;
    };
    // Registered so `stop` can kill an encoder mid-copy; the id lets
    // this handler find its own child again when the client hangs up.
    let child_id = child.id();
    if let Ok(mut guard) = children.lock() {
        guard.push(child);
    }
    let mut buf = [0u8; 8192];
    while !shutdown.load(Ordering::Relaxed) {
        match out.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if conn.write_all(&buf[..n]).is_err() {
                    break; // player hung up
                }
            }
            Err(_) => break,
        }
    }
    // The client is gone (or we're shutting down) — kill *this* encoder
    // rather than leaving an ffmpeg capturing audio into a dead socket.
    // Other clients' encoders stay running.
    if let Ok(mut guard) = children.lock()
        && let Some(pos) = guard.iter().position(|c| c.id() == child_id)
    {
        let mut child = guard.remove(pos);
        let _ = child.kill();
        let _ = child.wait();
    }
}

/// ffmpeg arguments: capture the loopback device, encode mp3, write to
/// stdout as fast as frames are produced.
fn encoder_args(index: &str) -> Vec<String> {
    vec![
        "-hide_banner".into(),
        "-loglevel".into(),
        "error".into(),
        "-f".into(),
        "avfoundation".into(),
        // Audio-only capture: the empty video slot before the colon.
        "-i".into(),
        format!(":{index}"),
        "-ac".into(),
        "2".into(),
        "-ar".into(),
        "44100".into(),
        "-c:a".into(),
        "libmp3lame".into(),
        "-b:a".into(),
        BITRATE.into(),
        // Flush every packet — buffering here would add to the delay
        // the Sonos already introduces.
        "-flush_packets".into(),
        "1".into(),
        "-f".into(),
        "mp3".into(),
        "pipe:1".into(),
    ]
}

/// Locate ffmpeg: `PATH` first, then the usual Homebrew prefixes (a
/// GUI-launched mnml can inherit a minimal `PATH`).
fn ffmpeg_bin() -> Option<PathBuf> {
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let candidate = dir.join("ffmpeg");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .iter()
        .map(PathBuf::from)
        .find(|p| p.is_file())
}

/// Find the avfoundation *input index* for `device_name`.
///
/// ffmpeg indexes capture devices in its own order, unrelated to
/// CoreAudio ids, and only prints the mapping — so this parses the
/// listing. `-list_devices` exits non-zero by design; the listing is on
/// stderr either way.
fn avfoundation_index(ffmpeg: &PathBuf, device_name: &str) -> Result<String, String> {
    let out = Command::new(ffmpeg)
        .args([
            "-hide_banner",
            "-f",
            "avfoundation",
            "-list_devices",
            "true",
            "-i",
            "",
        ])
        .output()
        .map_err(|e| format!("could not run ffmpeg: {e}"))?;
    let listing = String::from_utf8_lossy(&out.stderr);
    parse_avfoundation_index(&listing, device_name)
        .ok_or_else(|| format!("ffmpeg cannot see the '{device_name}' input device"))
}

/// Pull `[N] <name>` out of ffmpeg's device listing, restricted to the
/// audio section (video devices are indexed separately and can collide).
fn parse_avfoundation_index(listing: &str, device_name: &str) -> Option<String> {
    let needle = device_name.to_ascii_lowercase();
    let mut in_audio = false;
    for line in listing.lines() {
        let lower = line.to_ascii_lowercase();
        if lower.contains("audio devices:") {
            in_audio = true;
            continue;
        }
        if lower.contains("video devices:") {
            in_audio = false;
            continue;
        }
        if !in_audio {
            continue;
        }
        // `[AVFoundation indev @ 0x…] [1] BlackHole 2ch`
        let Some(open) = line.rfind('[') else {
            continue;
        };
        let Some(close) = line[open..].find(']').map(|i| i + open) else {
            continue;
        };
        let index = line[open + 1..close].trim();
        if !index.chars().all(|c| c.is_ascii_digit()) || index.is_empty() {
            continue;
        }
        if line[close + 1..]
            .trim()
            .to_ascii_lowercase()
            .contains(&needle)
        {
            return Some(index.to_string());
        }
    }
    None
}

/// This Mac's IP on the interface that routes to `host`.
///
/// No packets are sent — connecting a UDP socket only picks a route,
/// which is exactly the question being asked.
fn local_ip_towards(host: &str) -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect((host, super::soap::PORT)).ok()?;
    Some(socket.local_addr().ok()?.ip().to_string())
}

/// Minimal DIDL-Lite so the Sonos app shows a sensible title for the
/// stream instead of a bare URL.
pub fn didl(room: &str) -> String {
    let title = super::soap::escape(&format!("mnml — this Mac → {room}"));
    format!(
        "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" \
xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" \
xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">\
<item id=\"-1\" parentID=\"-1\" restricted=\"true\">\
<dc:title>{title}</dc:title>\
<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
</item></DIDL-Lite>"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim shape of ffmpeg's listing on macOS.
    const LISTING: &str = "\
[AVFoundation indev @ 0x14f704080] AVFoundation video devices:
[AVFoundation indev @ 0x14f704080] [0] FaceTime HD Camera
[AVFoundation indev @ 0x14f704080] [1] Capture screen 0
[AVFoundation indev @ 0x14f704080] AVFoundation audio devices:
[AVFoundation indev @ 0x14f704080] [0] MacBook Pro Microphone
[AVFoundation indev @ 0x14f704080] [1] BlackHole 2ch
";

    #[test]
    fn finds_the_loopback_input_index() {
        assert_eq!(
            parse_avfoundation_index(LISTING, "BlackHole 2ch").as_deref(),
            Some("1")
        );
    }

    #[test]
    fn ignores_the_video_section_when_indexes_collide() {
        // "[1] Capture screen 0" is video index 1; a name-only match
        // that ignored sections could return it.
        assert_eq!(
            parse_avfoundation_index(LISTING, "MacBook Pro Microphone").as_deref(),
            Some("0")
        );
        assert!(parse_avfoundation_index(LISTING, "FaceTime HD Camera").is_none());
    }

    #[test]
    fn missing_device_is_none_not_a_guess() {
        assert!(parse_avfoundation_index(LISTING, "Loopback Audio").is_none());
        assert!(parse_avfoundation_index("", "BlackHole 2ch").is_none());
    }

    #[test]
    fn encoder_args_capture_audio_only_and_stream_to_stdout() {
        let args = encoder_args("1");
        assert!(args.contains(&":1".to_string()), "audio-only input spec");
        assert!(args.contains(&"pipe:1".to_string()));
        assert_eq!(args.last().unwrap(), "pipe:1");
        assert!(args.windows(2).any(|w| w[0] == "-f" && w[1] == "mp3"));
    }

    #[test]
    fn didl_escapes_the_room_name() {
        let d = didl("Kids' <Room>");
        assert!(d.contains("Kids&apos; &lt;Room&gt;"));
        assert!(d.contains("audioBroadcast"));
    }

    #[test]
    fn install_hint_names_the_actual_formula() {
        assert!(INSTALL_HINT.contains("blackhole-2ch"));
    }
}
