//! The bundled header table behind the Headers tab's completion: the
//! standard request header names, a one-line description each (the
//! `?` tip and the popup's footer), and the values a name is usually
//! sent with. The live sources — the last response's headers and the
//! workspace's own `.http` files — rank ahead of this table
//! (`app/http.zig`, `headerNameCandidates` / `headerValueCandidates`);
//! this is the floor under them.

const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    doc: []const u8,
    values: []const []const u8 = &.{},
};

/// A response header whose value is what the next request sends under
/// another name: `ETag` answers `If-None-Match`.
pub const Pairing = struct { request: []const u8, response: []const u8 };

pub const pairings = [_]Pairing{
    .{ .request = "If-None-Match", .response = "ETag" },
    .{ .request = "If-Match", .response = "ETag" },
    .{ .request = "If-Modified-Since", .response = "Last-Modified" },
    .{ .request = "If-Unmodified-Since", .response = "Last-Modified" },
    .{ .request = "If-Range", .response = "ETag" },
    .{ .request = "Accept", .response = "Content-Type" },
    .{ .request = "Content-Type", .response = "Content-Type" },
    .{ .request = "X-Request-ID", .response = "X-Request-ID" },
    .{ .request = "X-Correlation-ID", .response = "X-Correlation-ID" },
    .{ .request = "Accept-Language", .response = "Content-Language" },
    .{ .request = "Accept-Encoding", .response = "Content-Encoding" },
};

const media_types = [_][]const u8{ "application/json", "*/*", "text/plain", "text/html", "application/xml", "application/x-ndjson", "text/event-stream", "application/octet-stream", "image/*" };
const encodings = [_][]const u8{ "gzip, deflate, br", "gzip", "deflate", "br", "identity" };

