//! Finding the Sonos household — SSDP discovery plus the zone-group
//! topology parse that turns one reachable player into the whole map.
//!
//! Two steps, because Sonos only needs one answer to give up the rest:
//! an SSDP `M-SEARCH` broadcast finds *any* player on the LAN, then
//! that player's `GetZoneGroupState` names every room, which player
//! coordinates which group, and who is merely a satellite (a Sub or a
//! surround — real devices that must never appear as rooms).

use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

use super::soap::{self, Service};

/// SSDP multicast endpoint (the UPnP standard address/port).
const SSDP_ADDR: &str = "239.255.255.250:1900";

/// Sonos's own device type. Searching for this instead of `ssdp:all`
/// keeps the reply set to players — no printers, no TVs, no Hue bridge.
const ZONE_PLAYER: &str = "urn:schemas-upnp-org:device:ZonePlayer:1";

/// How long to listen for `M-SEARCH` replies. Players answer in tens
/// of milliseconds on a quiet LAN; this is the "nothing is there"
/// ceiling, and it runs on the worker thread, never the render loop.
const DISCOVER_WINDOW: Duration = Duration::from_millis(1200);

/// One visible Sonos room.
///
/// Satellites (Sub, surrounds) are deliberately absent — they are
/// members of the household but not places you can play to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Player {
    /// Stable `RINCON_…` id. The key for every command.
    pub uuid: String,
    /// Room name as set in the Sonos app — "Living Room".
    pub room: String,
    /// IP (or hostname) to POST control requests at.
    pub host: String,
    /// `uuid` of the player coordinating this player's group. Equal to
    /// `uuid` when this player is its own coordinator. Transport
    /// commands must go to the *coordinator*, not the member.
    pub coordinator: String,
    /// True when the player advertises AirPlay 2 — the signal for
    /// whether the native-AirPlay hand-off is even possible.
    pub airplay: bool,
}

impl Player {
    /// True when this player leads its group (so it accepts transport
    /// commands directly).
    pub fn is_coordinator(&self) -> bool {
        self.uuid == self.coordinator
    }
}

/// Value of `name="…"` in a single XML element's text, or `None`.
fn attr(elem: &str, name: &str) -> Option<String> {
    let key = format!("{name}=\"");
    let start = elem.find(&key)? + key.len();
    let end = elem[start..].find('"')? + start;
    Some(elem[start..end].to_string())
}

/// Host component of a Sonos `Location` URL
/// (`http://192.168.1.131:1400/xml/device_description.xml`).
fn host_of(location: &str) -> Option<String> {
    let rest = location.strip_prefix("http://")?;
    let end = rest.find(':').or_else(|| rest.find('/'))?;
    Some(rest[..end].to_string())
}

/// Split `xml` into its top-level element strings in document order,
/// keeping only elements whose name is in `names`.
///
/// A scan rather than a parse: the zone-group document is flat enough
/// that grouping-by-most-recent-`ZoneGroup` is the entire structure we
/// need, and this keeps mnml free of an XML dependency.
fn elements<'a>(xml: &'a str, names: &[&str]) -> Vec<&'a str> {
    let mut out = Vec::new();
    let bytes = xml.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let Some(rel) = xml[i..].find('<') else { break };
        let start = i + rel;
        let Some(rel_end) = xml[start..].find('>') else {
            break;
        };
        let end = start + rel_end + 1;
        let elem = &xml[start..end];
        // `<Name` … match on the name only, so attributes don't matter.
        let name_end = elem[1..]
            .find(|c: char| c.is_whitespace() || c == '>' || c == '/')
            .map(|n| n + 1)
            .unwrap_or(elem.len());
        let name = &elem[1..name_end];
        if names.contains(&name) {
            out.push(elem);
        }
        i = end;
    }
    out
}

