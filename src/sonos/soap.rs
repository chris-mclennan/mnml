//! Sonos UPnP/SOAP client — the wire layer under [`crate::sonos`].
//!
//! Every Sonos player runs a plain HTTP server on port 1400 exposing
//! UPnP services (`AVTransport` for transport + queue,
//! `RenderingControl` for volume/mute, `ContentDirectory` for
//! favorites, `ZoneGroupTopology` for the household map). No auth, no
//! cloud round-trip, no vendor SDK — a POST with a SOAP envelope and
//! a `SOAPACTION` header is the whole protocol.
//!
//! Responses are small, fixed-shape XML documents, so this module
//! scans for known tags rather than pulling in an XML parser (mnml has
//! no XML dependency and one tag-scan helper is cheaper than adding
//! one). [`tag_text`] + [`unescape`] carry that weight; Sonos nests
//! *escaped* XML (DIDL-Lite metadata, the whole zone-group state) as
//! tag text, so double-unescaping is normal here, not a smell.

use std::time::Duration;

/// Sonos's fixed control port. Not configurable — it's baked into the
/// firmware.
pub const PORT: u16 = 1400;

/// How long any single SOAP call may take. Deliberately short: these
/// run on the [`crate::sonos`] worker thread, and a powered-off player
/// must not stall the poll loop (or a click) for seconds.
const TIMEOUT: Duration = Duration::from_millis(2500);

/// A UPnP service on a player — the path to POST to, and the service
/// type that namespaces the action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Service {
    /// Transport: play / pause / next / previous / queue / position.
    AvTransport,
    /// Volume + mute.
    Rendering,
    /// Browse favorites / playlists / queue.
    ContentDirectory,
    /// The household map — which players exist, who coordinates whom.
    Topology,
}

impl Service {
    /// Path component under `http://<host>:1400/`.
    fn path(self) -> &'static str {
        match self {
            Service::AvTransport => "MediaRenderer/AVTransport/Control",
            Service::Rendering => "MediaRenderer/RenderingControl/Control",
            Service::ContentDirectory => "MediaServer/ContentDirectory/Control",
            Service::Topology => "ZoneGroupTopology/Control",
        }
    }
    /// UPnP service type, used for both the `xmlns:u` of the action
    /// element and the `SOAPACTION` header.
    fn urn(self) -> &'static str {
        match self {
            Service::AvTransport => "urn:schemas-upnp-org:service:AVTransport:1",
            Service::Rendering => "urn:schemas-upnp-org:service:RenderingControl:1",
            Service::ContentDirectory => "urn:schemas-upnp-org:service:ContentDirectory:1",
            Service::Topology => "urn:schemas-upnp-org:service:ZoneGroupTopology:1",
        }
    }
}

/// Wrap `args` in the SOAP envelope Sonos expects for `action` on
/// `service`. Split out from [`call`] so the envelope shape is
/// unit-testable without a player on the network.
pub fn envelope(service: Service, action: &str, args: &str) -> String {
    format!(
        "<?xml version=\"1.0\"?>\
<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\
<s:Body><u:{action} xmlns:u=\"{urn}\">{args}</u:{action}></s:Body></s:Envelope>",
        action = action,
        urn = service.urn(),
        args = args,
    )
}

/// POST one SOAP action at `host` and return the raw response body.
///
/// `Err` covers both transport failure (player asleep / off the
/// network) and a SOAP fault, since callers treat them the same way:
/// the snapshot goes stale and the chip says so.
pub fn call(
    client: &reqwest::blocking::Client,
    host: &str,
    service: Service,
    action: &str,
    args: &str,
) -> Result<String, String> {
    let url = format!("http://{host}:{PORT}/{}", service.path());
    let soapaction = format!("\"{}#{action}\"", service.urn());
    let resp = client
        .post(&url)
        .header("Content-Type", "text/xml; charset=\"utf-8\"")
        .header("SOAPACTION", soapaction)
        .timeout(TIMEOUT)
        .body(envelope(service, action, args))
        .send()
        .map_err(|e| format!("{action}: {e}"))?;
    let status = resp.status();
    let body = resp.text().unwrap_or_default();
    if !status.is_success() {
        // Sonos returns 500 + a <errorCode> for refused actions (e.g.
        // Next on a non-skippable stream). Surface the code — it's the
        // only actionable part of the fault.
        let code = tag_text(&body, "errorCode").unwrap_or_default();
        return Err(if code.is_empty() {
            format!("{action}: HTTP {status}")
        } else {
            format!("{action}: UPnP error {code}")
        });
    }
    Ok(body)
}

