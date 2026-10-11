import { initializeApp } from "firebase-admin/app";
import { getDatabase } from "firebase-admin/database";
import { getMessaging } from "firebase-admin/messaging";
import { getStorage } from "firebase-admin/storage";
import { info, error as logError } from "firebase-functions/logger";
import { onValueCreated } from "firebase-functions/v2/database";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import {
  hashInviteSecret,
  inviteHashMatches,
  isAllowedExpiry,
  isValidInviteSecret,
  isValidPeerId,
  isValidRoomId,
  safeImagePathForRoom,
} from "./security_helpers";

initializeApp();

// Keep in sync with FirebaseService.defaultDatabaseUrl (Flutter client).
const DATABASE_INSTANCE = "secret-calculator-fce20-default-rtdb";
const DATABASE_REGION = "asia-southeast1";
const MAX_ROOM_MEMBERS = 2;
const EXPIRING_INDEX_BATCH_SIZE = 500;

interface SecurePairingData {
  roomId: string;
  inviteSecret: string;
  peerId: string;
}

function parseSecurePairingData(data: unknown): SecurePairingData {
  if (typeof data !== "object" || data === null) {
    throw new HttpsError("invalid-argument", "Invalid pairing request.");
  }
  const value = data as Record<string, unknown>;
  if (
    !isValidRoomId(value.roomId) ||
    !isValidInviteSecret(value.inviteSecret) ||
    !isValidPeerId(value.peerId)
  ) {
    throw new HttpsError("invalid-argument", "Invalid pairing credentials.");
  }
  return {
    roomId: value.roomId,
    inviteSecret: value.inviteSecret,
    peerId: value.peerId,
  };
}

function requireAuthUid(request: { auth?: { uid: string } | null }): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to pair devices.");
  return uid;
}

/**
 * Create rooms only on the server. The invite secret is hashed before it is
 * written; only the creating member's authenticated UID is stored as a key.
 */
export const createRoomSecure = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    const { roomId, inviteSecret, peerId } = parseSecurePairingData(request.data);
    const roomRef = getDatabase().ref(`rooms/${roomId}`);
    const now = Date.now();
    const result = await roomRef.transaction(
      (current) => {
        if (current !== null) return;
        return {
          createdAt: now,
          createdBy: peerId,
          inviteSecretHash: hashInviteSecret(inviteSecret),
          members: {
            [uid]: { peerId, joinedAt: now },
          },
        };
      },
      undefined,
      false,
    );
    if (!result.committed) {
      throw new HttpsError("already-exists", "Choose another room code.");
    }
    return { roomId };
  },
);

/**
 * Join only after validating the 256-bit invite secret. A transaction caps a
 * room at two authenticated members, including under concurrent join calls.
 */
export const joinRoomSecure = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    const { roomId, inviteSecret, peerId } = parseSecurePairingData(request.data);
    const roomRef = getDatabase().ref(`rooms/${roomId}`);
    const now = Date.now();
    const result = await roomRef.transaction(
      (current) => {
        if (current === null || typeof current !== "object") return;
        const room = current as Record<string, unknown>;
        if (!inviteHashMatches(inviteSecret, room.inviteSecretHash)) return;
        const rawMembers = room.members;
        const members =
          rawMembers !== null && typeof rawMembers === "object"
            ? (rawMembers as Record<string, unknown>)
            : {};
        const ownMembership = members[uid];
        if (ownMembership === undefined && Object.keys(members).length >= MAX_ROOM_MEMBERS) {
          return;
        }
        if (ownMembership !== undefined) return room;
        return {
          ...room,
          members: {
            ...members,
            [uid]: { peerId, joinedAt: now },
          },
        };
      },
      undefined,
      false,
    );
    if (!result.committed) {
      const snapshot = await roomRef.get();
      if (!snapshot.exists()) {
        throw new HttpsError("not-found", "Secure invite not found.");
      }
      const room = snapshot.val() as Record<string, unknown>;
      if (!inviteHashMatches(inviteSecret, room.inviteSecretHash)) {
        throw new HttpsError("permission-denied", "Secure invite is invalid.");
      }
      const members =
        room.members !== null && typeof room.members === "object"
          ? (room.members as Record<string, unknown>)
          : {};
      if (members[uid] !== undefined) return { roomId };
      if (Object.keys(members).length >= MAX_ROOM_MEMBERS) {
        throw new HttpsError("resource-exhausted", "This room is already paired.");
      }
      throw new HttpsError("aborted", "Pairing could not be completed. Retry.");
    }
    return { roomId };
  },
);

