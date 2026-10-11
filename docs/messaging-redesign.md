# Messaging redesign

## Navigation

The calculator stays the launch screen. The existing secret code and optional
biometric gate now open **Chats**, with **Calls** and **You** tabs. Quick Hide
returns to the calculator (overflow menu inside a conversation).

- Pair new contact creates a new room without forgetting older paired rooms.
- Each directory row uses that room's messages/profile, last-message time and
  actual unseen incoming-message count. Search matches name or room code.
- You edits name, About and a small gallery photo. Save persists locally and
  publishes an encrypted profile to each paired room. Both phones should update
  to this version to display names/photos and the new sticker/call records.
- Each pairing has its own invite code; there is no public/global user directory.
- Unpair removes only the selected contact locally and its notification token;
  shared history is **not** deleted. Clear chat remains an explicit action.

## Conversation

White header, cream original line-art wallpaper, green outgoing and white
incoming bubbles, date chips, photo/camera attachments, a rounded composer,
voice-note hold/release/cancel, reply/reactions/search and disappearing messages.
The emoji picker edits the actual composer (including backspace). The searchable
four-column sticker grid includes original offline heart/bear drawings and the
existing emoji-based catalogue. Sticker messages use encrypted `sticker:v1:`
payloads and render without a regular bubble. Older clients show that marker as
text; ordinary older messages remain readable.

Voice/video call buttons use the existing WebRTC implementation. Newly ended
calls produce a deterministic `messages/call_<startedAt>` record and appear in
Calls and the conversation. Duration means connected call-state duration, not
an independently verified media-flow metric. No historical call records are
invented. Calls still need both clients reachable; background ringing/CallKit,
TURN service, and a missed-call timeout are not added by this UI batch. When a
conversation is open, incoming-call handling remains scoped to that room.

No Meta AI, Updates, payment UI, third-party GIF service or Gboard sticker
catalogue is included. No workflow, Firebase rules, secrets or project settings
were modified. Profiles use the existing room-code access model, not a new
authenticated account system; this is not a security redesign or a claim of
WhatsApp-equivalent security.

## Migration and checks

`pairedRooms` and `profile` are additive local state fields. The old `roomId`
is imported into the directory; peer ID, custom passcode, biometric preference
and existing remote message paths are retained. Switching waits for the previous
route to finish disposal before changing the singleton's room encryption key.
The async photo send path verifies the room has not changed before sending.

Local tests cover legacy migration, multiple-room persistence, selective unpair,
unknown-room rejection, profile validation/key isolation, calculator navigation,
profile tabs, sticker search/empty state, 320px chat layout, keyboard back handling,
and the existing hold-to-record gestures. UI captures are generated with fixture
messages locally, not copied from a real user's conversations.

### Device acceptance (still required)

1. Upgrade two previously paired phones: verify old messages and secret code.
2. Save distinct profiles on both and verify names/photos update in Chats.
3. Pair a third phone as a second conversation; switch A/B and verify messages,
   encryption, unread badges and notifications never cross rooms.
4. Send text, photo, emoji/sticker, reply and voice note in both conversations.
5. Complete/decline voice and video calls and inspect both clients' records.
6. Kill/reopen the app; verify directory/profile persist; unpair only one contact.
7. Test Quick Hide with the sticker panel open and the calculator disguise.

No production Firebase interactions or on-device Android build are performed by
widget/unit tests. The user owns the CI and manual Android build buttons.
