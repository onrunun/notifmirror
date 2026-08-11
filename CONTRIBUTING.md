# Contributing

Thanks for considering a contribution to NotifMirror. This project is a
personal LAN tool, so a few things are deliberately kept simple — please
read [`README.md`](README.md) and [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md)
first to understand the architecture and the wire format.

## Ground rules

- **Backward compatibility on the wire**: the protocol is versioned. Adding
  a new message type is fine (unknown `t` values are ignored), but changing
  an existing field's meaning breaks older peers. Bump `PROTO_VERSION`
  (both `WireCodec`s) when you do.
- **No speculative abstraction**: keep changes small and targeted. Prefer the
  dependency already in the project over a new one.
- **Both platforms stay in sync**: the codec is mirrored in Kotlin
  (`android/.../protocol/Messages.kt`) and Swift (`mac/NotifMirror/Net/Protocol.swift`).
  If you touch one, update the other and the docs in `protocol/PROTOCOL.md`.

## Setup

See the "Prerequisites" section of the README. You'll need `xcodegen`,
`swiftlint`, JDK 17+, and the Android SDK.

## Before opening a PR

Run the same checks CI runs:

```sh
# Android
cd android
./gradlew :app:testDebugUnitTest :app:lintDebug detekt

# macOS
cd mac
swiftlint lint --config .swiftlint.yml
xcodegen generate
xcodebuild -project NotifMirror.xcodeproj -scheme NotifMirror \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual test
```

New code must be lint-clean. If you touch the wire codec, extend both test
suites (`android/.../WireCodecTest.kt` and `mac/NotifMirrorTests/WireCodecTests.swift`)
with the same round-trips.

## Committing

- Write concise, imperative commit messages.
- Don't commit machine-specific config (`local.properties`, `JAVA_HOME`
  paths, signing keys).
- Update `CHANGELOG.md` under `[Unreleased]`.

## Releasing

```sh
./scripts/bump-version.sh 1.1.0   # bumps version in both apps + changelog, tags v1.1.0
git push --follow-tags            # CI builds a draft GitHub Release from the tag
```
