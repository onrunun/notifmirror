# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.2] - 2026-09-03

### Added
- Android: "Send to Mac" option in the system text-selection toolbar (`ACTION_PROCESS_TEXT`) to instantly send highlighted text to the Mac.
- Mac: Clip-arrival user notification when text is received from the phone.
- Mac: If clipboard sync is disabled, incoming text is held and clicking the notification banner copies it and offers to enable sync.

### Changed
- Android: Improved permission descriptions and setup tips in SetupScreen and HomeScreen.

## [1.1.1] - 2026-08-11

### Added
- Muted-app list now syncs between the phone and the Mac via a new `blocklist`
  wire message: each side pushes its full snapshot on connect and after every
  toggle, and peers merge per package with "newest edit wins" — unmutes
  propagate too, with no ping-pong.
- Android: home screen now shows a battery card, a now-playing (media) card,
  and a transfer-history card for live and recent file transfers.
- Android: new "Notifications" (POST_NOTIFICATIONS) row in the permissions
  card, needed for received-file notifications and the Mac's E2E test.

### Fixed
- Android: E2E test notifications are dropped silently when
  POST_NOTIFICATIONS is missing — the app now warns in the log and the Mac's
  timeout message points at the right permission.
- Android: outgoing file pump resumes from the stored offset instead of
  restarting from byte zero.
- Mac: QR code scales to fill its container instead of staying fixed-size.

## [1.1.0] - 2026-08-11

### Added
- JVM unit tests for the Android wire codec (`WireCodecTest`) and an
  XCTest suite for the macOS wire codec + pairing payload (`NotifMirrorTests`).
  Both suites exercise the same round-trips so a protocol change on either
  platform is caught by the other platform's CI.
- GitHub Actions CI: Android (unit tests, Detekt, Android Lint, debug APK)
  and macOS (SwiftLint, build, XCTest) on every push/PR.
- GitHub Actions release workflow: tag push (`v*`) builds a release APK +
  macOS bundle and drafts a GitHub Release from the changelog.
- Dependabot config for Gradle and GitHub Actions.
- `.editorconfig`, SwiftLint config (`mac/.swiftlint.yml`), Detekt config
  (`android/config/detekt`).
- `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, PR/issue templates.
- `scripts/bump-version.sh` to bump version in one place and tag.

### Changed
- Gradle no longer hardcodes a machine-specific `org.gradle.java.home`;
  `scripts/build-and-deploy.sh` falls back to the Android Studio JBR when
  `JAVA_HOME` is unset. CI sets `JAVA_HOME` explicitly.

### Fixed
- Android lint `NewApi` crash on API 26–27: `RemoteInput.setResultsSource`
  now gated behind `Build.VERSION.SDK_INT >= 28`.
- Android lint opt-in and manifest fixes in the QR camera path.
- macOS: TLS identity is now built in memory via `SecKeyCreateWithData` +
  `SecIdentityCreate` instead of `SecPKCS12Import`, which imported the key
  into the login keychain and re-prompted "NotifMirror wants to sign using
  key" on every launch.

## [1.0] - 2026-08-11

Initial public release.
