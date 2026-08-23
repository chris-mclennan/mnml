//! The Sonos actions themselves — transport, volume, favorites,
//! grouping — plus the metadata projection that feeds the statusline.
//!
//! Everything here is blocking HTTP and runs on the [`super::worker`]
//! thread. Commands are addressed to a *coordinator*: Sonos rejects
//! transport calls sent to a grouped follower, so callers resolve the
//! coordinator first (see [`super::Snapshot::control_host`]).

use super::soap::{self, Service};
use reqwest::blocking::Client;

/// `<InstanceID>0</InstanceID>` — every AVTransport/RenderingControl
/// call takes it, and Sonos only ever has instance 0.
const INSTANCE: &str = "<InstanceID>0</InstanceID>";

/// What the player is doing right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TransportState {
    Playing,
    Paused,
    Stopped,
    /// Mid-transition (buffering a new stream). Rendered as playing —
    /// it resolves within a poll or two and flickering the chip
    /// between glyphs reads as a bug.
    Transitioning,
    #[default]
    Unknown,
}

impl TransportState {
    /// True when audio is (or is about to be) coming out.
    pub fn is_playing(self) -> bool {
        matches!(
            self,
            TransportState::Playing | TransportState::Transitioning
        )
    }

    fn parse(s: &str) -> Self {
        match s {
            "PLAYING" => TransportState::Playing,
            "PAUSED_PLAYBACK" => TransportState::Paused,
            "STOPPED" => TransportState::Stopped,
            "TRANSITIONING" => TransportState::Transitioning,
            _ => TransportState::Unknown,
        }
    }
}

/// Where the audio is coming from, derived from the track URI scheme.
///
/// This matters for the chip's label: an AirPlay or TV source reports
/// no track metadata at all, so naming the *source* is the only honest
/// thing to show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SourceKind {
    /// The player's own queue (a service track, a library file).
    #[default]
    Queue,
    /// AirPlay from a Mac / iPhone. No metadata is exposed.
    AirPlay,
    /// TV / HDMI-ARC input on a soundbar.
    Tv,
    /// Physical line-in.
    LineIn,
    /// An internet radio stream — including the one mnml serves when
    /// it is streaming this Mac's audio.
    Stream,
    /// Following another room's group.
    Grouped,
}

impl SourceKind {
    /// Classify by URI scheme. Sonos's schemes are stable across
    /// firmware generations, which is what makes this safe.
    pub fn parse(uri: &str) -> Self {
        if uri.starts_with("x-sonos-vli:") && uri.contains("airplay") {
            SourceKind::AirPlay
        } else if uri.starts_with("x-sonos-htastream:") {
            SourceKind::Tv
        } else if uri.starts_with("x-rincon-stream:") {
            SourceKind::LineIn
        } else if uri.starts_with("x-rincon-mp3radio:") || uri.starts_with("x-rincon-stream-http") {
            SourceKind::Stream
        } else if uri.starts_with("x-rincon:") {
            SourceKind::Grouped
        } else {
            SourceKind::Queue
        }
    }

    /// Short label for the statusline when there's no track to show.
    pub fn label(self) -> &'static str {
        match self {
            SourceKind::AirPlay => "AirPlay",
            SourceKind::Tv => "TV",
            SourceKind::LineIn => "Line-in",
            SourceKind::Stream => "Stream",
            SourceKind::Grouped => "Grouped",
            SourceKind::Queue => "Queue",
        }
    }
}

/// What's loaded on the player: the projection of `GetPositionInfo`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TrackInfo {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub uri: String,
    pub source: SourceKind,
}

/// A Sonos favorite, as browsed from `FV:2`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Favorite {
    pub title: String,
    /// The playable URI.
    pub uri: String,
    /// DIDL metadata Sonos wants handed back when playing the item.
    pub metadata: String,
}

impl Favorite {
    /// True when the URI names a *container* (a playlist, album, or
    /// station list) rather than a single stream. Containers have to go
    /// through the queue; streams can be set directly.
    pub fn is_container(&self) -> bool {
        self.uri.starts_with("x-rincon-cpcontainer")
            || self.uri.starts_with("x-rincon-playlist")
            || self.uri.starts_with("file:")
    }
}

