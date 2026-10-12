import { initializeApp } from "firebase-admin/app";
import { getDatabase } from "firebase-admin/database";
import { getMessaging } from "firebase-admin/messaging";
import { getStorage } from "firebase-admin/storage";
import { info, error as logError } from "firebase-functions/logger";
import { onValueCreated } from "firebase-functions/v2/database";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import {
  contactPairLockKey,
  generatePersonalId,
  generateRoomId,
  inviteSecretHashMatches,
  isAllowedExpiry,
  isValidInviteSecretHash,
  isValidKeyAgreementPublicKey,
  isValidPeerId,
  isValidPersonalId,
  isValidRequestId,
  isValidRoomId,
  normalizePersonalId,
  safeImagePathForRoom,
} from "./security_helpers";

initializeApp();

// Keep in sync with FirebaseService.defaultDatabaseUrl (Flutter client).
const DATABASE_INSTANCE = "secret-calculator-fce20-default-rtdb";
const DATABASE_REGION = "asia-southeast1";
const MAX_ROOM_MEMBERS = 2;
const EXPIRING_INDEX_BATCH_SIZE = 500;
const MAX_CONTACT_REQUESTS_PER_WINDOW = 20;
const CONTACT_REQUEST_WINDOW_MS = 24 * 60 * 60 * 1000;

interface SecurePairingData {
  roomId: string;
  inviteSecretHash: string;
  peerId: string;
}

function parseSecurePairingData(data: unknown): SecurePairingData {
  if (typeof data !== "object" || data === null) {
    throw new HttpsError("invalid-argument", "Invalid pairing request.");
  }
  const value = data as Record<string, unknown>;
  if (
    !isValidRoomId(value.roomId) ||
    !isValidInviteSecretHash(value.inviteSecretHash) ||
    !isValidPeerId(value.peerId)
  ) {
    throw new HttpsError("invalid-argument", "Invalid pairing credentials.");
  }
  return {
    roomId: value.roomId,
    inviteSecretHash: value.inviteSecretHash,
    peerId: value.peerId,
  };
}

function requireAuthUid(request: { auth?: { uid: string } | null }): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to pair devices.");
  return uid;
}

interface ContactRequestInput {
  personalId: string;
  requestId: string;
  peerId: string;
  publicKey: string;
}

interface ContactAcceptanceInput {
  requestId: string;
  peerId: string;
  publicKey: string;
}

function parseContactRequestInput(data: unknown): ContactRequestInput {
  if (typeof data !== "object" || data === null) {
    throw new HttpsError("invalid-argument", "Invalid contact request.");
  }
  const value = data as Record<string, unknown>;
  const personalId = normalizePersonalId(value.personalId);
  if (
    !personalId ||
    !isValidRequestId(value.requestId) ||
    !isValidPeerId(value.peerId) ||
    !isValidKeyAgreementPublicKey(value.publicKey)
  ) {
    throw new HttpsError("invalid-argument", "Invalid contact request details.");
  }
  return {
    personalId,
    requestId: value.requestId,
    peerId: value.peerId,
    publicKey: value.publicKey,
  };
}

function parseContactAcceptanceInput(data: unknown): ContactAcceptanceInput {
  if (typeof data !== "object" || data === null) {
    throw new HttpsError("invalid-argument", "Invalid contact approval.");
  }
  const value = data as Record<string, unknown>;
  if (
    !isValidRequestId(value.requestId) ||
    !isValidPeerId(value.peerId) ||
    !isValidKeyAgreementPublicKey(value.publicKey)
  ) {
    throw new HttpsError("invalid-argument", "Invalid contact approval details.");
  }
  return {
    requestId: value.requestId,
    peerId: value.peerId,
    publicKey: value.publicKey,
  };
}

