import { createECDH, randomBytes, timingSafeEqual } from "node:crypto";

const roomIdPattern = /^[A-Z0-9]{6}$/;
const inviteSecretHashPattern = /^[a-f0-9]{64}$/;
const peerIdPattern = /^[a-f0-9]{16}$/;
const personalIdPattern = /^[A-HJ-NP-Z2-9]{10}$/;
const requestIdPattern = /^[A-Za-z0-9_-]{22}$/;
const publicKeyPattern = /^[A-Za-z0-9_-]{87}$/;
const personalIdAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const fileNamePattern = /^[A-Za-z0-9_-]{1,120}(?:\.[A-Za-z0-9]{1,10})?$/;

export function isValidRoomId(roomId: unknown): roomId is string {
  return typeof roomId === "string" && roomIdPattern.test(roomId);
}

export function isValidPeerId(peerId: unknown): peerId is string {
  return typeof peerId === "string" && peerIdPattern.test(peerId);
}

export function normalizePersonalId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toUpperCase().replace(/[-\s]/g, "");
  return personalIdPattern.test(normalized) ? normalized : null;
}

export function isValidPersonalId(value: unknown): value is string {
  return typeof value === "string" && personalIdPattern.test(value);
}

export function isValidRequestId(value: unknown): value is string {
  return typeof value === "string" && requestIdPattern.test(value);
}

/** Collision-free canonical key for a pair of Firebase Auth UIDs. */
export function contactPairLockKey(firstUid: string, secondUid: string): string {
  const pair = [firstUid, secondUid].sort();
  return Buffer.from(JSON.stringify(pair), "utf8").toString("base64url");
}

/**
 * Personal IDs are discoverability handles, not authentication secrets.
 * Ten unambiguous base-32 characters remain easy to read while resisting
 * practical online enumeration; server callables still require approval.
 */
export function generatePersonalId(): string {
  return Array.from(randomBytes(10), (byte) =>
    personalIdAlphabet[byte & 31],
  ).join("");
}

export function generateRoomId(): string {
  return Array.from(randomBytes(6), (byte) =>
    personalIdAlphabet[byte & 31],
  ).join("");
}

/** Validates an uncompressed P-256 public key before it is stored in a request. */
export function isValidKeyAgreementPublicKey(value: unknown): value is string {
  if (typeof value !== "string" || !publicKeyPattern.test(value)) return false;
  const bytes = Buffer.from(value, "base64url");
  if (
    bytes.length !== 65 ||
    bytes[0] !== 4 ||
    bytes.toString("base64url") !== value
  ) {
    return false;
  }
  try {
    const verifier = createECDH("prime256v1");
    verifier.generateKeys();
    verifier.computeSecret(bytes);
    return true;
  } catch {
    return false;
  }
}

export function isValidInviteSecretHash(value: unknown): value is string {
  return typeof value === "string" && inviteSecretHashPattern.test(value);
}

export function inviteSecretHashMatches(
  candidateHash: unknown,
  storedHash: unknown,
): boolean {
  if (!isValidInviteSecretHash(candidateHash) || !isValidInviteSecretHash(storedHash)) {
    return false;
  }
  const candidate = Buffer.from(candidateHash, "hex");
  const expected = Buffer.from(storedHash, "hex");
  return candidate.length === expected.length && timingSafeEqual(candidate, expected);
}

export function isAllowedExpiry(seconds: unknown): seconds is 30 | 300 | 3600 {
  return seconds === 30 || seconds === 300 || seconds === 3600;
}

/**
 * Returns only a path confined to one room's images directory. New messages
 * provide imagePath; the URL fallback supports legacy timestamp-based objects.
 */
export function safeImagePathForRoom(
  roomId: string,
  imagePath: unknown,
  imageUrl: unknown,
): string | undefined {
  if (!isValidRoomId(roomId)) return undefined;
  let candidate: string | undefined;
  if (typeof imagePath === "string") {
    candidate = imagePath;
  } else if (typeof imageUrl === "string" && imageUrl.length <= 8192) {
    try {
      const url = new URL(imageUrl);
      if (url.hostname !== "firebasestorage.googleapis.com") return undefined;
      const objectMarker = "/o/";
      const markerIndex = url.pathname.indexOf(objectMarker);
      if (markerIndex < 0) return undefined;
      candidate = decodeURIComponent(
        url.pathname.substring(markerIndex + objectMarker.length),
      );
    } catch {
      return undefined;
    }
  }
  if (!candidate || candidate.length > 256 || candidate.includes("\\")) {
    return undefined;
  }
  const prefix = `images/${roomId}/`;
  if (!candidate.startsWith(prefix)) return undefined;
  const fileName = candidate.substring(prefix.length);
  if (
    fileName.includes("/") ||
    fileName === "." ||
    fileName === ".." ||
    fileName.includes("..") ||
    !fileNamePattern.test(fileName)
  ) {
    return undefined;
  }
  return candidate;
}