/// Text content of the first `<tag>…</tag>` in `xml`, or `None`.
///
/// Attribute-tolerant (`<tag foo="bar">` matches) and non-recursive —
/// enough for Sonos's flat response bodies. Returns the raw (still
/// escaped) text; callers that expect nested XML run [`unescape`].
pub fn tag_text<'a>(xml: &'a str, tag: &str) -> Option<&'a str> {
    let open = format!("<{tag}");
    let start = xml.find(&open)?;
    // Skip past the rest of the open tag (attributes included).
    let after_open = start + xml[start..].find('>')? + 1;
    // Self-closing (`<tag/>`) has no text.
    if xml[start..after_open].ends_with("/>") {
        return Some("");
    }
    let close = format!("</{tag}>");
    let end = xml[after_open..].find(&close)? + after_open;
    Some(&xml[after_open..end])
}

/// Resolve the XML entities Sonos actually emits. One pass, so nested
/// (double-escaped) payloads need two calls — which is exactly how
/// zone-group state and DIDL metadata arrive.
pub fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let tail = &rest[i..];
        let (entity, decoded): (&str, char) = if tail.starts_with("&amp;") {
            ("&amp;", '&')
        } else if tail.starts_with("&lt;") {
            ("&lt;", '<')
        } else if tail.starts_with("&gt;") {
            ("&gt;", '>')
        } else if tail.starts_with("&quot;") {
            ("&quot;", '"')
        } else if tail.starts_with("&apos;") {
            ("&apos;", '\'')
        } else if tail.starts_with("&#39;") {
            ("&#39;", '\'')
        } else if tail.starts_with("&#x27;") {
            ("&#x27;", '\'')
        } else {
            // Unknown entity — emit the `&` and keep scanning after it
            // so we can't loop forever on it.
            out.push('&');
            rest = &tail[1..];
            continue;
        };
        out.push(decoded);
        rest = &tail[entity.len()..];
    }
    out.push_str(rest);
    out
}

/// Escape `s` for inclusion as SOAP argument text. Needed because
/// favorite URIs and DIDL metadata are themselves XML and get nested
/// inside the envelope.
pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_carries_action_and_urn() {
        let e = envelope(Service::AvTransport, "Pause", "<InstanceID>0</InstanceID>");
        assert!(e.contains("<u:Pause xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"));
        assert!(e.contains("<InstanceID>0</InstanceID>"));
        assert!(e.ends_with("</u:Pause></s:Body></s:Envelope>"));
    }

    #[test]
    fn service_paths_are_the_documented_ones() {
        assert_eq!(
            Service::Rendering.path(),
            "MediaRenderer/RenderingControl/Control"
        );
        assert_eq!(Service::Topology.path(), "ZoneGroupTopology/Control");
    }

    #[test]
    fn tag_text_reads_flat_bodies() {
        let xml = "<x><CurrentTransportState>PLAYING</CurrentTransportState></x>";
        assert_eq!(tag_text(xml, "CurrentTransportState"), Some("PLAYING"));
        assert_eq!(tag_text(xml, "Nope"), None);
    }

    #[test]
    fn tag_text_tolerates_attributes_and_self_closing() {
        assert_eq!(tag_text("<a b=\"1\">hi</a>", "a"), Some("hi"));
        assert_eq!(tag_text("<a/>", "a"), Some(""));
    }

    #[test]
    fn unescape_handles_one_level() {
        assert_eq!(unescape("a &amp;lt;b&amp;gt; c"), "a &lt;b&gt; c");
        // Second pass gets the nested document, as Sonos requires.
        assert_eq!(
            unescape(&unescape("&amp;lt;ZoneGroup&amp;gt;")),
            "<ZoneGroup>"
        );
    }

    #[test]
    fn unescape_leaves_unknown_entities_alone_without_looping() {
        assert_eq!(unescape("100 &euro; &amp; more"), "100 &euro; & more");
    }

    #[test]
    fn escape_round_trips_through_unescape() {
        let raw = "Tom & Jerry's <hit> \"song\"";
        assert_eq!(unescape(&escape(raw)), raw);
    }
}