async function ensurePersonalId(uid: string): Promise<string> {
  const database = getDatabase();
  const userIdRef = database.ref(`users/${uid}/personalId`);
  let expectedId: unknown = (await userIdRef.get()).val();

  if (isValidPersonalId(expectedId)) {
    const mapping = await database.ref(`personalIds/${expectedId}`).transaction(
      (current) => current === null || current === uid ? uid : undefined,
      undefined,
      false,
    );
    if (mapping.committed && mapping.snapshot.val() === uid) return expectedId;
  }

  for (let attempt = 0; attempt < 12; attempt += 1) {
    const candidate = generatePersonalId();
    const mappingRef = database.ref(`personalIds/${candidate}`);
    const reservation = await mappingRef.transaction(
      (current) => current === null || current === uid ? uid : undefined,
      undefined,
      false,
    );
    if (!reservation.committed || reservation.snapshot.val() !== uid) continue;

    const assignment = await userIdRef.transaction(
      (current) => {
        if (current === expectedId || !isValidPersonalId(current)) return candidate;
        return current;
      },
      undefined,
      false,
    );
    const assignedId = assignment.snapshot.val();
    if (assignedId === candidate) return candidate;

    await mappingRef.transaction(
      (current) => current === uid ? null : undefined,
      undefined,
      false,
    );
    if (isValidPersonalId(assignedId)) {
      expectedId = assignedId;
      const assignedMapping = await database
        .ref(`personalIds/${assignedId}`)
        .transaction(
          (current) => current === null || current === uid ? uid : undefined,
          undefined,
          false,
        );
      if (assignedMapping.committed && assignedMapping.snapshot.val() === uid) {
        return assignedId;
      }
    } else {
      expectedId = assignedId;
    }
  }
  throw new HttpsError(
    "resource-exhausted",
    "Could not allocate a Personal ID. Retry.",
  );
}

async function consumeContactRequestQuota(uid: string): Promise<void> {
  const now = Date.now();
  const quotaRef = getDatabase().ref(`internal/contactRequestLimits/${uid}`);
  const result = await quotaRef.transaction(
    (raw) => {
      const current =
        raw !== null && typeof raw === "object"
          ? (raw as { windowStartedAt?: unknown; count?: unknown })
          : {};
      const start = current.windowStartedAt;
      const count = current.count;
      if (
        typeof start !== "number" ||
        typeof count !== "number" ||
        now - start >= CONTACT_REQUEST_WINDOW_MS
      ) {
        return { windowStartedAt: now, count: 1 };
      }
      if (count >= MAX_CONTACT_REQUESTS_PER_WINDOW) return;
      return { windowStartedAt: start, count: count + 1 };
    },
    undefined,
    false,
  );
  if (!result.committed) {
    throw new HttpsError(
      "resource-exhausted",
      "Too many contact requests. Try again later.",
    );
  }
}

async function hasContactLink(uid: string, otherUid: string): Promise<boolean> {
  const value = (await getDatabase().ref(`users/${uid}/contacts`).get()).val();
  if (value === null || typeof value !== "object") return false;
  return Object.values(value as Record<string, unknown>).some(
    (raw) =>
      raw !== null &&
      typeof raw === "object" &&
      (raw as Record<string, unknown>).otherUid === otherUid,
  );
}

/**
 * Create rooms only on the server. Clients send the 64-character SHA-256
 * invite verifier, never the room encryption secret.
 */
