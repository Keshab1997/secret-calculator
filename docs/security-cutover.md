# Secure pairing and cleanup cutover

This repository contains the client, rules, and Cloud Functions changes only. **Nothing has been deployed to Firebase.** Before enabling the new pairing flow in production, review the scheduled-function/storage costs and then apply the Firebase Console and deployment steps that you manage.

## What changes

- Firebase Anonymous Authentication gives each installation a stable UID. Realtime Database reads are limited to authenticated room members; room creation and joining are server-only.
- Pairing now uses a six-character room ID plus a separate 256-bit, case-sensitive invite secret. The invite secret is stored in platform secure storage and only its SHA-256 hash is written to Realtime Database.
- Photos are encrypted on-device before upload, use random object names, and are decrypted into a bounded memory-only cache. Voice notes use a temporary playback file which is removed after playback/stop; stale temporary files are removed at next launch.
- A database trigger maintains `/expiring`; the scheduled function checks the indexed queue every five minutes and removes expired messages and their Storage objects. Each run is capped at 500 entries.
- Passcodes and room secrets move out of the JSON preferences file into platform secure storage.

## Required manual Firebase setup

1. Enable **Authentication → Sign-in method → Anonymous** for the Firebase project.
2. Review `database.rules.json`, `storage.rules`, and `functions/src/index.ts` against the production project and its configured Realtime Database instance/region.
3. Review the scheduled cleanup cadence. At the current `every 5 minutes` cadence it runs about 288 times/day, queries up to 500 indexed entries per run, and deletes Storage objects only when an expired message contains an image. Adjust the schedule/batch size before deployment if that cost profile is not acceptable.
4. After review, deploy the rules and functions from your own Firebase environment. This repository change does not run Firebase CLI or alter live Firebase settings.

## User migration

Existing six-character room codes are intentionally insufficient after the cutover. Existing users must pair each contact again with the full `ROOMID.SECRET` invitation and share it only through a trusted channel. A one-time in-app notice explains this; it can be dismissed after users understand the migration. Old room data is not automatically deleted by this code. Legacy messages do not have the new server-maintained expiry index, so decide separately whether to retain or remove that historical data during cutover.

The Storage rules require authentication, but Firebase download URLs are bearer URLs. Photo bytes are ciphertext before upload, and URLs are kept in member-readable message data; do not add plaintext media or secrets to logs or public channels.
