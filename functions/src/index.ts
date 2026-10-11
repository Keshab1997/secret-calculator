import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

admin.initializeApp();

const db = admin.database();
const messaging = admin.messaging();

// Region must match the database region (asia-southeast1) for co-located functions.
export const onNewMessage = functions
    .region('asia-southeast1')
    .database.ref('/rooms/{roomId}/messages/{messageId}')
    .onCreate(async (snapshot, context) => {
      // Exit if this is an expiry-only update (no text/image/audio)
      const data = snapshot.val();
      if (!data || (!data.text && !data.imageUrl && !data.audioUrl)) {
        return null;
      }

      const { roomId } = context.params;
      const senderId = data.senderId;
      if (!senderId || typeof senderId !== 'string') {
        return null;
      }

      // Find the other peer's FCM token in the same room
      const tokensSnap = await db
          .ref(`rooms/${roomId}/tokens`)
          .once('value');
      const tokens = tokensSnap.val() || {};

      const partnerToken = Object.entries(tokens).find(
          ([peerId]) => peerId !== senderId
      )?.[1];

      if (!partnerToken || typeof partnerToken !== 'string') {
        // No partner device registered for push — local notifications will
        // still fire if the app is open or backgrounded.
        return null;
      }

      // Build a disguised notification so the app still looks like a calculator
      const notificationTitle = 'Calculator';
      const notificationBody = '📊 New calculation saved';

      const payload: admin.messaging.Message = {
        notification: {
          title: notificationTitle,
          body: notificationBody,
        },
        token: partnerToken,
        data: {
          // Extra data so the app can route the tap to open the chat.
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
          roomId: roomId,
          messageId: context.params.messageId,
        },
        android: {
          priority: 'high',
          notification: {
            sound: 'default',
            channelId: 'calculator_channel_v2',
          },
        },
        apns: {
          payload: {
            aps: {
              sound: 'default',
            },
          },
        },
      };

      try {
        await messaging.send(payload);
      } catch (err) {
        // Token may be stale — best-effort cleanup.
        console.error('Failed to send FCM:', err);
      }

      return null;
    });
