const assert = require("node:assert/strict");
const { createECDH } = require("node:crypto");
const test = require("node:test");

const {
  generatePersonalId,
  generateRoomId,
  isValidKeyAgreementPublicKey,
  isValidPersonalId,
  isValidRequestId,
  contactPairLockKey,
  normalizePersonalId,
  inviteSecretHashMatches,
  isAllowedExpiry,
  isValidInviteSecretHash,
  isValidPeerId,
  isValidRoomId,
  safeImagePathForRoom,
} = require("../lib/security_helpers.js");

test("secure pairing validates room ids, invite verifiers, and peer ids", () => {
  const verifier =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  assert.equal(isValidRoomId("AB23CD"), true);
  assert.equal(isValidRoomId("ab23cd"), false);
  assert.equal(isValidRoomId("AB23C"), false);
  assert.equal(isValidInviteSecretHash(verifier), true);
  assert.equal(isValidInviteSecretHash("A".repeat(64)), false);
  assert.equal(isValidPeerId("0123456789abcdef"), true);
  assert.equal(isValidPeerId("not-a-peer-id"), false);
});

test("personal IDs are readable, normalized, and not room secrets", () => {
  const personalId = generatePersonalId();
  assert.equal(personalId.length, 10);
  assert.equal(isValidPersonalId(personalId), true);
  assert.equal(normalizePersonalId(` ${personalId.slice(0, 5)}-${personalId.slice(5).toLowerCase()} `), personalId);
  assert.equal(normalizePersonalId("bad-id"), null);
  assert.equal(generateRoomId().length, 6);
  assert.equal(isValidRequestId("A".repeat(22)), true);
  assert.equal(isValidRequestId("A".repeat(21)), false);
});

test("contact pair lock keys are canonical without delimiter collisions", () => {
  assert.equal(
    contactPairLockKey("uid-a", "uid-b"),
    contactPairLockKey("uid-b", "uid-a"),
  );
  assert.notEqual(
    contactPairLockKey("a", "b_c"),
    contactPairLockKey("a_b", "c"),
  );
  assert.match(contactPairLockKey("uid-a", "uid-b"), /^[A-Za-z0-9_-]+$/);
});

test("contact key exchange accepts real P-256 public keys only", () => {
  const keyPair = createECDH("prime256v1");
  keyPair.generateKeys();
  const publicKey = keyPair.getPublicKey("base64url", "uncompressed");
  assert.equal(isValidKeyAgreementPublicKey(publicKey), true);
  assert.equal(isValidKeyAgreementPublicKey("A".repeat(87)), false);
  assert.equal(isValidKeyAgreementPublicKey("short"), false);
});

test("invite verifiers are validated and compared in constant time", () => {
  const verifier =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  assert.equal(isValidInviteSecretHash(verifier), true);
  assert.equal(isValidInviteSecretHash("invalid"), false);
  assert.equal(inviteSecretHashMatches(verifier, verifier), true);
  assert.equal(inviteSecretHashMatches(verifier, "0".repeat(64)), false);
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
