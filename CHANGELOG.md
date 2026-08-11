# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
