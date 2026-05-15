# SiCal

SiCal is a calendar app for iOS and Android powered by the Sia Network.

## Prerequisites

- Flutter SDK compatible with Dart 3.9.x
- Rust toolchain (`rustup`, `cargo`)
- Android Studio / Android SDK for Android builds
- Xcode for iOS builds (macOS only)

Verify local setup:

```bash
flutter --version
dart --version
rustc --version
cargo --version
```

## Initial Setup

From the repository root:

```bash
flutter pub get
```

This project includes generated flutter_rust_bridge bindings in `lib/src/rust/`.
If Rust API changes require regeneration, use flutter_rust_bridge tooling and then run:

```bash
flutter pub get
```

## Run The App

List connected devices:

```bash
flutter devices
```

Run on a selected device/emulator:

```bash
flutter run
```

## Build

Android APK:

```bash
flutter build apk --release
```

Android App Bundle:

```bash
flutter build appbundle --release
```

iOS (macOS only):

```bash
flutter build ios --release
```

## Test

Run all Dart/Flutter tests:

```bash
flutter test
```

Run a specific test file:

```bash
flutter test test/ics_import_service_test.dart
```

## Static Analysis And Linting

Run analyzer:

```bash
flutter analyze
```

Format Dart code:

```bash
dart format .
```

## Rust Development

Run Rust checks inside the Rust crate:

```bash
cd rust
cargo check
cargo test
```

## Assets And Native UI Generation

Regenerate launcher icons:

```bash
dart run flutter_launcher_icons
```

Regenerate native splash screens:

```bash
dart run flutter_native_splash:create
```

## Acknowledgement

This work is supported by a [Sia Foundation](https://sia.tech/) grant.