## What does this change?

<!-- Brief summary of the intent and the user-visible effect, if any. -->

## Checklist

- [ ] Both platforms updated if the change touches the wire protocol
      (`android/.../protocol/Messages.kt`, `mac/.../Net/Protocol.swift`,
      `protocol/PROTOCOL.md`).
- [ ] Codec changes mirrored in both test suites
      (`android/.../WireCodecTest.kt`, `mac/NotifMirrorTests/WireCodecTests.swift`).
- [ ] Android checks pass: `./gradlew :app:testDebugUnitTest :app:lintDebug detekt`
- [ ] macOS checks pass: `swiftlint lint --config .swiftlint.yml` and
      `xcodebuild ... test` (see CONTRIBUTING.md).
- [ ] `CHANGELOG.md` updated under `[Unreleased]`.

## Testing

<!-- What did you test manually, and on which device / macOS version? -->

## Screenshots

<!-- Optional, only for UI changes. -->