/// Sonos's "no value here" sentinel — returned for duration, position
/// and metadata on sources that don't expose them (AirPlay, TV).
const NOT_IMPLEMENTED: &str = "NOT_IMPLEMENTED";

/// Pull one DIDL-Lite field, tolerating the namespace prefix Sonos
/// uses (`dc:title`, `upnp:album`, …).
fn didl_field(didl: &str, tag: &str) -> String {
    soap::tag_text(didl, tag)
        .map(soap::unescape)
        .filter(|v| v != NOT_IMPLEMENTED)
        .unwrap_or_default()
}

/// Project a `GetPositionInfo` response into a [`TrackInfo`].
pub fn parse_position(body: &str) -> TrackInfo {
    let uri = soap::tag_text(body, "TrackURI")
        .map(soap::unescape)
        .unwrap_or_default();
    let raw_meta = soap::tag_text(body, "TrackMetaData").unwrap_or_default();
    let didl = soap::unescape(raw_meta);
    TrackInfo {
        title: didl_field(&didl, "dc:title"),
        artist: didl_field(&didl, "dc:creator"),
        album: didl_field(&didl, "upnp:album"),
        source: SourceKind::parse(&uri),
        uri,
    }
}

/// Read transport state.
pub fn transport_state(client: &Client, host: &str) -> Result<TransportState, String> {
    let body = soap::call(
        client,
        host,
        Service::AvTransport,
        "GetTransportInfo",
        INSTANCE,
    )?;
    Ok(TransportState::parse(
        soap::tag_text(&body, "CurrentTransportState").unwrap_or_default(),
    ))
}

/// Read what's loaded (title / artist / source).
pub fn position(client: &Client, host: &str) -> Result<TrackInfo, String> {
    let body = soap::call(
        client,
        host,
        Service::AvTransport,
        "GetPositionInfo",
        INSTANCE,
    )?;
    Ok(parse_position(&body))
}

/// Read `Master` volume (0-100).
pub fn volume(client: &Client, host: &str) -> Result<u8, String> {
    let body = soap::call(
        client,
        host,
        Service::Rendering,
        "GetVolume",
        &format!("{INSTANCE}<Channel>Master</Channel>"),
    )?;
    Ok(soap::tag_text(&body, "CurrentVolume")
        .and_then(|v| v.trim().parse::<u8>().ok())
        .unwrap_or(0))
}

/// Read mute state.
pub fn muted(client: &Client, host: &str) -> Result<bool, String> {
    let body = soap::call(
        client,
        host,
        Service::Rendering,
        "GetMute",
        &format!("{INSTANCE}<Channel>Master</Channel>"),
    )?;
    Ok(soap::tag_text(&body, "CurrentMute").map(str::trim) == Some("1"))
}

/// Start (or resume) playback.
pub fn play(client: &Client, host: &str) -> Result<(), String> {
    soap::call(
        client,
        host,
        Service::AvTransport,
        "Play",
        &format!("{INSTANCE}<Speed>1</Speed>"),
    )
    .map(|_| ())
}

/// Pause playback.
pub fn pause(client: &Client, host: &str) -> Result<(), String> {
    soap::call(client, host, Service::AvTransport, "Pause", INSTANCE).map(|_| ())
}

/// Next track. Fails (harmlessly) on non-skippable sources like TV.
pub fn next(client: &Client, host: &str) -> Result<(), String> {
    soap::call(client, host, Service::AvTransport, "Next", INSTANCE).map(|_| ())
}

/// Previous track.
pub fn previous(client: &Client, host: &str) -> Result<(), String> {
    soap::call(client, host, Service::AvTransport, "Previous", INSTANCE).map(|_| ())
}

/// Set absolute volume, clamped to Sonos's 0-100 range.
pub fn set_volume(client: &Client, host: &str, vol: u8) -> Result<(), String> {
    soap::call(
        client,
        host,
        Service::Rendering,
        "SetVolume",
        &format!(
            "{INSTANCE}<Channel>Master</Channel><DesiredVolume>{}</DesiredVolume>",
            vol.min(100)
        ),
    )
    .map(|_| ())
}

