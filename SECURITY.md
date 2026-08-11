# Security Policy

NotifMirror is a single-user tool that runs only on your own LAN. There is
no cloud component, no third-party telemetry, and no accounts. This policy
is short on purpose — the surface area is small.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems that
involve a live threat to users. Instead:

- Email the maintainer directly (see the commit history / GitHub profile of
  `onrunun` for contact details), or
- Open a private security advisory via
  GitHub → Security → "Report a vulnerability".

You will get an acknowledgement within 7 days.

## Scope

The codebase: the wire protocol, TLS/pairing, file transfer, clipboard sync,
and both app frontends.

## Threat model

From `protocol/PROTOCOL.md`:

- The wire is TLS-protected (self-signed EC P-256 cert on the server, SPKI-
  pinned on the client via the QR's `fp` field). A passive sniffer on the
  same Wi-Fi cannot read clipboard text, notification bodies, or file bytes.
- The 32-byte pre-shared `secret` proves which phone may talk to the server.
- Out of scope: an active attacker who already controls the phone or the Mac.
  A photographed QR is equivalent to a leaked password — re-pair to rotate.

## Supported versions

Only the latest release on `main` is supported. This is a personal tool with
no LTS commitment.
