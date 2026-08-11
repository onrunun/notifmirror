# NotifMirror Wire Protocol (v2)

Transport: one persistent **TLS** WebSocket (`wss://`), Mac = server,
Android = client. The server presents a self-signed leaf cert; the client
pins it by SHA-256 of its SubjectPublicKeyInfo (carried in the QR as `fp`).
Discovery: Bonjour service type `_andnotif._tcp`.
Framing: every WebSocket text frame is one JSON object, UTF-8.
Versioning: `v` field on every message; server accepts any `proto` it
understands (currently 1 and 2). Unknown `t` values MUST be ignored silently by
both sides so future additions don't break older peers.

---

## Pairing

Mac generates a 256-bit random secret AND a self-signed EC P-256 cert on
first launch, both stored in `~/Library/Preferences` (UserDefaults — see
`Pairing.swift` for why this is preferred over Keychain). The pairing QR
is a UTF-8 JSON string:

```json
{
  "v": 3,
  "host": "192.168.1.42",
  "port": 53712,
  "secret": "<base64-32B>",
  "name": "My MacBook",
  "fp": "<base64 SHA-256 of cert SPKI>"
}
```

`fp` is the SHA-256 of the server cert's SubjectPublicKeyInfo (DER), base64.
The Android client pins on this — no CA chain is involved, the cert is
trusted iff its SPKI hash matches `fp`. Reset Pairing on the Mac rotates
both `secret` and the cert (so `fp` changes too); the phone must re-scan.

Android scans the QR, stores the payload in EncryptedSharedPreferences, and
uses `host:port` for the first connection. On reconnect it prefers the Bonjour
resolved address so IP changes don't brick pairing.

QRs from earlier (v=1, v=2 — plaintext `ws://`) versions are no longer
accepted; the phone refuses to load any payload missing `fp`.

---

## Message schema

All messages have at least `t` (type) and `v` (protocol version).

### `hello` — client → server
Sent immediately after TCP/WS handshake.

```json
{"t":"hello","v":2,"proto":2,"secret":"<b64>","deviceName":"Pixel 8",
 "features":["clip","media","file"]}
```

`features` is optional; it advertises which optional capabilities the client
supports. A server that doesn't recognise a feature simply won't use it.

Server validates `secret` with constant-time comparison against Keychain. On
failure, server sends `error` and closes. On success, server sends `hello_ack`
and starts receiving.

### `hello_ack` — server → client

```json
{"t":"hello_ack","v":2,"accepted":true,"serverName":"My MacBook",
 "features":["clip","media","file"]}
```

### `posted` — client → server
A new notification. `key` is `StatusBarNotification.key` (stable for the life
of the notification on that device).

```json
{
  "t":"posted","v":2,
  "key":"0|com.whatsapp|12345|null|10123",
  "pkg":"com.whatsapp",
  "app":"WhatsApp",
  "title":"Ali",
  "text":"Hey, are you around?",
  "subText":null,
  "appIcon":"<b64 png, nullable>",
  "largeIcon":"<b64 png, nullable>",
  "picture":"<b64 jpg, nullable>",
  "postTime":1710000000000,
  "silent":false,
  "actions":[
    {"id":"0","title":"Reply","isReply":true},
    {"id":"1","title":"Mark as read","isReply":false}
  ]
}
```

### `removed` — client → server
Notification dismissed on Android.

```json
{"t":"removed","v":2,"key":"..."}
```

### `dismiss` — server → client
User dismissed the mirrored notification on macOS; phone should cancel it.

```json
{"t":"dismiss","v":2,"key":"..."}
```

### `action` — server → client
User invoked an action on macOS. If `text` is present, it's a reply
(`RemoteInput` on Android).

```json
{"t":"action","v":2,"key":"...","actionId":"0","text":"hello from Mac"}
```

---

## Clipboard sync (feature `clip`)

### `clip` — either direction
One-shot text clipboard content. Sender publishes its current pasteboard text
whenever it changes. Recipient writes the text to its pasteboard without
triggering another `clip` broadcast (hash-based echo suppression, see below).

```json
{"t":"clip","v":2,"text":"hello world","origin":"mac","seq":42}
```