/// Nudge volume by `delta` (Sonos clamps at the ends itself). One call
/// instead of read-modify-write, so two quick clicks can't race.
pub fn adjust_volume(client: &Client, host: &str, delta: i16) -> Result<(), String> {
    soap::call(
        client,
        host,
        Service::Rendering,
        "SetRelativeVolume",
        &format!("{INSTANCE}<Channel>Master</Channel><Adjustment>{delta}</Adjustment>"),
    )
    .map(|_| ())
}

/// Set mute.
pub fn set_mute(client: &Client, host: &str, mute: bool) -> Result<(), String> {
    soap::call(
        client,
        host,
        Service::Rendering,
        "SetMute",
        &format!(
            "{INSTANCE}<Channel>Master</Channel><DesiredMute>{}</DesiredMute>",
            u8::from(mute)
        ),
    )
    .map(|_| ())
}

/// Point the player at `uri` and start it.
///
/// The direct path — right for a radio stream (including mnml's own
/// Mac-audio stream). Containers need [`play_favorite`].
pub fn play_uri(client: &Client, host: &str, uri: &str, metadata: &str) -> Result<(), String> {
    soap::call(
        client,
        host,
        Service::AvTransport,
        "SetAVTransportURI",
        &format!(
            "{INSTANCE}<CurrentURI>{}</CurrentURI><CurrentURIMetaData>{}</CurrentURIMetaData>",
            soap::escape(uri),
            soap::escape(metadata)
        ),
    )?;
    play(client, host)
}

/// Play a favorite, routing containers through the queue the way the
/// Sonos app does (clear queue → enqueue → point transport at the
/// queue → play).
pub fn play_favorite(
    client: &Client,
    host: &str,
    uuid: &str,
    fav: &Favorite,
) -> Result<(), String> {
    if !fav.is_container() {
        return play_uri(client, host, &fav.uri, &fav.metadata);
    }
    soap::call(
        client,
        host,
        Service::AvTransport,
        "RemoveAllTracksFromQueue",
        INSTANCE,
    )?;
    soap::call(
        client,
        host,
        Service::AvTransport,
        "AddURIToQueue",
        &format!(
            "{INSTANCE}<EnqueuedURI>{}</EnqueuedURI><EnqueuedURIMetaData>{}</EnqueuedURIMetaData>\
<DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>1</EnqueueAsNext>",
            soap::escape(&fav.uri),
            soap::escape(&fav.metadata)
        ),
    )?;
    play_uri(client, host, &format!("x-rincon-queue:{uuid}#0"), "")
}

/// Make `follower_host` join the group led by `coordinator_uuid`.
pub fn join(client: &Client, follower_host: &str, coordinator_uuid: &str) -> Result<(), String> {
    play_uri(
        client,
        follower_host,
        &format!("x-rincon:{coordinator_uuid}"),
        "",
    )
}

/// Drop a player out of its group, back to standalone.
pub fn unjoin(client: &Client, host: &str) -> Result<(), String> {
    soap::call(
        client,
        host,
        Service::AvTransport,
        "BecomeCoordinatorOfStandaloneGroup",
        INSTANCE,
    )
    .map(|_| ())
}

/// Browse the player's Sonos favorites (`FV:2`).
pub fn favorites(client: &Client, host: &str) -> Result<Vec<Favorite>, String> {
    let body = soap::call(
        client,
        host,
        Service::ContentDirectory,
        "Browse",
        "<ObjectID>FV:2</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>\
<Filter>*</Filter><StartingIndex>0</StartingIndex><RequestedCount>100</RequestedCount>\
<SortCriteria></SortCriteria>",
    )?;
    Ok(parse_favorites(&body))
}

