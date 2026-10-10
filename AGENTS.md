# Secret Calculator - Agent Notes

## Project Overview
A secret messaging app disguised as a calculator. When the secret code `1997` is entered, it reveals a hidden messaging interface.

## Features
- Full calculator functionality (+, -, ×, ÷, %)
- Secret code detection (1997)
- Hidden messaging screen with:
  - Text chat
  - Emoji support
  - Image sharing
  - Voice/video calling
  - SMS integration

## Technical Stack
- Flutter 3.47.7
- Dart
- Material Design 3

## Build Notes
- Use `flutter run` to test
- Use `flutter build apk` for Android release
- Use `flutter build ios` for iOS release

## Agent Instructions
- Push to main branch directly
- Use conventional commits: feat(update):, fix(auth):, chore(ci):
- Never commit secrets (*.jks, *.keystore, key.properties, google-services.json)