/// Parse a `GetZoneGroupState` response body into the visible rooms.
///
/// Handles Sonos's double-escaping (the whole zone-group document
/// arrives as escaped text inside `<ZoneGroupState>`) and drops
/// `Invisible="1"` members plus `<Satellite>` elements, which are the
/// Sub / surround speakers bonded into a room.
pub fn parse_topology(body: &str) -> Vec<Player> {
    // The payload may be nested (a real SOAP response) or already
    // unwrapped (a test fixture); unescape twice either way — the
    // second pass is a no-op on plain XML.
    let inner = soap::tag_text(body, "ZoneGroupState").unwrap_or(body);
    let doc = soap::unescape(&soap::unescape(inner));
    let mut players = Vec::new();
    let mut coordinator = String::new();
    // `Satellite` is listed so the scan *sees* it and can skip it;
    // without that it would be invisible to the loop, not excluded.
    for elem in elements(&doc, &["ZoneGroup", "ZoneGroupMember", "Satellite"]) {
        if elem.starts_with("<ZoneGroup ") || elem.starts_with("<ZoneGroup>") {
            coordinator = attr(elem, "Coordinator").unwrap_or_default();
            continue;
        }
        if elem.starts_with("<Satellite") {
            continue;
        }
        if attr(elem, "Invisible").as_deref() == Some("1") {
            continue;
        }
        let Some(uuid) = attr(elem, "UUID") else {
            continue;
        };
        let Some(host) = attr(elem, "Location").as_deref().and_then(host_of) else {
            continue;
        };
        players.push(Player {
            room: attr(elem, "ZoneName").unwrap_or_else(|| uuid.clone()),
            coordinator: if coordinator.is_empty() {
                uuid.clone()
            } else {
                coordinator.clone()
            },
            airplay: attr(elem, "AirPlayEnabled").as_deref() == Some("1"),
            uuid,
            host,
        });
    }
    players.sort_by(|a, b| a.room.cmp(&b.room));
    players
}

/// Broadcast an SSDP `M-SEARCH` and collect the hosts that answer.
///
/// Best-effort by design: a firewalled or multicast-hostile network
/// yields an empty list, which the caller treats as "no Sonos here"
/// rather than an error.
pub fn ssdp_hosts() -> Vec<String> {
    let Ok(socket) = UdpSocket::bind("0.0.0.0:0") else {
        return Vec::new();
    };
    let _ = socket.set_read_timeout(Some(Duration::from_millis(300)));
    let msearch = format!(
        "M-SEARCH * HTTP/1.1\r\nHOST: {SSDP_ADDR}\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: {ZONE_PLAYER}\r\n\r\n"
    );
    let Ok(addr) = SSDP_ADDR.parse::<SocketAddr>() else {
        return Vec::new();
    };
    if socket.send_to(msearch.as_bytes(), addr).is_err() {
        return Vec::new();
    }
    let deadline = Instant::now() + DISCOVER_WINDOW;
    let mut hosts: Vec<String> = Vec::new();
    let mut buf = [0u8; 2048];
    while Instant::now() < deadline {
        let Ok((n, from)) = socket.recv_from(&mut buf) else {
            continue; // read timeout — keep waiting until the deadline
        };
        let text = String::from_utf8_lossy(&buf[..n]);
        // Prefer the LOCATION header's host (correct even behind a
        // router doing odd things); fall back to the sender's address.
        let host = text
            .lines()
            .find(|l| l.to_ascii_uppercase().starts_with("LOCATION:"))
            .and_then(|l| host_of(l[9..].trim()))
            .unwrap_or_else(|| from.ip().to_string());
        if !hosts.contains(&host) {
            hosts.push(host);
        }
    }
    hosts
}