pub const entries = [_]Entry{
    .{ .name = "Accept", .doc = "Media types the client can take back, best first; `*/*` for anything.", .values = &media_types },
    .{ .name = "Accept-Charset", .doc = "Character sets the client can read.", .values = &.{ "utf-8", "iso-8859-1" } },
    .{ .name = "Accept-Encoding", .doc = "Content codings the client can decode; the server picks one for the body.", .values = &encodings },
    .{ .name = "Accept-Language", .doc = "Natural languages the client prefers, with `q` weights.", .values = &.{ "en-US,en;q=0.9", "en-US", "en", "fr", "de", "es", "ja" } },
    .{ .name = "Accept-Ranges", .doc = "Range units a server supports (`bytes`); sent back, not up.", .values = &.{ "bytes", "none" } },
    .{ .name = "Access-Control-Request-Headers", .doc = "The headers a CORS preflight asks permission to send.", .values = &.{ "content-type", "authorization", "content-type, authorization" } },
    .{ .name = "Access-Control-Request-Method", .doc = "The method a CORS preflight asks permission to use.", .values = &.{ "GET", "POST", "PUT", "PATCH", "DELETE" } },
    .{ .name = "Allow", .doc = "The methods a resource supports; answers a 405.", .values = &.{ "GET, HEAD, OPTIONS", "GET, POST" } },
    .{ .name = "Authorization", .doc = "Credentials for the resource: a scheme, a space, the token.", .values = &.{ "Bearer ", "Basic ", "Digest ", "Token ", "ApiKey " } },
    .{ .name = "Cache-Control", .doc = "Caching directives for the request and every cache on the way.", .values = &.{ "no-cache", "no-store", "max-age=0", "max-age=3600", "must-revalidate", "only-if-cached", "no-transform", "public", "private" } },
    .{ .name = "Connection", .doc = "Whether the connection stays open after this exchange.", .values = &.{ "keep-alive", "close", "upgrade" } },
    .{ .name = "Content-Disposition", .doc = "How a body part is meant to be handled: inline, an attachment, a form field.", .values = &.{ "inline", "attachment; filename=\"file.txt\"", "form-data; name=\"field\"" } },
    .{ .name = "Content-Encoding", .doc = "The coding applied to the body being sent.", .values = &.{ "gzip", "deflate", "br", "identity" } },
    .{ .name = "Content-Language", .doc = "The natural language of the body.", .values = &.{ "en", "en-US" } },
    .{ .name = "Content-Length", .doc = "The body's size in bytes; the client sets it from the body — rarely typed by hand." },
    .{ .name = "Content-MD5", .doc = "A base64 MD5 of the body, for integrity checks." },
    .{ .name = "Content-Type", .doc = "The media type of the body being sent, with an optional charset.", .values = &.{ "application/json", "application/x-www-form-urlencoded", "multipart/form-data", "text/plain", "application/json; charset=utf-8", "application/xml", "text/html", "application/octet-stream", "application/graphql", "application/x-ndjson" } },
    .{ .name = "Cookie", .doc = "Cookies for this host as `name=value` pairs; the jar adds its own after the send is built.", .values = &.{"session="} },
    .{ .name = "Date", .doc = "When the message was made, in HTTP date form." },
    .{ .name = "Digest", .doc = "A digest of the body, `algorithm=base64`.", .values = &.{"sha-256="} },
    .{ .name = "DNT", .doc = "The do-not-track preference.", .values = &.{"1"} },
    .{ .name = "Early-Data", .doc = "The request was sent in TLS early data (0-RTT).", .values = &.{"1"} },
    .{ .name = "ETag", .doc = "A resource's version tag; sent back, and echoed in `If-None-Match`." },
    .{ .name = "Expect", .doc = "Ask the server to answer 100 Continue before the body is sent.", .values = &.{"100-continue"} },
    .{ .name = "Forwarded", .doc = "Proxy information: the original client, host and protocol.", .values = &.{"for=192.0.2.60;proto=https;by=203.0.113.43"} },
    .{ .name = "From", .doc = "An email address for the person running the client." },
    .{ .name = "Host", .doc = "The target host and port; the client sets it from the URL." },
    .{ .name = "Idempotency-Key", .doc = "A unique key so a retried request is applied once.", .values = &.{"{{$uuid}}"} },
    .{ .name = "If-Match", .doc = "Only act when the resource's ETag matches — a safe conditional write.", .values = &.{"*"} },
    .{ .name = "If-Modified-Since", .doc = "Only send the body when it changed after this date; else 304." },
    .{ .name = "If-None-Match", .doc = "Only send the body when the ETag differs; else 304.", .values = &.{"*"} },
    .{ .name = "If-Range", .doc = "Send the range only when the ETag or date still matches, else the whole body." },
    .{ .name = "If-Unmodified-Since", .doc = "Only act when the resource is unchanged since this date." },
    .{ .name = "Keep-Alive", .doc = "Hints for a persistent connection: idle timeout, request cap.", .values = &.{ "timeout=5", "timeout=5, max=100" } },
    .{ .name = "Last-Modified", .doc = "When the resource last changed; sent back, echoed in `If-Modified-Since`." },
    .{ .name = "Link", .doc = "Related resources with a `rel`: pagination, alternates.", .values = &.{"<https://example.com/?page=2>; rel=\"next\""} },
    .{ .name = "Location", .doc = "Where a redirect or a created resource lives; sent back." },
    .{ .name = "Max-Forwards", .doc = "How many proxies a TRACE or OPTIONS may pass through.", .values = &.{ "0", "10" } },
    .{ .name = "Origin", .doc = "The scheme, host and port the request came from; drives CORS.", .values = &.{ "https://example.com", "null" } },
    .{ .name = "Pragma", .doc = "The HTTP/1.0 way to say `no-cache`.", .values = &.{"no-cache"} },
    .{ .name = "Prefer", .doc = "How the client would like the server to behave: a minimal body, an async answer.", .values = &.{ "return=minimal", "return=representation", "respond-async", "wait=10" } },
    .{ .name = "Priority", .doc = "The request's urgency and incremental delivery hint.", .values = &.{ "u=3", "u=0", "u=1, i" } },
    .{ .name = "Proxy-Authorization", .doc = "Credentials for a proxy on the way.", .values = &.{ "Basic ", "Bearer " } },
    .{ .name = "Purpose", .doc = "A speculative request: a prefetch.", .values = &.{"prefetch"} },
    .{ .name = "Range", .doc = "Ask for part of the body, in bytes.", .values = &.{ "bytes=0-1023", "bytes=0-", "bytes=-500" } },
    .{ .name = "Referer", .doc = "The page the request came from." },
    .{ .name = "Retry-After", .doc = "How long to wait before trying again; sent back with 429 and 503.", .values = &.{ "120", "Wed, 21 Oct 2015 07:28:00 GMT" } },
    .{ .name = "Save-Data", .doc = "The client prefers less data.", .values = &.{"on"} },
    .{ .name = "Sec-Fetch-Dest", .doc = "What the fetched resource is for.", .values = &.{ "document", "empty", "image", "script", "style" } },
    .{ .name = "Sec-Fetch-Mode", .doc = "The fetch mode: navigate, cors, no-cors.", .values = &.{ "cors", "navigate", "no-cors", "same-origin", "websocket" } },
    .{ .name = "Sec-Fetch-Site", .doc = "How the origin relates to the target.", .values = &.{ "same-origin", "same-site", "cross-site", "none" } },
    .{ .name = "Sec-WebSocket-Protocol", .doc = "The subprotocols a WebSocket client offers." },
    .{ .name = "Sec-WebSocket-Version", .doc = "The WebSocket protocol version.", .values = &.{"13"} },
    .{ .name = "Service-Worker", .doc = "The request fetches a service worker script.", .values = &.{"script"} },
    .{ .name = "TE", .doc = "Transfer codings the client accepts, and `trailers`.", .values = &.{ "trailers", "chunked" } },
    .{ .name = "Trailer", .doc = "Header fields that follow a chunked body." },
    .{ .name = "Transfer-Encoding", .doc = "How the body is framed on the wire.", .values = &.{"chunked"} },
    .{ .name = "Upgrade", .doc = "Ask to switch protocols on this connection.", .values = &.{ "websocket", "h2c" } },
    .{ .name = "Upgrade-Insecure-Requests", .doc = "The client prefers an https answer.", .values = &.{"1"} },
    .{ .name = "User-Agent", .doc = "The client's name and version.", .values = &.{ "mnml", "curl/8.0", "Mozilla/5.0" } },
    .{ .name = "Vary", .doc = "Which request headers a cache must key on; sent back.", .values = &.{ "Accept-Encoding", "Origin", "*" } },
    .{ .name = "Via", .doc = "The proxies the message passed through." },
    .{ .name = "Warning", .doc = "Extra information about a response's status." },
    .{ .name = "WWW-Authenticate", .doc = "The challenge a 401 sends back: the scheme and realm to answer." },
    .{ .name = "X-Api-Key", .doc = "An API key, sent as a plain header." },
    .{ .name = "X-Correlation-ID", .doc = "An id that ties this request to the others of one operation.", .values = &.{"{{$uuid}}"} },
    .{ .name = "X-CSRF-Token", .doc = "The anti-forgery token a form-based site expects back." },
    .{ .name = "X-Forwarded-For", .doc = "The original client address, as a proxy reports it.", .values = &.{"192.0.2.60"} },
    .{ .name = "X-Forwarded-Host", .doc = "The original Host the client asked for." },
    .{ .name = "X-Forwarded-Proto", .doc = "The original scheme the client used.", .values = &.{ "https", "http" } },
    .{ .name = "X-HTTP-Method-Override", .doc = "The method a POST should be treated as, past a proxy that blocks it.", .values = &.{ "PUT", "PATCH", "DELETE" } },
    .{ .name = "X-Request-ID", .doc = "A unique id for this request, for tracing on both sides.", .values = &.{"{{$uuid}}"} },
    .{ .name = "X-Requested-With", .doc = "Marks a request made from script.", .values = &.{"XMLHttpRequest"} },
};

