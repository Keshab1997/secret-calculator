import { createHash, timingSafeEqual } from "node:crypto";

const roomIdPattern = /^[A-Z0-9]{6}$/;
const inviteSecretPattern = /^[A-Za-z0-9_-]{43}$/;
const peerIdPattern = /^[a-f0-9]{16}$/;
const fileNamePattern = /^[A-Za-z0-9_-]{1,120}(?:\.[A-Za-z0-9]{1,10})?$/;

export function isValidRoomId(roomId: unknown): roomId is string {
  return typeof roomId === "string" && roomIdPattern.test(roomId);
}

export function isValidInviteSecret(secret: unknown): secret is string {
  if (typeof secret !== "string" || !inviteSecretPattern.test(secret)) {
    return false;
  }
  try {
    return Buffer.from(secret, "base64url").length === 32;
  } catch {
    return false;
  }
}

export function isValidPeerId(peerId: unknown): peerId is string {
  return typeof peerId === "string" && peerIdPattern.test(peerId);
}

export function hashInviteSecret(secret: string): string {
  return createHash("sha256").update(secret, "utf8").digest("hex");
}

export function inviteHashMatches(secret: string, storedHash: unknown): boolean {
  if (typeof storedHash !== "string" || !/^[a-f0-9]{64}$/.test(storedHash)) {
    return false;
  }
  const candidate = Buffer.from(hashInviteSecret(secret), "hex");
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
