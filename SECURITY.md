# Security Policy

## Reporting a vulnerability

Please report security issues privately, through GitHub's
[private vulnerability reporting][pvr] on this repository:

**<https://github.com/chris-mclennan/mnml/security/advisories/new>**

That channel is preferred over a public issue, a discussion, or a PR —
it keeps the details out of sight until a fix ships. If private
reporting is unavailable to you for any reason, open a normal issue
saying only that you have a security report and asking for a contact,
without the details.

Expect an acknowledgement within a few days. mnml is maintained by one
person, so please allow reasonable time for a fix before disclosing
publicly.

### What's useful in a report

The mechanism and how you found it. A proof of concept helps a great
deal — even a rough one — because the difference between "this looks
reachable" and "I ran this and it did X" is most of the work.

Please say which you have. A report that flags something plausible but
unverified is still worth sending; just label it as such, so it can be
triaged accordingly rather than treated as confirmed.

## Supported versions

Fixes land on the latest release. There is no long-term support branch —
if you're reporting against an older version, please check whether the
issue still reproduces on the current one.

## Scope

mnml is a terminal IDE. It runs language servers, formatters, debug
adapters, shell commands and AI tooling on your behalf, and it talks to
a number of third-party services through its integrations. The
interesting boundaries are:

- **Untrusted workspace content.** Opening a repository should not run
  code from that repository. A repo's own `.mnml/` config can declare
  language servers, formatters, startup commands and integrations;
  those are gated behind a per-workspace trust prompt
  (`workspace.review_trust`). A way around that gate is a
  vulnerability.
- **Credentials at rest.** Integration tokens, cookies, HTTP request
  history and AI credentials are written under `~/.config/mnml/` and
  the workspace's `.mnml/` and `.rqst/` directories, owner-only. A path
  that writes one world-readable, commits one to git, or leaks one into
  a process that shouldn't have it is a vulnerability.
- **What leaves the machine.** AI features send buffer context to a
  backend you configure. That's opt-in, and files whose names look
  secret-bearing are excluded regardless. Anything that sends more than
  the feature implies is a vulnerability.
- **Local network surfaces.** The Sonos audio-streaming feature runs a
  short-lived HTTP server while active; the file-IPC channel is a local
  control surface. Both should be reachable only by their intended
  peer.

### Out of scope

- Anything requiring an attacker who already has code execution as your
  user, or who can write to your home directory. mnml can't defend a
  boundary that's already gone.
- Configuration you wrote yourself. `:!command`, `[[startup.layout]]`
  and friends run what you tell them to; that's the feature.
- Denial of service via a deliberately malformed file that only affects
  your own session.
- Vulnerabilities in language servers, formatters or other tools mnml
  launches — report those to their maintainers. How mnml *decides* to
  launch them is in scope.

[pvr]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability
