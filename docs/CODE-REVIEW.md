# Code Review & Fix Plan

Secret Calculator (`com.keshabstudios.calculator`)

Reviewed at commit `7007c4e` on `main`. This document lists every issue found, in the
order they should be fixed, with the exact file/line, why it is wrong, and the fix.

**Current state:** the app builds and launches on a real device. `flutter analyze`
reports 5 warnings and no errors; `flutter test` passes 1 smoke test. The core
2-device chat flow does **not** work end to end yet — see P0.

---

## How to verify your work

```bash
flutter analyze                 # must print "No issues found!"
flutter test                    # must stay green
flutter run -d <device-id>      # flutter devices to list
```

Two-device testing tip: `flutter run -d <phone>` plus one emulator
(`flutter emulators --launch <id>`), or use Firebase Auth-free "anonymous" testing by
opening `rooms/<code>` directly in the Firebase Console to inspect what is written.

---

## Priority summary

| # | Issue | Severity | Files |
|---|-------|----------|-------|
| P0-1 | ~~Pairing is broken: 6-char code can never resolve to the real room key~~ ✅ fixed | Blocker | `firebase_service.dart`, `pairing_screen.dart` |
| P0-2 | ~~`senderId` stores the room id, not the sender~~ ✅ fixed | Blocker | `firebase_service.dart`, `chat_screen.dart` |
| P0-3 | ~~Messages duplicate on every update~~ ✅ fixed | High | `chat_screen.dart` |
| P0-4 | ~~Both peers write to the same `status` node (online/last seen is wrong)~~ ✅ fixed | High | `firebase_service.dart`, `chat_screen.dart` |
| P1-1 | ~~"Encryption" is a hardcoded key + fixed IV, AES-128 not AES-256~~ ✅ fixed (AES-256-GCM + random 12-byte nonce + per-room PBKDF2 key) | High (security) | `encryption_service.dart` |
| P1-2 | ~~No Firebase Realtime Database / Storage security rules~~ ✅ fixed (`database.rules.json`, `storage.rules`, `firebase.json`) | High (security) | repo root |
| P1-3 | ~~`google-services.json` committed to a public repo~~ ✅ fixed in `26d6f21` | High (security) | `android/app/google-services.json` |
| P2-1 | ~~Almost no tests (1 smoke test) though CI runs tests~~ ✅ fixed (18 unit + widget tests) | Medium | `test/` |
| P2-2 | ~~5 analyzer warnings~~ ✅ fixed (`No issues found!`) | Low | `chat_screen.dart` |
| P2-3 | ~~Message/status `StreamSubscription`s never cancelled~~ ✅ fixed | Medium | `chat_screen.dart`, `pairing_screen.dart` |
| P3-1 | Voice/video call buttons are "coming soon" stubs | Low / intentional | `chat_screen.dart` |

---

## P0-1 — Pairing flow is broken (chat can never start)

**Symptom:** the person who enters a friend's 6-character code always gets
`Room not found`.

**Root cause:** `createRoom()` uses a Realtime Database `push()` key (≈20 chars, e.g.
`-Nxxxx…`) as the room id, but only the **first 6 characters** are shown to the user.
`joinRoom()` then looks up `rooms/<the 6-char code>`, which never exists.

`lib/services/firebase_service.dart:23-53`
```dart
Future<String> createRoom() async {
  final roomRef = FirebaseDatabase.instance.ref().child('rooms').push(); // <-- 20-char key
  _roomId = roomRef.key;
  ...
}

Future<bool> joinRoom(String roomCode) async {
  final roomRef = FirebaseDatabase.instance.ref().child('rooms').child(roomCode); // <-- 6 chars
  ...
}
```
`lib/services/firebase_service.dart:119-123`
```dart
String getShortCode() {
  if (_roomId == null) return '';
  return _roomId!.substring(0, 6).toUpperCase();
}
```

Second, smaller bug: `getShortCode()` upper-cases the code but
`pairing_screen.dart:55` calls `joinRoom(code.toLowerCase())`. Push keys are
case-sensitive, so even a correct-length code would not match after lower-casing.

**Fix (recommended): make the code itself the room key.** No lookup table needed.

```dart
// firebase_service.dart
static const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I
final _random = Random.secure();

String _generateCode() => List.generate(
      6,
      (_) => _codeAlphabet[_random.nextInt(_codeAlphabet.length)],
    ).join();

Future<String> createRoom() async {
  final code = _generateCode();
  final roomRef = FirebaseDatabase.instance.ref().child('rooms').child(code);
  await roomRef.set({'createdAt': ServerValue.timestamp});
  _roomId = code;                 // the code IS the room key now
  _chatRef = roomRef.child('messages');
  return code;
}

Future<bool> joinRoom(String code) async {
  _roomId = code.trim().toUpperCase();   // same normalisation both sides
  final roomRef = FirebaseDatabase.instance.ref().child('rooms').child(_roomId!);
  final snapshot = await roomRef.get();
  if (!snapshot.exists) {
    _roomId = null;
    return false;
  }
  _chatRef = roomRef.child('messages');
  return true;
}

String getShortCode() => _roomId ?? '';
```
Then in `pairing_screen.dart:55` pass the code **without** `toLowerCase()` — check it is
6 chars and `A-Z0-9` only before calling.