/// The entry for `name`, case-insensitively.
pub fn find(name: []const u8) ?*const Entry {
    const n = std.mem.trim(u8, name, " \t");
    for (&entries) |*e| if (std.ascii.eqlIgnoreCase(e.name, n)) return e;
    return null;
}

/// The response header whose value answers a request header, if any.
pub fn pairedResponseHeader(request_name: []const u8) ?[]const u8 {
    for (pairings) |p| if (std.ascii.eqlIgnoreCase(p.request, request_name)) return p.response;
    return null;
}

/// The request header a response header suggests sending next.
pub fn suggestedRequestHeader(response_name: []const u8) ?[]const u8 {
    for (pairings) |p| if (std.ascii.eqlIgnoreCase(p.response, response_name) and !std.ascii.eqlIgnoreCase(p.request, response_name)) return p.request;
    return null;
}

test "the table has the headers the tab promises, each with a description; lookups ignore case; pairings answer both ways" {
    try std.testing.expect(entries.len >= 60);
    for (entries) |e| {
        try std.testing.expect(e.name.len > 0 and e.doc.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, e.name, ' ') == null);
    }
    try std.testing.expectEqualStrings("Content-Type", find("content-type").?.name);
    try std.testing.expectEqualStrings("application/json", find(" Content-Type ").?.values[0]);
    try std.testing.expect(find("X-Nope") == null);
    try std.testing.expect(find("Accept-Encoding").?.values.len >= 3);
    try std.testing.expectEqualStrings("ETag", pairedResponseHeader("if-none-match").?);
    try std.testing.expectEqualStrings("If-None-Match", suggestedRequestHeader("etag").?);
    // A response `Content-Type` suggests `Accept` — never itself.
    try std.testing.expectEqualStrings("Accept", suggestedRequestHeader("Content-Type").?);
    try std.testing.expect(suggestedRequestHeader("Server") == null);
    try std.testing.expectEqualStrings("Content-Type", pairedResponseHeader("Content-Type").?);
}