export const createRoomSecure = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    const { roomId, inviteSecretHash, peerId } = parseSecurePairingData(request.data);
    const roomRef = getDatabase().ref(`rooms/${roomId}`);
    const now = Date.now();
    const result = await roomRef.transaction(
      (current) => {
        if (current !== null) return;
        return {
          createdAt: now,
          createdBy: peerId,
          inviteSecretHash,
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
 * Join only after validating the invite verifier. A transaction caps a room
 * at two authenticated members, including under concurrent join calls.
 */
export const joinRoomSecure = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    const { roomId, inviteSecretHash, peerId } = parseSecurePairingData(request.data);
    const roomRef = getDatabase().ref(`rooms/${roomId}`);
    const now = Date.now();
    const result = await roomRef.transaction(
      (current) => {
        if (current === null || typeof current !== "object") return;
        const room = current as Record<string, unknown>;
        if (!inviteSecretHashMatches(inviteSecretHash, room.inviteSecretHash)) return;
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
      if (!inviteSecretHashMatches(inviteSecretHash, room.inviteSecretHash)) {
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

/** Personal-ID discovery and approval-gated, per-contact room creation. */
/** Returns the per-install contact handle; the private key never leaves the device. */
export const getOrCreatePersonalId = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    return { personalId: await ensurePersonalId(uid) };
  },
);

/** Sends an authenticated request to the owner of a Personal ID. */
export const sendContactRequest = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    const input = parseContactRequestInput(request.data);
    await consumeContactRequestQuota(uid);
    const database = getDatabase();
    const senderPersonalId = await ensurePersonalId(uid);
    const ownerSnapshot = await database.ref(`personalIds/${input.personalId}`).get();
    const targetUid = ownerSnapshot.val();
    if (typeof targetUid !== "string") {
      throw new HttpsError("not-found", "No user has that Personal ID.");
    }
    if (targetUid === uid) {
      throw new HttpsError("invalid-argument", "You cannot add your own Personal ID.");
    }
    const registeredId = (await database.ref(`users/${targetUid}/personalId`).get()).val();
    if (registeredId !== input.personalId) {
      throw new HttpsError("not-found", "No user has that Personal ID.");
    }

    if (await hasContactLink(uid, targetUid)) {
      throw new HttpsError("already-exists", "You are already connected.");
    }

    const requestRef = database.ref(`users/${targetUid}/requests/${input.requestId}`);
    const priorRequest = await requestRef.get();
    if (priorRequest.exists()) {
      const prior = priorRequest.val() as Record<string, unknown>;
      if (prior.fromUid === uid && prior.publicKey === input.publicKey) {
        return { requestId: input.requestId, alreadySent: true };
      }
      throw new HttpsError("already-exists", "That request ID is already in use.");
    }

    const pairKey = contactPairLockKey(uid, targetUid);
    const pairLockRef = database.ref(`internal/contactPairLocks/${pairKey}`);
    const priorPairLock = (await pairLockRef.get()).val();
    try {
      const pairLock = await pairLockRef.transaction(
        (current) =>
          current === null || current === input.requestId
            ? input.requestId
            : undefined,
        undefined,
        false,
      );
      if (!pairLock.committed || pairLock.snapshot.val() !== input.requestId) {
        throw new HttpsError(
          "already-exists",
          "A request is already waiting for this person, or they have requested you.",
        );
      }
    } catch (error) {
      await pairLockRef.transaction(
        (current) => (current === input.requestId ? null : undefined),
        undefined,
        false,
      );
      throw error;
    }

    const pendingRef = database.ref(`pendingContactRequests/${targetUid}/${uid}`);
    let priorPendingId: unknown = null;
    try {
      if (await hasContactLink(uid, targetUid)) {
        throw new HttpsError("already-exists", "You are already connected.");
      }
      priorPendingId = (await pendingRef.get()).val();
      const pending = await pendingRef.transaction(
        (current) => {
          if (current === null || current === input.requestId) return input.requestId;
          return;
        },
        undefined,
        false,
      );
      if (!pending.committed || pending.snapshot.val() !== input.requestId) {
        throw new HttpsError(
          "already-exists",
          "A contact request is already waiting for this person.",
        );
      }
    } catch (error) {
      if (priorPairLock === null) {
        await pendingRef.transaction(
          (current) => (current === input.requestId ? null : undefined),
          undefined,
          false,
        );
        await pairLockRef.transaction(
          (current) => (current === input.requestId ? null : undefined),
          undefined,
          false,
        );
      }
      throw error;
    }

    try {
      const createdAt = Date.now();
      await database.ref().update({
        [`users/${targetUid}/requests/${input.requestId}`]: {
          requestId: input.requestId,
          fromUid: uid,
          toUid: targetUid,
          fromPersonalId: senderPersonalId,
          fromPeerId: input.peerId,
          publicKey: input.publicKey,
          status: "pending",
          createdAt,
        },
        [`users/${uid}/sentRequests/${input.requestId}`]: {
          requestId: input.requestId,
          targetUid,
          targetPersonalId: input.personalId,
          status: "pending",
          createdAt,
        },
      });
    } catch (error) {
      // Avoid leaving a lock if no request record was committed. A retry with
      // the same request ID remains idempotent if the record already exists.
      const createdRequest = await requestRef.get();
      if (!createdRequest.exists()) {
        if (priorPendingId === null) {
          await pendingRef.transaction(
            (current) => (current === input.requestId ? null : undefined),
            undefined,
            false,
          );
        }
        if (priorPairLock === null) {
          await pairLockRef.transaction(
            (current) => (current === input.requestId ? null : undefined),
            undefined,
            false,
          );
        }
      }
      throw error;
    }
    return { requestId: input.requestId, alreadySent: false };
  },
);

async function finishContactAcceptance(
  acceptorUid: string,
  requestId: string,
  acceptedRequest: Record<string, unknown>,
): Promise<Record<string, string>> {
  const requesterUid = acceptedRequest.fromUid;
  const roomId = acceptedRequest.roomId;
  const requesterPeerId = acceptedRequest.fromPeerId;
  const requesterPublicKey = acceptedRequest.publicKey;
  const acceptorPeerId = acceptedRequest.acceptedByPeerId;
  const acceptorPublicKey = acceptedRequest.acceptedByPublicKey;
  const requesterPersonalId = acceptedRequest.fromPersonalId;
  const acceptedAt = acceptedRequest.acceptedAt;

  if (
    typeof requesterUid !== "string" ||
    typeof roomId !== "string" ||
    !isValidRoomId(roomId) ||
    !isValidPeerId(requesterPeerId) ||
    !isValidKeyAgreementPublicKey(requesterPublicKey) ||
    !isValidPeerId(acceptorPeerId) ||
    !isValidKeyAgreementPublicKey(acceptorPublicKey) ||
    !isValidPersonalId(requesterPersonalId) ||
    typeof acceptedAt !== "number"
  ) {
    throw new HttpsError("failed-precondition", "Contact request data is incomplete.");
  }

  const acceptorPersonalId = await ensurePersonalId(acceptorUid);
  const database = getDatabase();
  const roomRef = database.ref(`rooms/${roomId}`);
  const roomValue = {
    createdAt: acceptedAt,
    createdBy: acceptorPeerId,
    members: {
      [requesterUid]: { peerId: requesterPeerId, joinedAt: acceptedAt },
      [acceptorUid]: { peerId: acceptorPeerId, joinedAt: acceptedAt },
    },
  };
  const roomResult = await roomRef.transaction(
    (current) => (current === null ? roomValue : undefined),
    undefined,
    false,
  );
  if (!roomResult.committed) {
    const existingRoom = (await roomRef.get()).val() as
      | Record<string, unknown>
      | null;
    const members =
      existingRoom?.members !== null && typeof existingRoom?.members === "object"
        ? (existingRoom.members as Record<string, unknown>)
        : {};
    const requesterMember = members[requesterUid];
    const acceptorMember = members[acceptorUid];
    const roomBelongsToThisAcceptance =
      existingRoom?.createdAt === acceptedAt &&
      existingRoom?.createdBy === acceptorPeerId &&
      requesterMember !== null &&
      typeof requesterMember === "object" &&
      (requesterMember as Record<string, unknown>).peerId === requesterPeerId &&
      acceptorMember !== null &&
      typeof acceptorMember === "object" &&
      (acceptorMember as Record<string, unknown>).peerId === acceptorPeerId;
    if (!roomBelongsToThisAcceptance) {
      throw new HttpsError("already-exists", "The generated room code is in use.");
    }
  }

  const updates: Record<string, unknown> = {
    [`users/${requesterUid}/contacts/${roomId}`]: {
      roomId,
      otherUid: acceptorUid,
      otherPeerId: acceptorPeerId,
      otherPublicKey: acceptorPublicKey,
      otherPersonalId: acceptorPersonalId,
      requestId,
      createdAt: acceptedAt,
    },
    [`users/${acceptorUid}/contacts/${roomId}`]: {
      roomId,
      otherUid: requesterUid,
      otherPeerId: requesterPeerId,
      otherPublicKey: requesterPublicKey,
      otherPersonalId: requesterPersonalId,
      requestId,
      createdAt: acceptedAt,
    },
    [`users/${requesterUid}/sentRequests/${requestId}`]: {
      requestId,
      targetUid: acceptorUid,
      targetPersonalId: acceptorPersonalId,
      status: "accepted",
      roomId,
      createdAt: acceptedAt,
    },
    [`pendingContactRequests/${acceptorUid}/${requesterUid}`]: null,
    [`internal/contactPairLocks/${contactPairLockKey(requesterUid, acceptorUid)}`]: null,
  };
  await database.ref().update(updates);
  return {
    roomId,
    otherUid: requesterUid,
    otherPeerId: requesterPeerId,
    otherPublicKey: requesterPublicKey,
    selfPublicKey: acceptorPublicKey,
    otherPersonalId: requesterPersonalId,
    requestId,
  };
}

/** The ID owner approves a request; separate contact rooms remain private. */
export const acceptContactRequest = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    const input = parseContactAcceptanceInput(request.data);
    const database = getDatabase();
    const requestRef = database.ref(`users/${uid}/requests/${input.requestId}`);
    const snapshot = await requestRef.get();
    if (!snapshot.exists()) {
      throw new HttpsError("not-found", "Contact request not found.");
    }
    const raw = snapshot.val() as Record<string, unknown>;
    if (raw.toUid !== uid || typeof raw.fromUid !== "string") {
      throw new HttpsError("permission-denied", "This request is not for your account.");
    }
    if (raw.status === "rejected") {
      throw new HttpsError("failed-precondition", "This request was declined.");
    }

    let accepted = raw;
    if (raw.status === "pending") {
      let unusedRoomId = "";
      for (let attempt = 0; attempt < 12; attempt += 1) {
        const candidate = generateRoomId();
        if (!(await database.ref(`rooms/${candidate}`).get()).exists()) {
          unusedRoomId = candidate;
          break;
        }
      }
      if (!unusedRoomId) {
        throw new HttpsError("resource-exhausted", "Could not allocate a private room.");
      }
      const acceptedAt = Date.now();
      const claim = await requestRef.transaction(
        (current) => {
          if (
            current !== null &&
            typeof current === "object" &&
            (current as Record<string, unknown>).status === "pending" &&
            (current as Record<string, unknown>).toUid === uid
          ) {
            return {
              ...(current as Record<string, unknown>),
              status: "accepted",
              roomId: unusedRoomId,
              acceptedBy: uid,
              acceptedByPeerId: input.peerId,
              acceptedByPublicKey: input.publicKey,
              acceptedAt,
            };
          }
          return current;
        },
        undefined,
        false,
      );
      if (!claim.committed) {
        const latest = (await requestRef.get()).val() as
          | Record<string, unknown>
          | null;
        if (latest?.status !== "accepted" || latest.acceptedBy !== uid) {
          throw new HttpsError("aborted", "The request changed. Refresh and retry.");
        }
        accepted = latest;
      } else {
        accepted = claim.snapshot.val() as Record<string, unknown>;
      }
    }
    if (accepted.status !== "accepted" || accepted.acceptedBy !== uid) {
      throw new HttpsError("failed-precondition", "This request is no longer pending.");
    }
    return finishContactAcceptance(uid, input.requestId, accepted);
  },
);