> Alternative if you keep push keys: add a `roomsByCode/{code} -> {roomId}` index and
> resolve it in `joinRoom`. Do not keep the substring approach: `substring(0, 6)` on a
> random push key is not unique and leaks room ids.

**Verify:** two devices, create on one, join with the shown code on the other, then
check both see the same `rooms/<CODE>` subtree in the Firebase Console.

---

## P0-2 — `senderId` stores the room id, not the sender

**Symptom:** your own messages render on the left (partner side), and you get a fake
notification for messages you sent yourself.

**Root cause:** the sent message records the room as the sender:

`lib/services/firebase_service.dart:62-67`
```dart
await _chatRef!.push().set({
  'text': encryptedText,
  'imageUrl': imageUrl,
  'timestamp': ServerValue.timestamp,
  'senderId': _roomId,          // <-- room id, identical on both devices
});
```
while the UI compares it against the short code:

`lib/screens/chat_screen.dart:104-115`
```dart
isMe: message['senderId'] == _firebase.getShortCode().toLowerCase(),   // never true
...
if (message['senderId'] != _firebase.getShortCode().toLowerCase()) {
  _notifications.showFakeNotification();                                // fires on own msgs
}
```

**Fix:** give each install a stable random identity and record that as the sender.

```dart
// firebase_service.dart
final String peerId = ...; // e.g. 16 random chars, persisted with shared_preferences
                           // so it survives restarts. Generate once per install.

// sendMessage(...)
await _chatRef!.push().set({
  'text': encryptedText,
  'imageUrl': imageUrl,
  'timestamp': ServerValue.timestamp,
  'senderId': peerId,
});
```
Then the UI compares the same value: `message['senderId'] == _firebase.peerId`.
Expose `String get myPeerId => peerId;` and use it in both places.

**Verify:** send from device A — the bubble is right-aligned on A and left-aligned on
B, with no notification on A.

---

## P0-3 — Messages duplicate on every update

**Symptom:** after a few messages, the list repeats earlier messages.

**Root cause:** the listener re-adds every child on every `onValue` emission. `onValue`
fires with the **whole list** each time, but the code appends without clearing.

`lib/screens/chat_screen.dart:89-119`
```dart
_firebase.getMessagesStream().listen((event) {
  if (event.snapshot?.value != null) {
    final data = event.snapshot!.value as Map<dynamic, dynamic>;
    data.forEach((key, value) {
      ...
      setState(() { _messages.add(ChatMessage(...)); });   // <-- re-added every event
    });
  }
});
```

**Fix — pick one:**

1. **Rebuild from the snapshot** (simplest, keeps ordering):
   ```dart
   final rebuilt = <ChatMessage>[];
   data.forEach((key, value) { rebuilt.add(...); });
   setState(() {
     _messages
       ..clear()
       ..addAll(rebuilt);
   });
   ```
2. **Use `onChildAdded`** and append only the new child (needs a separate
   `DatabaseReference` API — `_chatRef!.orderByChild('timestamp').onChildAdded`).

Also note `getMessagesStream()` uses `orderByChild('timestamp')`, so prefer the
snapshot rebuild above if you want to keep that ordering for free.

**Verify:** send 3 messages; exactly 3 bubbles remain after each send.

---

## P0-4 — Both peers write to the same `status` node

**Symptom:** "Online" / "Last seen" reflects your own device, not your partner's.

**Root cause:** both devices write to `rooms/<roomId>/status`, so each overwrite also
overwrites the other peer's state. There is no per-peer status.

`lib/services/firebase_service.dart:90-117`
```dart
final statusRef = FirebaseDatabase.instance
    .ref().child('rooms').child(_roomId!).child('status');   // one shared node
await statusRef.set({'isOnline': isOnline, 'lastSeen': ServerValue.timestamp});
```
```dart
Stream<DatabaseEvent> getPartnerStatusStream() {
  return FirebaseDatabase.instance
      .ref().child('rooms').child(_roomId!).child('status')  // reads back my own writes
      .onValue;
}
```

**Fix:** key status by peer, then listen to the *other* peer's node.

