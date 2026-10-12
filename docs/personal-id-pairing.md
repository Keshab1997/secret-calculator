# Personal ID pairing: security and deployment notes

## Flow

1. Each anonymous Firebase Auth UID gets one randomly assigned, ten-character, unambiguous base-32 Personal ID. The ID is returned only to that authenticated UID; a private server-side index maps it to the UID. It remains stable while that UID exists. A reinstall or a different phone may sign in as a different anonymous UID and receive a different ID.
2. Entering another ID sends that owner a pending request. The sender’s request ID, peer ID, and P-256 public key are written by a callable; clients cannot write request, contact, mapping, or rate-limit records directly. No room is created at this stage.
3. The owner can accept or decline. Acceptance creates one new room for that contact, adds the two authenticated members, and writes owner-only contact-directory entries. Declining creates no room. A pair lock prevents simultaneous opposite-direction requests from making duplicate rooms.
4. Both clients compute P-256 ECDH locally and pass the shared value through HKDF-SHA-256, with the generated room ID bound into the KDF context. Only public keys cross Firebase. The resulting 32-byte room secret is stored in platform secure storage and used by the existing AES-GCM message encryption. Cloud Functions never receive or return the plaintext room secret.
5. Leaving a Personal-ID room removes the relationship from both directories, removes both members, and closes the accepted request so it cannot recreate a room. Existing paired-room data is retained. The updated client still accepts the legacy `ROOMID.SECRET` invite format, but hashes that secret locally and sends only a SHA-256 verifier to the legacy room callables; existing stored invite hashes remain compatible. Older app binaries that send the plaintext invite field must be updated before deploying the changed Functions.

## Important identity-authentication limitation

The first public keys are relayed by Firebase and are **not signed by a previously trusted identity key**. ECDH plus HKDF protects the key from being sent as plaintext, but it does not authenticate who controls either key. A malicious or compromised server can substitute keys during first pairing and mount a man-in-the-middle attack. The in-app warning is intentional: verify the other person’s Personal ID through a trusted independent channel if protection against that threat is required. Do not describe this first pairing as authenticated or as fully MITM-resistant end-to-end encryption.

The accept/decline screen supplies human approval, but approval alone does not cryptographically bind the person to the public key. A future authenticated design would need a trust anchor (for example, a key fingerprint checked out of band or a previously pinned signing key); merely signing keys with a newly generated key would not solve first-contact authentication.

## Firebase data boundaries

- `/users/{uid}` is readable only by the matching authenticated UID; clients cannot write below it.
- `/personalIds`, `/pendingContactRequests`, and `/internal` remain denied by the root rules. Callable Functions use Admin privileges to manage them.
- `/rooms/{roomId}` is created only after acceptance for this flow; existing member-only room read/write rules remain in force.
- `sendContactRequest` applies a per-UID request limit and a transaction lock per UID pair. Requests are owner-approved before room/member creation.

## Deployment

Firebase deployments are operator-managed; this workflow does not deploy Realtime Database rules or Functions. Before shipping a client built from this source, verify that the live rules and Functions match the current repository revision—especially if later code changes were made after a manual deployment. Do not assume a previous deployment includes those changes. Also verify anonymous Auth is enabled and anonymous-account automatic cleanup remains disabled so assigned IDs and contact directories do not unexpectedly disappear.
