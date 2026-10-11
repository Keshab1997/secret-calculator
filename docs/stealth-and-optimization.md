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

5. **Upload Pre-Seed Cache & Smart Compression:**
   - Image attachments continue using compact resize/compression (`maxWidth: 1280`, `imageQuality: 75`) and immediately seed `MediaCacheService` with the local bytes upon upload (`seedCachedImage(downloadUrl, sourceFile)`), so the sender never re-downloads their own uploaded photo from Firebase Storage.

6. **Firebase Storage Cleanup on Message Delete / Clear / Expiry:**
   - Deleting a message, pruning an expired disappearing message, or clearing a conversation also deletes any associated Firebase Storage object (`FirebaseStorage.instance.refFromURL(imageUrl).delete()`) best-effort so orphaned encrypted photos do not accumulate in cloud storage.

7. **Voice Note Disk Caching & Automatic Cache Pruning:**
   - Decrypted voice notes (`NativeBridgeService.playEncryptedAudio`) are cached deterministically by payload hash in `MediaCacheService` instead of writing a new temporary `.m4a` file on every play.
   - `MediaCacheService` enforces a bounded disk cache (pruning oldest cached media files when total size exceeds 50 MB).

8. **Bounded Directory & Chat Queries:**
   - `FirebaseService` enables Realtime Database disk persistence (`10 MB`) and bounds message streams (`limitToLast(150)` in active chats, `limitToLast(1)` for background calculator message checks, and bounded recent messages in the directory) while caching decrypted profiles and messages in memory.

## 3. Smooth Chat UX & Discreet Notifications

9. **Gboard / Rich Keyboard Sticker & Image Input (`contentInsertionConfiguration`):**
   - The chat composer `TextField` registers `ContentInsertionConfiguration` for `image/png`, `image/gif`, `image/webp`, and `image/jpeg`.
   - Selecting a sticker or rich image directly from Gboard writes the bytes to a temporary file, uploads it through the existing Storage pipeline, pre-seeds the local cache, and sends it into the current room.

10. **Discreet Single-Slot SMS Notifications:**
    - Notifications fire only for newly arrived partner messages when the user is not actively reading the chat in the foreground.
    - Uses a single notification slot (`id: 1997`, `onlyAlertOnce: true`, Android tag `calculator_sync`) and a 25-second cooldown with message-ID deduplication so lock screens never accumulate suspicious notification stacks. Tapping the notification opens the app to the Calculator screen.
