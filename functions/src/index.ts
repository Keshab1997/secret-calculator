import { onValueCreated } from "firebase-functions/v2/database";
import { initializeApp } from "firebase-admin/app";
import { getDatabase } from "firebase-admin/database";
import { getMessaging } from "firebase-admin/messaging";
import { info, error as logError } from "firebase-functions/logger";

initializeApp();

// Keep in sync with FirebaseService.defaultDatabaseUrl (Flutter client).
const DATABASE_INSTANCE = "secret-calculator-fce20-default-rtdb";
const DATABASE_REGION = "asia-southeast1";

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