/// Project a `Browse` response's DIDL into favorites.
pub fn parse_favorites(body: &str) -> Vec<Favorite> {
    let didl = soap::unescape(soap::tag_text(body, "Result").unwrap_or(body));
    let mut out = Vec::new();
    // Items are `<item …>…</item>`; split on the open tag and read each
    // chunk's fields. `res` is the playable URI, `r:resMD` the metadata
    // Sonos wants echoed back.
    for chunk in didl.split("<item ").skip(1) {
        let title = didl_field(chunk, "dc:title");
        let uri = didl_field(chunk, "res");
        if title.is_empty() || uri.is_empty() {
            continue;
        }
        out.push(Favorite {
            title,
            uri,
            metadata: didl_field(chunk, "r:resMD"),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transport_states_map_from_the_wire() {
        assert_eq!(TransportState::parse("PLAYING"), TransportState::Playing);
        assert_eq!(
            TransportState::parse("PAUSED_PLAYBACK"),
            TransportState::Paused
        );
        assert_eq!(TransportState::parse("weird"), TransportState::Unknown);
        assert!(TransportState::Transitioning.is_playing());
        assert!(!TransportState::Paused.is_playing());
    }

    #[test]
    fn source_kind_classifies_sonos_uri_schemes() {
        assert_eq!(
            SourceKind::parse("x-sonos-vli:RINCON_X:1,airplay:311e2b"),
            SourceKind::AirPlay
        );
        assert_eq!(
            SourceKind::parse("x-sonos-htastream:RINCON_X:spdif"),
            SourceKind::Tv
        );
        assert_eq!(
            SourceKind::parse("x-rincon-mp3radio://192.168.1.9:9123/live.mp3"),
            SourceKind::Stream
        );
        assert_eq!(SourceKind::parse("x-rincon:RINCON_Y"), SourceKind::Grouped);
        assert_eq!(
            SourceKind::parse("x-sonos-http:track%3a123.mp4"),
            SourceKind::Queue
        );
    }

    #[test]
    fn parses_a_queue_track_with_metadata() {
        let body = "<u:GetPositionInfoResponse><TrackURI>x-sonos-http:track123.mp4</TrackURI>\
<TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Windowlicker&lt;/dc:title&gt;\
&lt;dc:creator&gt;Aphex Twin&lt;/dc:creator&gt;&lt;upnp:album&gt;Windowlicker&lt;/upnp:album&gt;\
&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData></u:GetPositionInfoResponse>";
        let t = parse_position(body);
        assert_eq!(t.title, "Windowlicker");
        assert_eq!(t.artist, "Aphex Twin");
        assert_eq!(t.source, SourceKind::Queue);
    }

    #[test]
    fn airplay_source_reports_no_metadata_not_a_bogus_title() {
        // Verbatim shape from a real AirPlay session — Sonos exposes
        // nothing but the sentinel, so the chip must fall back to the
        // source label instead of showing "NOT_IMPLEMENTED".
        let body = "<u:GetPositionInfoResponse><TrackURI>x-sonos-vli:RINCON_C43:1,airplay:311e</TrackURI>\
<TrackMetaData>NOT_IMPLEMENTED</TrackMetaData></u:GetPositionInfoResponse>";
        let t = parse_position(body);
        assert_eq!(t.source, SourceKind::AirPlay);
        assert!(t.title.is_empty(), "sentinel must not leak into the label");
        assert_eq!(t.source.label(), "AirPlay");
    }

    #[test]
    fn parses_favorites_and_flags_containers() {
        let didl = "&lt;DIDL-Lite&gt;\
&lt;item id=\"FV:2/1\"&gt;&lt;dc:title&gt;Radio Paradise&lt;/dc:title&gt;\
&lt;res&gt;x-rincon-mp3radio://stream.radioparadise.com/mp3-192&lt;/res&gt;&lt;/item&gt;\
&lt;item id=\"FV:2/2\"&gt;&lt;dc:title&gt;Deep House&lt;/dc:title&gt;\
&lt;res&gt;x-rincon-cpcontainer:1006206c&lt;/res&gt;&lt;r:resMD&gt;meta&lt;/r:resMD&gt;&lt;/item&gt;\
&lt;/DIDL-Lite&gt;";
        let favs = parse_favorites(&format!("<Result>{didl}</Result>"));
        assert_eq!(favs.len(), 2);
        assert_eq!(favs[0].title, "Radio Paradise");
        assert!(!favs[0].is_container(), "a radio stream plays directly");
        assert!(favs[1].is_container(), "a cpcontainer goes via the queue");
        assert_eq!(favs[1].metadata, "meta");
    }

    #[test]
    fn favorites_skip_entries_missing_a_uri() {
        let didl = "&lt;item id=\"FV:2/9\"&gt;&lt;dc:title&gt;Broken&lt;/dc:title&gt;&lt;/item&gt;";
        assert!(parse_favorites(&format!("<Result>{didl}</Result>")).is_empty());
    }
}
