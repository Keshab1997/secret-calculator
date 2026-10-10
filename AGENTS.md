# Calculator - Secret Messaging App

## Project Overview
A secret messaging app disguised as a calculator. When the secret code `1997` is entered, it reveals a hidden messaging interface.

## App Identity
- **App Name:** Calculator (displays as "Calculator" on phone)
- **Package Name:** com.keshabstudios.calculator
- **Secret Code:** 1997

## Features
- Full calculator functionality (+, -, ×, ÷, %)
- Secret code detection (1997)
- Hidden messaging screen with:
  - Text chat (Firebase Realtime Database)
  - Emoji support (32+ emojis)
  - Image sharing (Firebase Storage)
  - Voice/video calling UI
  - End-to-End Encryption (AES-256)
  - Fake notifications (calculator-themed)
  - Online status tracking
  - Last seen feature
  - One-time pairing system

## Technical Stack
- Flutter 3.47.7
- Dart
- Material Design 3
- Firebase Core
- Firebase Realtime Database
- Firebase Storage
- AES-256 Encryption

## Setup Requirements
1. Firebase project created
2. google-services.json in android/app/
3. Firebase Realtime Database enabled
4. Firebase Storage enabled

## CI/CD Workflows
- **Flutter CI**: Format check + Tests (manual trigger)
- **Manual Build**: APK/AAB build (manual trigger)
- **Web Preview**: GitHub Pages deployment (manual trigger)

## Build Notes
- Use `flutter run` to test
- Use `flutter build apk` for Android release
- Use `flutter build ios` for iOS release

## Agent Instructions
- Push to main branch directly
- Use conventional commits: feat(update):, fix(auth):, chore(ci):
- Never commit secrets (*.jks, *.keystore, key.properties, google-services.json)