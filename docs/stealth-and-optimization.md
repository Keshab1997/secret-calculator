# Stealth, Privacy & Firebase Cost Optimizations

This document tracks the architecture and behavior of the stealth, privacy, media caching, and Firebase cost-reduction improvements implemented across the app.

## 1. Stealth & Privacy Protections

1. **Auto-Lock to Calculator on Background:**
   - Whenever the user is inside the private messaging flow (`ChatsScreen`, `ChatScreen`, `PairingScreen`, `ProfileScreen`) and the app transitions to background/inactive (`AppLifecycleState.paused` or `hidden`) without an active voice/video call or system permission/picker dialog in progress, the navigation stack automatically pops back to the root `CalculatorScreen`.
   - Returning to the app always presents the ordinary Calculator screen first, requiring the secret passcode again.

2. **Recent Apps Blur & Screenshot Protection (`FLAG_SECURE`):**
   - Native Android `setSecureScreen(true)` sets `WindowManager.LayoutParams.FLAG_SECURE` while inside the secret messaging screens and clears it (`setSecureScreen(false)`) when returning to the Calculator screen.
   - Prevents screenshots, screen recording, and Recent Apps thumbnail leaks of private conversations while keeping the front Calculator screen looking normal.

3. **Quick Panic Gesture (Double-Tap AppBar Title to Hide):**
   - Double-tapping the chat header immediately triggers Quick Hide to pop back to the root Calculator screen and clear any open keyboard/panels.

4. **Decoy Passcode Mode:**
   - Optional decoy passcode (4–8 digits, distinct from the real unlock code) configurable from the `You` profile/security tab.
   - Entering the decoy code on the Calculator opens `ChatsScreen(decoyMode: true)`, which shows an empty private conversations list without exposing any paired rooms or real messages.

## 2. Firebase Bandwidth, Storage & Query Optimizations

5. **Client-Encrypted Photo Uploads:**
   - Photo bytes are encrypted with the room key before upload, stored under a random object name as `application/octet-stream`, and decrypted only after download. Decrypted photos use a bounded memory-only cache; no decrypted photo is seeded to disk.

6. **Firebase Storage Cleanup on Message Delete / Clear / Expiry:**
   - Explicit message deletion and clearing a conversation remove associated Storage objects best-effort. Expiry is handled by the server: a database trigger indexes expiring messages under `/expiring`, and a scheduled function removes expired messages and safe, room-confined image paths in batches. The client only hides expired messages locally; it does not perform expiry deletion.

7. **Temporary Voice Playback:**
   - `NativeBridgeService.playEncryptedAudio` decrypts the note to a temporary `.m4a` playback file, then removes it on stop or after the native player duration. Stale playback folders are removed on the next app launch. `MediaCacheService` retains only a bounded in-memory cache for decrypted photos and avatars.

8. **Bounded Directory & Chat Queries:**
   - `FirebaseService` enables Realtime Database disk persistence (`10 MB`) and bounds message streams (`limitToLast(150)` in active chats, `limitToLast(1)` for background calculator message checks, and bounded recent messages in the directory) while caching decrypted profiles and messages in memory.

## 3. Smooth Chat UX & Discreet Notifications

9. **Gboard / Rich Keyboard Sticker & Image Input (`contentInsertionConfiguration`):**
   - The chat composer `TextField` registers `ContentInsertionConfiguration` for `image/png`, `image/gif`, `image/webp`, and `image/jpeg`.
   - Selecting a sticker or rich image directly from Gboard writes the source bytes to a temporary file, encrypts them in the upload pipeline, and sends the encrypted photo into the current room. The source temp file is not used as a decrypted download cache.

10. **Discreet Single-Slot SMS Notifications:**
    - Notifications fire only for newly arrived partner messages when the user is not actively reading the chat in the foreground.
    - Uses a single notification slot (`id: 1997`, `onlyAlertOnce: true`, Android tag `calculator_sync`) and a 25-second cooldown with message-ID deduplication so lock screens never accumulate suspicious notification stacks. Tapping the notification opens the app to the Calculator screen.