- `text`: UTF-8, capped at 64 KiB. Larger selections are not sent.
- `origin`: `"mac"` or `"android"`. Used only for display/logging.
- `seq`: monotonic per-sender counter. Recipients ignore a `clip` whose
  SHA-256 of `text` matches what they most recently wrote to their own
  pasteboard (echo suppression).

Android constraint: Android 10+ forbids background reads of the clipboard, so
Android→Mac sync only works while the NotifMirror app is foregrounded. Mac→
Android works in all cases (write is always allowed).

---

## Media control (feature `media`)

### `media_state` — client → server
Now-playing snapshot. Sent on state transitions (play, pause, track change,
seek) and on explicit request via `media_cmd` `refresh`. Sender throttles to
no more than one update per 500 ms.

```json
{
  "t":"media_state","v":2,
  "pkg":"com.spotify.music",
  "app":"Spotify",
  "title":"Midnight City",
  "artist":"M83",
  "album":"Hurry Up, We're Dreaming",
  "artwork":"<b64 jpg, nullable>",
  "playing":true,
  "positionMs":73400,
  "durationMs":241000,
  "canPause":true,
  "canSkipNext":true,
  "canSkipPrev":true,
  "volume":6,
  "maxVolume":15,
  "updatedAt":1710000000000
}
```

`volume` / `maxVolume` report the phone's current `STREAM_MUSIC` level (an
integer step, 0..max). They're included even when no session is active, since
the OS exposes them independently.

If no session is active, send:

```json
{"t":"media_state","v":2,"pkg":null,"playing":false,"volume":6,"maxVolume":15,"updatedAt":...}
```

### `media_cmd` — server → client
A transport command.

```json
{"t":"media_cmd","v":2,"cmd":"play"}
```

`cmd` values: `play`, `pause`, `toggle`, `next`, `prev`, `refresh`,
`vol_up`, `vol_down`, `vol_set`. When `cmd` is `vol_set`, include an integer
`value` (0..maxVolume):

```json
{"t":"media_cmd","v":2,"cmd":"vol_set","value":8}
```

---

## Battery status (feature `battery`)

Phone pushes its current battery level and charging state to the Mac. Mac
displays it (typically in the menu bar) and may surface a low-battery notice.
One-way: `phone → Mac`.

### `battery_state` — client → server

Sent on initial connect, on charge-state transitions
(`ACTION_POWER_CONNECTED` / `_DISCONNECTED`), on
`ACTION_BATTERY_LOW` / `_OKAY`, and on every level change of ≥1 %. Throttled
to one update per 5 s to avoid flooding while the level briefly toggles
(e.g. while plugging in).

```json
{
  "t":"battery_state","v":2,
  "level":87,
  "charging":true,
  "status":"charging",
  "plugged":"ac",
  "temperatureC":32.5,
  "voltageMv":4250,
  "low":false,
  "updatedAt":1710000000000
}
```

- `level` — integer 0..100, percent. `-1` if the OS reports it as unknown
  (rare; means caller should treat the snapshot as level-less).
- `charging` — convenience boolean: `true` when the phone is gaining charge
  (i.e. `status` is `charging` or `full` while still plugged in).
- `status` — one of `charging`, `discharging`, `full`, `not_charging`,
  `unknown`. Mirrors `BatteryManager.EXTRA_STATUS`.
- `plugged` — one of `ac`, `usb`, `wireless`, `dock`, `none`, `unknown`.
  `dock` is Android 12+ only.