```dart
Future<void> updateOnlineStatus(bool isOnline) async {
  if (_roomId == null) return;
  await FirebaseDatabase.instance
      .ref().child('rooms').child(_roomId!).child('status').child(peerId)
      .set({'isOnline': isOnline, 'lastSeen': ServerValue.timestamp});
}

Stream<DatabaseEvent> getPartnerStatusStream(String partnerPeerId) =>
    FirebaseDatabase.instance
        .ref().child('rooms').child(_roomId!).child('status').child(partnerPeerId)
        .onValue;
```
The partner id can be discovered from any message's `senderId` that is not your own.

**Verify:** background device A — device B shows "Last seen …" while A shows itself
online.

---

## P1-1 — The encryption is not real end-to-end encryption

`lib/services/encryption_service.dart` (whole file):
```dart
// Using a fixed key for simplicity (in production, use key exchange)
final _key = Key.fromUtf8('1997199719971997'); // 16 chars for AES-128
final _iv  = IV.fromUtf8('1997199719971997');  // 16 chars
```
Problems, most serious first:

1. **The key is a constant shipped inside the APK** and derived from the publicly
   documented secret code (`1997`, see `AGENTS.md`). Anyone can extract it and read
   every message. This is obfuscation, not encryption.
2. **A fixed IV is reused for every message.** In CBC that makes encryption
   deterministic: identical plaintexts produce identical ciphertext, leaking message
   equality and structure. Every message must use a fresh random IV.