/// Discover the household: ask each candidate host for the topology
/// and return the first complete answer.
///
/// `pinned` short-circuits SSDP entirely (the `[sonos] host` config
/// key) — useful on networks that drop multicast, and one less
/// broadcast at startup.
pub fn discover(client: &reqwest::blocking::Client, pinned: Option<&str>) -> Vec<Player> {
    let mut candidates: Vec<String> = Vec::new();
    if let Some(h) = pinned.map(str::trim).filter(|h| !h.is_empty()) {
        candidates.push(h.to_string());
    }
    candidates.extend(ssdp_hosts());
    for host in candidates {
        let Ok(body) = soap::call(client, &host, Service::Topology, "GetZoneGroupState", "") else {
            continue;
        };
        let players = parse_topology(&body);
        if !players.is_empty() {
            return players;
        }
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shape taken from a real household: one visible room with a
    /// bonded Sub as a `<Satellite>`.
    const TOPOLOGY: &str = r#"<ZoneGroups><ZoneGroup Coordinator="RINCON_AAA01400" ID="RINCON_AAA01400:271">
<ZoneGroupMember UUID="RINCON_AAA01400" ZoneName="Living Room" Location="http://192.168.1.131:1400/xml/device_description.xml" AirPlayEnabled="1">
<Satellite UUID="RINCON_SUB01400" ZoneName="Sub 4" Location="http://192.168.1.179:1400/xml/device_description.xml" Invisible="1" AirPlayEnabled="0"/>
</ZoneGroupMember></ZoneGroup>
<ZoneGroup Coordinator="RINCON_BBB01400" ID="RINCON_BBB01400:9">
<ZoneGroupMember UUID="RINCON_BBB01400" ZoneName="Kitchen" Location="http://192.168.1.55:1400/xml/device_description.xml" AirPlayEnabled="0"/>
<ZoneGroupMember UUID="RINCON_CCC01400" ZoneName="Bedroom" Location="http://192.168.1.56:1400/xml/device_description.xml" AirPlayEnabled="1"/>
</ZoneGroup></ZoneGroups>"#;

    #[test]
    fn parses_rooms_and_skips_satellites() {
        let players = parse_topology(TOPOLOGY);
        let rooms: Vec<&str> = players.iter().map(|p| p.room.as_str()).collect();
        assert_eq!(rooms, vec!["Bedroom", "Kitchen", "Living Room"]);
        assert!(
            !players.iter().any(|p| p.room == "Sub 4"),
            "a bonded Sub is not a room"
        );
    }

    #[test]
    fn resolves_host_and_airplay_flag() {
        let players = parse_topology(TOPOLOGY);
        let lr = players.iter().find(|p| p.room == "Living Room").unwrap();
        assert_eq!(lr.host, "192.168.1.131");
        assert!(lr.airplay);
        let kitchen = players.iter().find(|p| p.room == "Kitchen").unwrap();
        assert!(!kitchen.airplay);
    }

    #[test]
    fn grouped_members_share_their_coordinator() {
        let players = parse_topology(TOPOLOGY);
        let bedroom = players.iter().find(|p| p.room == "Bedroom").unwrap();
        assert_eq!(bedroom.coordinator, "RINCON_BBB01400");
        assert!(!bedroom.is_coordinator(), "Bedroom follows the Kitchen");
        let kitchen = players.iter().find(|p| p.room == "Kitchen").unwrap();
        assert!(kitchen.is_coordinator());
    }

    #[test]
    fn parses_the_escaped_soap_wrapping() {
        // How it actually arrives: the document escaped inside the tag.
        let escaped = TOPOLOGY
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;");
        let body = format!(
            "<u:GetZoneGroupStateResponse><ZoneGroupState>{escaped}</ZoneGroupState></u:GetZoneGroupStateResponse>"
        );
        let players = parse_topology(&body);
        assert_eq!(players.len(), 3);
    }

    #[test]
    fn empty_or_junk_body_yields_no_players() {
        assert!(parse_topology("").is_empty());
        assert!(parse_topology("<html>nope</html>").is_empty());
    }

    #[test]
    fn host_of_handles_sonos_location_urls() {
        assert_eq!(
            host_of("http://192.168.1.131:1400/xml/device_description.xml").as_deref(),
            Some("192.168.1.131")
        );
        assert_eq!(host_of("garbage"), None);
    }
}
