# SiCal

SiCal is a calendar app for iOS and Android powered by the Sia Network.

## Prerequisites

- Flutter SDK compatible with Dart 3.10+
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

The app uses the hosted `sia_storage` package for Sia SDK bindings.
Its native library is compiled at build time via Dart build hooks, so keep the
Rust toolchain available on developer machines and CI.

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