- `temperatureC` — battery temperature in degrees Celsius (`null` if the
  OS doesn't report it). The raw extra is tenths-of-a-degree; we divide.
- `voltageMv` — battery voltage in millivolts (`null` if not reported).
- `low` — `true` while the device is in the low-battery state
  (`ACTION_BATTERY_LOW` fired and `_OKAY` hasn't yet). Mac uses this to
  surface a "phone is low" banner once per low-event, not on every update.

If the phone advertises `battery` in `hello.features` but the platform
returns no battery info (emulator, dev kit), it sends one snapshot with
`level:-1` and `status:"unknown"` so the Mac UI shows "—" instead of an
empty placeholder.

---

## File transfer (feature `file`)

A file is sent over the same WebSocket in chunks, sharing the channel with
notifications. To keep notifications and pings responsive, the sender chunks
at **256 KiB** and pauses between chunks using natural WebSocket back-pressure
(OkHttp's `WebSocket.send` returns false if the outbound queue is full —
sender yields and retries).

File transfers are identified by an `xid` (transfer id) chosen by the sender.
Either peer may initiate.

### `file_offer` — either direction
Announce a new transfer. Recipient must reply with `file_accept` or
`file_reject` before chunks arrive.

```json
{
  "t":"file_offer","v":2,
  "xid":"A1B2C3D4",
  "name":"photo.jpg",
  "size":2847392,
  "mime":"image/jpeg",
  "sha256":"<hex-64, optional>"
}
```

### `file_accept` — either direction

```json
{"t":"file_accept","v":2,"xid":"A1B2C3D4"}
```

### `file_reject` — either direction

```json
{"t":"file_reject","v":2,"xid":"A1B2C3D4","reason":"user_declined"}
```

Known reasons: `user_declined`, `too_big`, `unsupported`, `io_error`.

### `file_chunk` — sender → recipient
Zero-based `offset`, `data` is base64-encoded chunk bytes. `last` flags the
final chunk.

```json
{
  "t":"file_chunk","v":2,
  "xid":"A1B2C3D4",
  "offset":0,
  "data":"<b64>",
  "last":false
}
```

### `file_done` — sender → recipient
Sent after the final `file_chunk`. Recipient verifies size (and optional
sha256) and responds with `file_ack`.

```json
{"t":"file_done","v":2,"xid":"A1B2C3D4"}
```

### `file_ack` — recipient → sender

```json
{"t":"file_ack","v":2,"xid":"A1B2C3D4","ok":true,"error":null}
```

### `file_cancel` — either direction
Abort an in-flight transfer.

```json
{"t":"file_cancel","v":2,"xid":"A1B2C3D4","reason":"user_cancelled"}
```

---

## Phone file browse (feature `fsbrowse`)

Lets the Mac browse/read/write the phone filesystem over the paired WebSocket
so the user doesn't need adb + developer options. Android advertises `fsbrowse`
in its `hello.features` only when `MANAGE_EXTERNAL_STORAGE` has been granted.

Every request carries `reqId` (short random string, client-chosen). Responses
echo the same `reqId` back so the Mac can correlate. `path` is always an
absolute POSIX path on the phone (e.g. `/sdcard/DCIM/Camera`).

### `fs_list` — server → client

```json
{"t":"fs_list","v":2,"reqId":"r1","path":"/sdcard/DCIM"}
```

### `fs_list_result` — client → server

```json
{"t":"fs_list_result","v":2,"reqId":"r1","path":"/sdcard/DCIM","entries":[
  {"name":"Camera","kind":"dir","size":0,"mtime":1714074123},
  {"name":"IMG_0001.jpg","kind":"file","size":2456123,"mtime":1714074124}
]}
```

`kind` ∈ {`dir`, `file`, `link`, `other`}. `mtime` is seconds since epoch. If
the directory can't be read, client sends the same message with `error` and an
empty `entries` list.

### `fs_delete` / `fs_mkdir` — server → client

```json
{"t":"fs_delete","v":2,"reqId":"r2","path":"/sdcard/Download/a.txt"}
{"t":"fs_mkdir","v":2,"reqId":"r3","path":"/sdcard/Download/foo"}
```

`fs_delete` is recursive for directories.

### `fs_op_result` — client → server
Generic success/failure reply for `fs_delete` and `fs_mkdir`.

```json
{"t":"fs_op_result","v":2,"reqId":"r2","ok":true}
{"t":"fs_op_result","v":2,"reqId":"r3","ok":false,"error":"permission denied"}
```

### `fs_disk` / `fs_disk_result` — free/total bytes for a path

```json
{"t":"fs_disk","v":2,"reqId":"r4","path":"/sdcard"}
{"t":"fs_disk_result","v":2,"reqId":"r4","free":39929436672,"total":108736512000}
```

### `fs_du` / `fs_du_result` — recursive disk usage scan

`fs_du` asks the phone to walk `path` recursively and report the total
on-disk size of each *immediate child*. The walk happens entirely on the
phone (one syscall per inode) so the Mac doesn't pay round-trip costs per
subdirectory.

```json
{"t":"fs_du","v":2,"reqId":"r9","path":"/sdcard"}
```

```json
{"t":"fs_du_result","v":2,"reqId":"r9","path":"/sdcard",
 "totalSize":42949672960,
 "entries":[
   {"name":"DCIM","kind":"dir","totalSize":18253611008,"fileCount":3142},
   {"name":"WhatsApp","kind":"dir","totalSize":7301201920,"fileCount":11210},
   {"name":"Download","kind":"dir","totalSize":903184,"fileCount":7},
   {"name":"some_video.mp4","kind":"file","totalSize":214568432,"fileCount":1}
 ],
 "error":null}
```

- `entries[i].totalSize` is recursive for directories (entire subtree),
  equal to the file size for files.
- `fileCount` counts regular files within the subtree (1 for files
  themselves; 0 for directories that contain only other directories or
  unreadable entries).
- Symlinks are reported with `kind:"link"` and `totalSize:0`; the walker
  does not follow them.
- Entries the phone can't `lstat` (permission, vanished mid-scan) are
  silently skipped — they don't fail the whole scan.
- For very large trees (`/sdcard`, tens of thousands of files) the scan
  can take several seconds; the response is sent only when the walk
  finishes. There's no `fs_du_progress` in v1.

### `fs_read` — server → client
Request the client to stream a file's bytes back.

```json
{"t":"fs_read","v":2,"reqId":"r5","path":"/sdcard/Download/a.txt"}
```

### `fs_read_result` — client → server
Sent once before any chunks; carries file size (or an error, in which case no
chunks follow).

```json
{"t":"fs_read_result","v":2,"reqId":"r5","size":12345}
```

Followed by one or more `fs_chunk` messages (client → server), ending with one
where `last=true`. Chunks are 256 KiB base64 payloads.

### `fs_write` — server → client
Server wants to write `size` bytes to `path`. Client must reply with
`fs_write_ready` before the server starts streaming chunks.

```json
{"t":"fs_write","v":2,"reqId":"r6","path":"/sdcard/Download/a.txt","size":12345}
```

### `fs_write_ready` — client → server
```json
{"t":"fs_write_ready","v":2,"reqId":"r6"}
```

If the client can't open the target for write, it replies with `error` set and
the server aborts (no chunks sent).

### `fs_chunk` — either direction
Body bytes for an in-flight `fs_read` (client→server) or `fs_write`
(server→client). `offset` is from the start of the file.

```json
{"t":"fs_chunk","v":2,"reqId":"r5","offset":0,"data":"<b64>","last":false}
{"t":"fs_chunk","v":2,"reqId":"r5","offset":262144,"data":"<b64>","last":true}
```

After a write's final chunk, the client sends `fs_op_result{ok:true}` to
confirm the file was closed and the size matched.

---

## Screen mirroring (feature `screen`)

Lets the Mac mirror the phone's display, audio, and inject touch/key input
over the paired WebSocket. No adb, no scrcpy, no separate transport.

Android advertises `screen` in its `hello.features` whenever the app is
installed — grant flows (MediaProjection consent, AccessibilityService) are
requested lazily when the Mac asks to start a session. A Mac that doesn't
support the feature simply never sends `screen_start`.

### Binary frames

Unlike the rest of the protocol, media samples travel as **binary** WebSocket
frames to avoid the ~33 % base64 overhead and per-frame JSON parse cost. Each
binary frame has a fixed 10-byte header followed by a raw codec payload:

```
byte 0     channel       0x01 = video, 0x02 = audio
bytes 1-8  ptsMicros     uint64 big-endian, microseconds since capture start
byte 9     flags         bit 0 = keyframe / sync sample
                         bit 1 = config (CSD-only payload, no actual frame)
bytes 10+  payload       video: H.264/H.265 annex-B NAL units
                         audio: AAC raw access unit
```

Video frames carry inline SPS/PPS (H.264) or VPS/SPS/PPS (H.265) prepended to
every IDR, so the Mac can start decoding from any keyframe without relying on
a separate config message. Config-flag frames may also arrive out of band (for
example on encoder reconfiguration).

All other messages below are standard JSON text frames.

### `screen_start` — server → client
Mac asks the phone to start a mirroring session. If a session is already
active, the phone tears it down and starts a new one with the new parameters.

```json
{
  "t":"screen_start","v":2,
  "preferredCodecs":["h265","h264"],
  "maxWidth":1280,
  "maxFps":30,
  "bitrateKbps":6000,
  "audio":true,
  "input":true
}
```

- `preferredCodecs` — ordered list; phone picks the first it can encode in
  hardware, falling back to the next. If none are supported, phone replies
  with `screen_error`.
- `maxWidth` — upper bound on the longer edge of the encoded video; phone
  scales down to keep the aspect ratio. `0` means "use native resolution".
- `maxFps` — 15, 30, or 60.
- `bitrateKbps` — VBR target. Phone clamps to what the hardware encoder
  supports.
- `audio` — when `true` and the phone is Android 10+, phone starts an
  `AudioPlaybackCapture` session for `STREAM_MUSIC`. Apps marked
  `allowAudioPlaybackCapture=false` in their manifest are silently excluded
  (platform policy). On failure the session still starts, video-only.
- `input` — when `true`, phone binds its `AccessibilityService` to accept
  `screen_input` messages. If the user hasn't granted the accessibility
  permission, phone replies `screen_ready` with `input:false` and the Mac
  can prompt the user to enable it.

### `screen_ready` — client → server
Phone has opened the encoder and is about to start emitting binary frames.

```json
{
  "t":"screen_ready","v":2,
  "codec":"h265",
  "width":720,
  "height":1560,
  "fps":30,
  "audioCodec":"aac",
  "audioSampleRate":48000,
  "audioChannels":2,
  "input":true
}
```

`audioCodec` is `null` when audio capture wasn't granted or not requested.
`input` echoes whether input injection is actually available.

### `screen_stop` — either direction
Stop the session. Sender shouldn't emit more binary frames after this.

```json
{"t":"screen_stop","v":2,"reason":"user_closed"}
```

Known reasons: `user_closed`, `peer_disconnected`, `encoder_error`,
`permission_revoked`.

### `screen_stopped` — client → server
Phone confirms the session is fully torn down (projection released, encoder
stopped). Mac uses this to know when it's safe to start a new session.

```json
{"t":"screen_stopped","v":2,"reason":"user_closed"}
```

### `screen_error` — client → server
Fatal startup problem that prevents frames from ever arriving.

```json
{"t":"screen_error","v":2,"code":"no_codec","msg":"no supported codec in preferredCodecs"}
```

Known codes: `no_codec`, `projection_denied`, `encoder_init`, `internal`.

### `screen_input` — server → client
Injected input event. Coordinates are normalized to the capture frame
(0..1, origin top-left) so the Mac doesn't need to track actual pixel
dimensions. Times are in milliseconds from the start of the gesture.

```json
{"t":"screen_input","v":2,"kind":"tap","x":0.48,"y":0.72}
{"t":"screen_input","v":2,"kind":"down","x":0.1,"y":0.2,"pid":0}
{"t":"screen_input","v":2,"kind":"move","x":0.3,"y":0.4,"pid":0}
{"t":"screen_input","v":2,"kind":"up","x":0.3,"y":0.4,"pid":0}
{"t":"screen_input","v":2,"kind":"swipe","points":[{"x":0.1,"y":0.2,"tMs":0},{"x":0.3,"y":0.4,"tMs":150}]}
{"t":"screen_input","v":2,"kind":"key","key":"back"}
{"t":"screen_input","v":2,"kind":"text","text":"hello"}
```

`kind` values:
- `tap` — one-shot tap at (x, y).
- `down` / `move` / `up` — continuous pointer; `pid` is 0..9 so the Mac can
  support multitouch if it ever wants to. Phone dispatches via
  `AccessibilityService.dispatchGesture` with piecewise strokes.
- `swipe` — pre-computed gesture with a waypoint list. Handy for the Mac to
  synthesize wheel-to-swipe.
- `key` — system key: `back`, `home`, `recents`, `power`, `wake`,
  `volume_up`, `volume_down`, `notifications`, `quick_settings`. Dispatched
  via `AccessibilityService.performGlobalAction` where possible.
- `text` — UTF-8 string typed into whatever view has focus. Dispatched via
  `AccessibilityService` focused-node `ACTION_SET_TEXT` (falls back to
  appending for editable views).

Events arriving before `screen_ready` are discarded.

---

## End-to-end notification test

### `test_request` — server → client
Mac asks the phone to post a real local notification *from the NotifMirror app
package*. Android's own `MirrorListenerService` then catches that notification
and mirrors it back through the normal `posted` flow, exercising the entire
pipeline (WS out → NotificationManager → NotificationListener → WS in →
macOS banner). Mac correlates the round-trip via `reqId`, which it expects to
appear verbatim in the returned `posted.text`.

```json
{"t":"test_request","v":2,"reqId":"r7"}
```

The phone uses an `IMPORTANCE_DEFAULT` channel so the resulting notification
isn't classified as silent, and it includes `reqId` in the body. Failure modes
(no listener bound, NotificationManager unavailable) are silent on the wire —
the Mac surfaces a timeout if no matching `posted` arrives within ~5 s.

---

## Muted-app sync (`blocklist`)

Both sides keep an independent per-package mute list; this message keeps the
two converged. It carries the **full snapshot**, not deltas.

### `blocklist` — either direction

```json
{"t":"blocklist","v":2,"packages":[
  {"pkg":"com.whatsapp","blocked":true,"updatedAt":1710000000000},
  {"pkg":"com.telegram","blocked":false,"updatedAt":1710000000001}
]}
```

Each entry records the package, whether it's muted, and the wall-clock time
(epoch ms) of the **last local edit**. A peer that receives the snapshot
merges *per package* with "newest edit wins" (strict `>` on `updatedAt`) and
persists any change. Including `blocked:false` entries — not just mutes — is
what lets unmutes propagate.

Send policy, identical on both sides:
- on connect (right after `hello_ack`), push the current snapshot;
- after every local toggle of a package, push the full snapshot again.

Receivers never echo a received snapshot back, so there's no ping-pong; both
sides push on connect, and the max-timestamp merge converges to the most
recent edit per package.

---

## `ping` / `pong` — either direction

```json
{"t":"ping","v":2}
{"t":"pong","v":2}
```

### `error` — either direction

```json
{"t":"error","v":2,"code":"single_client","msg":"another client is connected"}
```

Known codes:
- `bad_secret` — HELLO auth failed; connection closes.
- `single_client` — another client already connected; connection closes.
- `bad_proto` — unsupported `proto`; connection closes.
- `malformed` — couldn't parse JSON; connection closes.

---

## Server policy

- **Single client**: at most one authenticated client. A second `hello`
  receives `error code="single_client"` and gets closed.
- **Heartbeat**: WebSocket control-frame ping every 30 s (`autoReplyPing`).
  App-level `ping` optional.
- **Frame size cap**: 8 MiB per WebSocket frame. Android down-scales `picture`
  and `artwork` to 1024 px longest-edge JPEG (80 %) before sending. File
  transfers chunk at 256 KiB to stay well inside the cap.

---

## Security model

Threat model: personal LAN, trusted operator (you). The wire is TLS-protected
(self-signed EC P-256 cert on the server, SPKI-pinned on the client via the
QR's `fp` field). A passive sniffer on the same Wi-Fi cannot read clipboard
text, notification bodies, file contents, or browse traffic. Forward secrecy
comes from TLS's ECDHE; replay protection from TLS sequence numbers. The
pre-shared 32-byte `secret` carried in HELLO is still required on top of TLS
— pinning proves *which* server, the secret proves *which* phone is allowed
to talk to it.

Out of scope: an active attacker who already controls the phone or the Mac.
A leaked QR (someone photographs the screen) is equivalent to a leaked
password — re-pair to rotate.

Pairing rotation: "Reset pairing" on the Mac regenerates BOTH the secret
AND the TLS cert; the listener restarts so the new identity takes effect.
Any previously paired device must re-scan the new QR — its old `fp` will
no longer match.