/** Declines a request and releases the pair-specific pending-request lock. */
export const rejectContactRequest = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    const data = request.data as Record<string, unknown>;
    const requestId = data?.requestId;
    if (!isValidRequestId(requestId)) {
      throw new HttpsError("invalid-argument", "Invalid contact request ID.");
    }
    const database = getDatabase();
    const requestRef = database.ref(`users/${uid}/requests/${requestId}`);
    const snapshot = await requestRef.get();
    if (!snapshot.exists()) return { rejected: true };
    const current = snapshot.val() as Record<string, unknown>;
    if (current.toUid !== uid || typeof current.fromUid !== "string") {
      throw new HttpsError("permission-denied", "This request is not for your account.");
    }
    if (current.status === "accepted") {
      throw new HttpsError("failed-precondition", "An accepted contact cannot be declined.");
    }
    const rejectedAt = Date.now();
    const transition = await requestRef.transaction(
      (value) => {
        if (
          value !== null &&
          typeof value === "object" &&
          (value as Record<string, unknown>).status === "pending" &&
          (value as Record<string, unknown>).toUid === uid
        ) {
          return {
            ...(value as Record<string, unknown>),
            status: "rejected",
            rejectedAt,
          };
        }
        if (
          value !== null &&
          typeof value === "object" &&
          (value as Record<string, unknown>).status === "rejected"
        ) {
          return value;
        }
        return;
      },
      undefined,
      false,
    );
    let rejected = transition.snapshot.val() as Record<string, unknown> | null;
    if (!transition.committed) {
      rejected = (await requestRef.get()).val() as Record<string, unknown> | null;
    }
    if (rejected?.status !== "rejected" || rejected.fromUid !== current.fromUid) {
      throw new HttpsError("failed-precondition", "This request is no longer pending.");
    }
    await database.ref().update({
      [`users/${uid}/requests/${requestId}/rejectedAt`]: rejected.rejectedAt ?? rejectedAt,
      [`users/${current.fromUid}/sentRequests/${requestId}/status`]: "rejected",
      [`pendingContactRequests/${uid}/${current.fromUid}`]: null,
      [`internal/contactPairLocks/${contactPairLockKey(uid, current.fromUid)}`]: null,
    });
    return { rejected: true };
  },
);