/** Server-maintained expiry index; clients cannot write to /expiring. */
export const indexExpiringMessage = onValueCreated(
  {
    ref: "/rooms/{roomId}/messages/{messageId}",
    instance: DATABASE_INSTANCE,
    region: DATABASE_REGION,
  },
  async (event) => {
    const { roomId, messageId } = event.params;
    if (
      !isValidRoomId(roomId) ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(messageId)
    ) {
      return null;
    }
    const messageRef = getDatabase().ref(
      `rooms/${roomId}/messages/${messageId}`,
    );
    const result = await messageRef.transaction(
      (current) => {
        if (current === null || typeof current !== "object") return;
        const message = current as Record<string, unknown>;
        if (typeof message.expiresAt === "number") return message;
        const seconds = message.expiresInSeconds;
        if (!isAllowedExpiry(seconds)) return message;
        return {
          ...message,
          expiresAt: Date.now() + seconds * 1000,
        };
      },
      undefined,
      false,
    );
    if (!result.snapshot.exists()) return null;
    const saved = result.snapshot.val() as Record<string, unknown>;
    const expiresAt = saved.expiresAt;
    if (typeof expiresAt !== "number" || !Number.isFinite(expiresAt)) {
      return null;
    }
    await getDatabase().ref(`expiring/${roomId}_${messageId}`).set({
      roomId,
      messageId,
      expiresAt,
    });
    return null;
  },
);

/**
 * Removes expired messages and their encrypted Storage objects in bounded
 * batches. Running every five minutes avoids a client-side cleanup race while
 * keeping the database query on the indexed /expiring node.
 */
export const cleanupExpiredMessages = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "UTC",
    region: DATABASE_REGION,
    maxInstances: 1,
  },
  async () => {
    const database = getDatabase();
    const now = Date.now();
    const expiredSnapshot = await database
      .ref("expiring")
      .orderByChild("expiresAt")
      .endAt(now)
      .limitToFirst(EXPIRING_INDEX_BATCH_SIZE)
      .once("value");
    const indexed = (expiredSnapshot.val() ?? {}) as Record<string, unknown>;

    const entries = Object.entries(indexed);
    const concurrency = 20;
    for (let offset = 0; offset < entries.length; offset += concurrency) {
      const batch = entries.slice(offset, offset + concurrency);
      await Promise.all(
        batch.map(async ([indexKey, rawEntry]) => {
          let roomId: unknown;
          let messageId: unknown;
          try {
            if (rawEntry === null || typeof rawEntry !== "object") {
              await database.ref(`expiring/${indexKey}`).remove();
              return;
            }
            const entry = rawEntry as Record<string, unknown>;
            roomId = entry.roomId;
            messageId = entry.messageId;
            if (
              !isValidRoomId(roomId) ||
              typeof messageId !== "string" ||
              !/^[A-Za-z0-9_-]{1,128}$/.test(messageId)
            ) {
              await database.ref(`expiring/${indexKey}`).remove();
              return;
            }

            const indexRef = database.ref(`expiring/${indexKey}`);
            const messageRef = database.ref(`rooms/${roomId}/messages/${messageId}`);
            const messageSnapshot = await messageRef.once("value");
            if (!messageSnapshot.exists()) {
              await indexRef.remove();
              return;
            }
            const message = messageSnapshot.val() as Record<string, unknown>;
            const currentExpiry = message.expiresAt;
            if (typeof currentExpiry !== "number" || !Number.isFinite(currentExpiry)) {
              await indexRef.remove();
              return;
            }
            if (currentExpiry > now) {
              await indexRef.set({ roomId, messageId, expiresAt: currentExpiry });
              return;
            }

            const imagePath = safeImagePathForRoom(
              roomId,
              message.imagePath,
              message.imageUrl,
            );
            if (imagePath !== undefined) {
              await getStorage()
                .bucket()
                .file(imagePath)
                .delete({ ignoreNotFound: true });
            }
            await messageRef.remove();
            await indexRef.remove();
          } catch (cleanupError) {
            // Keep the index for the next scheduled attempt if an object or
            // database deletion failed partway through this cleanup.
            logError(
              `cleanupExpiredMessages failed for ${String(roomId)}/${String(messageId)}:`,
              cleanupError,
            );
          }
        }),
      );
    }
    return;
  },
);

