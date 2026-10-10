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
  - Text chat
  - Emoji support
  - Image sharing
  - Voice/video calling UI
  - SMS integration UI

## Technical Stack
- Flutter 3.47.7
- Dart
- Material Design 3
- Firebase (to be added)

## Build Notes
- Use `flutter run` to test
- Use `flutter build apk` for Android release
- Use `flutter build ios` for iOS release

## Agent Instructions
- Push to main branch directly
- Use conventional commits: feat(update):, fix(auth):, chore(ci):
- Never commit secrets (*.jks, *.keystore, key.properties, google-services.json)