3. **`AGENTS.md` claims AES-256.** A 16-byte key is AES-128. The claim is wrong (fix
   the doc or the code — don't leave the mismatch).
4. **`decrypt()` swallows failures** and returns the ciphertext unchanged
   (`encryption_service.dart:24-26`), so corruption and wrong-key cases look like
   normal text instead of erroring.
5. **Images are not encrypted at all** — `uploadImage()` stores the raw file in
   Firebase Storage (`firebase_service.dart:79-88`) and saves a plain `imageUrl`.

**Fix (target design):**
- Per-room shared secret negotiated with **X25519 ECDH** (see package `cryptography`),
  or derive from a room passphrase with **Argon2/PBKDF2**.
- Encrypt each message with **AES-256-GCM** (`cryptography` package) using a
  **random 12-byte nonce per message**, stored alongside the ciphertext, e.g.
  `{ "ct": base64, "nonce": base64 }`.
- Throw/return an error on decrypt failure instead of returning the input.
- Encrypt images client-side before upload (or accept the risk and document it).

**Verify:** two devices decrypt each other's messages; the same plaintext sent twice
produces two different ciphertexts in the console.

> If a real key exchange is out of scope right now, the minimum honest fix is: random
> IV per message + store it, AES-256-GCM, keep the hardcoded key but **stop calling it
> AES-256 E2E** in `AGENTS.md` and the UI.

---

## P1-2 — No Firebase security rules

There is no `firebase.json`, `database.rules.json`, or `storage.rules` in the repo
(`find . -name "*.rules" -o -name firebase.json` returns nothing). If the project is
in Realtime Database "test mode", **anyone with the project URL can read every room**,
including the (weakly) encrypted messages and all uploaded image URLs — authentication
is not required.

**Fix:** add and deploy rules.

`database.rules.json`
```json
{
  "rules": {
    "rooms": {
      "$room": {
        ".read": true,
        ".write": true,
        "messages": { ".indexOn": ["timestamp"] }
      }
    }
  }
}
```
This at least adds the `timestamp` index (the code queries `orderByChild('timestamp')`
without an index, which logs a "Using an unspecified index" warning and downloads the
whole tree). Because rooms are joined by a shared code with no auth, true access
control needs Firebase Auth — plan that as a follow-up, and until then treat every
message as public. Minimum steps:

1. Restrict read/write so nothing outside `rooms/$room` is reachable.
2. Add `.indexOn: ["timestamp"]`.
3. Add `storage.rules` so `images/` is not world-writable.

**Verify:** `firebase deploy --only database,storage`; in the console try reading a
non-existent top-level path and confirm it is denied.

---

## P1-3 — `google-services.json` committed to a public repo — ✅ fixed in `26d6f21`

`android/app/google-services.json` was tracked (`git ls-files` listed it) and there was
no `.gitignore` entry for it, even though `AGENTS.md` says it must never be committed.
It contains the project id, API key and app id, so it was public in
`github.com/Keshab1997/secret-calculator`.

**Fixed:** the file is untracked (`git rm --cached`) and ignored; CI now writes it from
the `GOOGLE_SERVICES_JSON_BASE64` repository secret before the build
(`manual-build.yml` forwards the secret, `publish-release.yml` inherits it and sets
`preflight-require-firebase: true`). `flutter-builder`'s `doctor.sh` now reports
`google-services.json … not tracked by git` and
`GOOGLE_SERVICES_JSON_BASE64 forwarded by every build workflow`.

To re-set the secret after changing the Firebase project:

```bash
openssl base64 -A -in android/app/google-services.json \
  | gh secret set GOOGLE_SERVICES_JSON_BASE64 --repo Keshab1997/secret-calculator
```

**Still outstanding:** the file remains in git **history**, so the old API key is still
readable there. **Rotate/restrict the API key in the Firebase Console** (Google Cloud
Console → APIs & Services → Credentials → restrict the key to the Android app +
Firebase APIs). Purging history would need a `git filter-repo` rewrite and a force
push, which is not worth it once the key is rotated.

---

## P2-1 — Almost no tests

`test/widget_test.dart` is a single 9-line smoke test. CI (`ci.yml`) runs format +
tests, so the suite passing proves very little. Good first targets, in order of value:

1. **`EncryptionService`** — round-trip `decrypt(encrypt(x)) == x`; different ciphertext
   for the same input (this test will **fail** today because of the fixed IV — that is
   the point).
2. **Calculator logic** — extract `_calculate`/`_percentage` into a testable helper
   (they are currently private methods inside a `State`), then test `+ - × ÷ %`,
   divide-by-zero, decimals, and the `1997` secret-code buffer.
3. **`getShortCode()`/code generation** — 6 chars, unambiguous alphabet, upper-cased.
4. **Widget test** — typing `1997` navigates to `PairingScreen`.

Add `firebase_database` mocks or keep services injectable so tests do not touch the
network.

---

## P2-2 — Analyzer warnings (5)

```
warning • Unused import: 'package:firebase_database/firebase_database.dart'
          • lib/screens/chat_screen.dart:3:8 • unused_import
warning • The receiver can't be null, so the null-aware operator '?.' is unnecessary
          • lib/screens/chat_screen.dart:91:25 • invalid_null_aware_operator
warning • The '!' will have no effect because the receiver can't be null
          • lib/screens/chat_screen.dart:92:36 • unnecessary_non_null_assertion
warning • The receiver can't be null, so the null-aware operator '?.' is unnecessary
          • lib/screens/chat_screen.dart:125:25 • invalid_null_aware_operator
warning • The '!' will have no effect because the receiver can't be null
          • lib/screens/chat_screen.dart:126:36 • unnecessary_non_null_assertion
```

**Fix:** remove the unused `firebase_database` import from `chat_screen.dart` (it was
only needed for the now-correct typed stream) and replace `event.snapshot?.value` /
`event.snapshot!.value` with `event.snapshot.value` (a `DatabaseEvent` always has a
non-null `snapshot`). Target: `flutter analyze` → "No issues found!".

---

## P2-3 — Stream subscriptions are never cancelled

`lib/screens/chat_screen.dart:64-78` starts two subscriptions
(`getMessagesStream`, `getPartnerStatusStream`) in `initState` but `dispose()` does not
cancel them. After leaving the chat screen the listeners keep firing and call
`setState` on a disposed `State` (a "setState() called after dispose()" crash, and a
leak on every visit).

**Fix:**
```dart
StreamSubscription<DatabaseEvent>? _messagesSub;
StreamSubscription<DatabaseEvent>? _statusSub;

// initState
_messagesSub = _firebase.getMessagesStream().listen(_onMessages);
_statusSub   = _firebase.getPartnerStatusStream(...).listen(_onStatus);

// dispose
await _messagesSub?.cancel();
await _statusSub?.cancel();
```

---

## P3-1 — Call buttons are stubs

`lib/screens/chat_screen.dart:196-230` shows `Voice call feature coming soon!` /
`Video call feature coming soon!` snackbars. This matches `AGENTS.md` ("voice/video
calling UI"), so it is intentional — either build it (e.g. `flutter_webrtc`) or leave
it, but keep `AGENTS.md` honest that it is UI-only.

---

## Appendix — what was already fixed (commits `3c6ef65`…`7007c4e`)

These were blocking the build and are done:

- **`3c6ef65`** `android/build.gradle.kts` — a previous commit had replaced the
  `allprojects { repositories … }` block with a `plugins { … }` block declaring AGP
  `8.7.0`, which both broke the file's syntax and conflicted with AGP `9.1.0` declared
  in `settings.gradle.kts`. Restored the `allprojects` block. Also enabled core library
  desugaring (`isCoreLibraryDesugaringEnabled = true`, `desugar_jdk_libs:2.1.4`) which
  `flutter_local_notifications` requires.
- **`493d871`** corrected invalid imports `package:firebase_database.dart` →
  `package:firebase_database/firebase_database.dart` (and the same for
  `firebase_storage`) in `firebase_service.dart` and `chat_screen.dart`.
- **`7007c4e`** refreshed `pubspec.lock` after upgrading Flutter 3.47.4 → 3.47.7
  (the project requires Dart `^3.13.5`).

Known non-blocking warning while building:
`applies the Kotlin Gradle Plugin, which will cause build failures in future versions of
Flutter` — see https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers
for the migration guide.
