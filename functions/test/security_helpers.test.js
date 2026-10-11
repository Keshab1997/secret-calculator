const assert = require("node:assert/strict");
const test = require("node:test");

const {
  hashInviteSecret,
  inviteHashMatches,
  isAllowedExpiry,
  isValidInviteSecret,
  isValidPeerId,
  isValidRoomId,
  safeImagePathForRoom,
} = require("../lib/security_helpers.js");

test("secure pairing validates room ids, 256-bit invites, and peer ids", () => {
  const invite = Buffer.alloc(32, 0x5a).toString("base64url");
  assert.equal(isValidRoomId("AB23CD"), true);
  assert.equal(isValidRoomId("ab23cd"), false);
  assert.equal(isValidRoomId("AB23C"), false);
  assert.equal(isValidInviteSecret(invite), true);
  assert.equal(isValidInviteSecret("A".repeat(43)), true);
  assert.equal(isValidInviteSecret("A".repeat(42)), false);
  assert.equal(isValidPeerId("0123456789abcdef"), true);
  assert.equal(isValidPeerId("not-a-peer-id"), false);
});

test("invite secrets are stored as hashes and compared in constant time", () => {
  const invite = Buffer.alloc(32, 0x31).toString("base64url");
  const hash = hashInviteSecret(invite);
  assert.match(hash, /^[a-f0-9]{64}$/);
  assert.equal(inviteHashMatches(invite, hash), true);
  assert.equal(inviteHashMatches(`${invite.slice(0, -1)}A`, hash), false);
  assert.equal(inviteHashMatches(invite, "invalid"), false);
});

test("only supported disappearing-message durations are accepted", () => {
  assert.equal(isAllowedExpiry(30), true);
  assert.equal(isAllowedExpiry(300), true);
  assert.equal(isAllowedExpiry(3600), true);
  assert.equal(isAllowedExpiry(60), false);
  assert.equal(isAllowedExpiry(null), false);
});

test("image cleanup paths are confined to the matching room", () => {
  const path = `images/AB23CD/${"a".repeat(32)}.bin`;
  assert.equal(safeImagePathForRoom("AB23CD", path, null), path);
  assert.equal(
    safeImagePathForRoom("AB23CD", "images/EF45GH/photo.jpg", null),
    undefined,
  );
  assert.equal(
    safeImagePathForRoom("AB23CD", "images/AB23CD/../../secrets", null),
    undefined,
  );
  const legacyUrl =
    "https://firebasestorage.googleapis.com/v0/b/example/o/images%2FAB23CD%2F1700000000000.jpg?alt=media&token=secret";
  assert.equal(
    safeImagePathForRoom("AB23CD", undefined, legacyUrl),
    "images/AB23CD/1700000000000.jpg",
  );
  assert.equal(
    safeImagePathForRoom("AB23CD", undefined, "https://evil.test/photo.jpg"),
    undefined,
  );
});