// Fires when a new child appears under /rooms/{roomId}/messages/{messageId}.
// Sends a disguised "Calculator" push to the other peer so the app still
// looks like a calculator on the lock screen / notification shade.
export const onNewMessage = onValueCreated(
  {
    ref: "/rooms/{roomId}/messages/{messageId}",
    instance: DATABASE_INSTANCE,
    region: DATABASE_REGION,
  },
  async (event) => {
    const data = event.data.val() as {
      text?: string | null;
      imageUrl?: string | null;
      audioData?: string | null;
      audioUrl?: string | null;
      senderId?: unknown;
    } | null;

    // Skip expiry-only writes and non-message nodes (reactions/seen updates
    // don't create children, but guard anyway).
    if (
      !data ||
      (!data.text && !data.imageUrl && !data.audioData && !data.audioUrl)
    ) {
      return null;
    }

    const { roomId, messageId } = event.params;
    const senderId = data.senderId;
    if (!senderId || typeof senderId !== "string") {
      return null;
    }

    // Find all non-sender FCM tokens in the room (e.g. if a peer reinstalled
    // and generated a new peerId before the old stale entry was cleaned up).
    const tokensSnap = await getDatabase()
      .ref(`rooms/${roomId}/tokens`)
      .once("value");
    const tokens = (tokensSnap.val() || {}) as Record<string, unknown>;

    const partnerEntries = Object.entries(tokens).filter(
      ([peerId, token]) =>
        peerId !== senderId && typeof token === "string" && token.length > 0
    ) as Array<[string, string]>;

    if (partnerEntries.length === 0) {
      // No partner device registered for push — local notifications will
      // still fire if the app is open or backgrounded.
      info(`onNewMessage: no partner token in room ${roomId}, skipping push`);
      return null;
    }

    const seenTokens = new Set<string>();
    for (const [partnerPeerId, partnerToken] of partnerEntries) {
      if (seenTokens.has(partnerToken)) continue;
      seenTokens.add(partnerToken);

      try {
        await getMessaging().send({
          notification: {
            // Disguised so the app still looks like a calculator.
            title: "Calculator",
            body: "📊 New calculation saved",
          },
          token: partnerToken,
          data: {
            // Extra data so the app can route the tap to open the chat.
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            roomId: String(roomId),
            messageId: String(messageId),
          },
          android: {
            priority: "high",
            notification: {
              sound: "default",
              channelId: "calculator_channel_v2",
              tag: "calculator_sync",
            },
          },
          apns: {
            payload: {
              aps: {
                sound: "default",
              },
            },
          },
        });
        info(`onNewMessage: push sent in room ${roomId} to ${partnerPeerId}`);
      } catch (err: unknown) {
        // Token may be stale — drop it so the next message doesn't fail again.
        // The client re-registers its token via registerFcmToken() on join.
        const code =
          typeof err === "object" && err !== null && "code" in err
            ? String((err as { code: unknown }).code)
            : "";
        if (
          code.includes("registration-token-not-registered") ||
          code.includes("invalid-argument")
        ) {
          try {
            await getDatabase()
              .ref(`rooms/${roomId}/tokens/${partnerPeerId}`)
              .remove();
            info(`onNewMessage: removed stale token in room ${roomId}`);
          } catch (cleanupErr) {
            logError("Failed to remove stale FCM token:", cleanupErr);
          }
        } else {
          logError("Failed to send FCM:", err);
        }
      }
    }

    return null;
  }
);