async function addAcceptedRequestClosureUpdates(
  updates: Record<string, unknown>,
  firstUid: string,
  secondUid: string,
  roomId: string,
  requestIdValue: unknown,
): Promise<void> {
  if (!isValidRequestId(requestIdValue)) return;
  const database = getDatabase();
  for (const requestOwnerUid of [firstUid, secondUid]) {
    const requestSnapshot = await database
      .ref(`users/${requestOwnerUid}/requests/${requestIdValue}`)
      .get();
    if (!requestSnapshot.exists()) continue;
    const contactRequest = requestSnapshot.val() as Record<string, unknown>;
    const participantsMatch =
      (contactRequest.fromUid === firstUid &&
        contactRequest.toUid === secondUid) ||
      (contactRequest.fromUid === secondUid &&
        contactRequest.toUid === firstUid);
    if (
      contactRequest.status !== "accepted" ||
      contactRequest.roomId !== roomId ||
      contactRequest.toUid !== requestOwnerUid ||
      !participantsMatch
    ) {
      continue;
    }
    updates[`users/${requestOwnerUid}/requests/${requestIdValue}/status`] =
      "closed";
    updates[`users/${requestOwnerUid}/requests/${requestIdValue}/closedAt`] =
      Date.now();
    updates[
      `users/${contactRequest.fromUid as string}/sentRequests/${requestIdValue}/status`
    ] = "closed";
    return;
  }
}

/** Removes a contact relationship from both directories when one peer leaves. */
export const leaveContactRoom = onCall(
  { region: DATABASE_REGION, maxInstances: 10 },
  async (request) => {
    const uid = requireAuthUid(request);
    const data = request.data as Record<string, unknown>;
    const roomId = data?.roomId;
    if (!isValidRoomId(roomId)) {
      throw new HttpsError("invalid-argument", "Invalid room ID.");
    }
    const database = getDatabase();
    const ownContactSnapshot = await database
      .ref(`users/${uid}/contacts/${roomId}`)
      .get();
    const ownContactValue = ownContactSnapshot.val();
    const ownContact =
      ownContactValue !== null && typeof ownContactValue === "object"
        ? (ownContactValue as Record<string, unknown>)
        : {};
    const roomSnapshot = await database.ref(`rooms/${roomId}`).get();
    if (!roomSnapshot.exists()) {
      if (!ownContactSnapshot.exists()) return { removed: true };
      const updates: Record<string, unknown> = {
        [`users/${uid}/contacts/${roomId}`]: null,
      };
      const linkedUid = ownContact.otherUid;
      if (typeof linkedUid === "string") {
        updates[`users/${linkedUid}/contacts/${roomId}`] = null;
        await addAcceptedRequestClosureUpdates(
          updates,
          uid,
          linkedUid,
          roomId,
          ownContact.requestId,
        );
      }
      await database.ref().update(updates);
      return { removed: true };
    }
    const room = roomSnapshot.val() as Record<string, unknown>;
    const rawMembers = room.members;
    const members =
      rawMembers !== null && typeof rawMembers === "object"
        ? (rawMembers as Record<string, unknown>)
        : {};
    if (members[uid] === undefined) {
      if (!ownContactSnapshot.exists()) return { removed: true };
      const linkedUid = ownContact.otherUid;
      if (typeof linkedUid !== "string") {
        throw new HttpsError("permission-denied", "You are not a member of this room.");
      }
      const updates: Record<string, unknown> = {
        [`users/${uid}/contacts/${roomId}`]: null,
        [`users/${linkedUid}/contacts/${roomId}`]: null,
      };
      await addAcceptedRequestClosureUpdates(
        updates,
        uid,
        linkedUid,
        roomId,
        ownContact.requestId,
      );
      await database.ref().update(updates);
      return { removed: true };
    }
    const otherUid = Object.keys(members).find((memberUid) => memberUid !== uid);
    const updates: Record<string, unknown> = {
      [`users/${uid}/contacts/${roomId}`]: null,
    };
    for (const memberUid of Object.keys(members)) {
      updates[`rooms/${roomId}/members/${memberUid}`] = null;
      const member = members[memberUid];
      if (member !== null && typeof member === "object") {
        const memberPeerId = (member as Record<string, unknown>).peerId;
        if (isValidPeerId(memberPeerId)) {
          updates[`rooms/${roomId}/tokens/${memberPeerId}`] = null;
          updates[`rooms/${roomId}/status/${memberPeerId}`] = null;
          updates[`rooms/${roomId}/profiles/${memberPeerId}`] = null;
        }
      }
    }
    if (otherUid) {
      updates[`users/${otherUid}/contacts/${roomId}`] = null;
      await addAcceptedRequestClosureUpdates(
        updates,
        uid,
        otherUid,
        roomId,
        ownContact.requestId,
      );
    }
    await database.ref().update(updates);
    return { removed: true };
  },
);

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
