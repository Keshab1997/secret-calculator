import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'encryption_service.dart';
import 'key_agreement_service.dart';

/// A photo upload that failed with a reason worth showing the person who
/// sent it.
class MediaUploadException implements Exception {
  final String message;

  const MediaUploadException(this.message);

  @override
  String toString() => message;
}

class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal()
    : _peerId = generatePeerId(),
      _secureStorageOverride = null;

  static final Map<String, Map<String, String>> _testSecureValues = {};

  @visibleForTesting
  FirebaseService.forTesting(File stateFile)
    : _peerId = generatePeerId(),
      stateFileOverride = stateFile,
      _secureStorageOverride = _testSecureValues.putIfAbsent(
        stateFile.path,
        () => <String, String>{},
      );

  /// Unambiguous 6-character code alphabet (excludes 0, O, 1, I).
  static const String codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const int roomCodeLength = 6;
  static const int personalIdLength = 10;
  static const int roomSecretLengthBytes = 32;
  static const String defaultPasscode = '1997';
  static const String functionRegion = 'asia-southeast1';
  static const String _customPasscodeStorageKey = 'custom_passcode_v1';
  static const String _decoyPasscodeStorageKey = 'decoy_passcode_v1';
  static const FlutterSecureStorage _platformSecureStorage =
      FlutterSecureStorage();

  /// Explicit Realtime Database URL (required because the database resides in
  /// `asia-southeast1` and `google-services.json` may omit `firebase_url`).
  static const String defaultDatabaseUrl =
      'https://secret-calculator-fce20-default-rtdb.asia-southeast1.firebasedatabase.app';

  static final Random _random = Random.secure();
  static final RegExp _validCodePattern = RegExp(r'^[A-Z0-9]{6}$');
  static final RegExp _validPersonalIdPattern = RegExp(r'^[A-HJ-NP-Z2-9]{10}$');
  static final RegExp _validPasscodePattern = RegExp(r'^[0-9]{4,8}$');
  static final RegExp _validRoomSecretPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _validContactRequestIdPattern = RegExp(
    r'^[A-Za-z0-9_-]{22}$',
  );

  final Map<String, String> _pairedRooms = {};
  final Map<String, String> _roomSecrets = {};
  final Set<String> _contactRooms = {};
  final Map<String, Future<String>> _contactAcceptanceOperations = {};
  final Map<String, String>? _secureStorageOverride;
  bool _needsRePair = false;
  Map<String, String> _profile = {
    'name': 'Calculator user',
    'about': 'Available',
  };
  Map<String, String> get pairedRooms => Map.unmodifiable(_pairedRooms);
  Map<String, String> get profile => Map.unmodifiable(_profile);

  String _peerId;
  String? _personalId;
  Future<String>? _personalIdFetch;
  bool _personalIdVerified = false;
  DatabaseReference? _chatRef;
  StreamSubscription<DatabaseEvent>? _contactLinksSubscription;
  StreamSubscription<DatabaseEvent>? _databaseConnectionSubscription;
  Future<void> _contactDirectoryQueue = Future<void>.value();
  bool _contactsServerConfirmed = false;
  String? _roomId;
  final ValueNotifier<int> contactRevisionNotifier = ValueNotifier(0);
  bool _isPaired = false;
  bool _isOnline = true;
  bool? _lastWrittenOnline;
  bool? _lastWrittenTyping;
  String? _lastWrittenStatusRoom;
  bool _persistenceConfigured = false;
  final Map<String, ({String cipher, Map<String, String> profile})>
  _partnerProfileCache = {};
  String _customPasscode = defaultPasscode;
  String? _decoyPasscode;
  bool _biometricEnabled = false;
  int? _disappearingSeconds;
  ThemeMode _themeMode = ThemeMode.system;
  final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
    ThemeMode.system,
  );
  String _callAlert = 'sound';
  final ValueNotifier<String> callAlertNotifier = ValueNotifier<String>(
    'sound',
  );
  String? _lastSeenRelease;
  final EncryptionService _encryption = EncryptionService();

  /// When set, the next [sendMessage] throws this instead of writing: the
  /// failure bubble and its retry need a testable seam, and this is the
  /// smallest one.
  @visibleForTesting
  Object? nextSendError;

  /// Unique per-install/session peer identifier used as `senderId` and status key.
  String get peerId => _peerId;

  /// Stable Personal ID for this anonymous Firebase installation.
  String? get personalId => _personalId;

  /// Notifies the directory when a contact request is accepted/revoked.
  ValueListenable<int> get contactsChanged => contactRevisionNotifier;

  /// Alias for [peerId].
  String get myPeerId => _peerId;

  /// Whether this device has an active paired chat room.
  bool get isPaired => _isPaired && _roomId != null;

  /// True when rooms created before the secure-invite upgrade need pairing again.
  bool get needsSecureRePair => _needsRePair;

  /// The out-of-band invite currently shown to the room creator.
  String? get currentInviteCode {
    final room = _roomId;
    final secret = room == null ? null : _roomSecrets[room];
    return room == null || secret == null ? null : '$room.$secret';
  }

  /// Current Firebase Auth identity, or null until anonymous sign-in succeeds.
  String? get authUid =>
      Firebase.apps.isEmpty ? null : FirebaseAuth.instance.currentUser?.uid;

  /// The Firebase project this build was configured for, or null when the app
  /// has no Firebase config at all (google-services.json was absent when the
  /// APK was built). Setup errors name it so a build carrying the wrong config
  /// cannot pass for a disabled provider.
  String? get firebaseProjectId =>
      Firebase.apps.isEmpty ? null : Firebase.app().options.projectId;

  /// Why this device has no signed-in identity, in one line the person holding
  /// the phone can act on. A build with no Firebase config, a disabled provider
  /// and a refused sign-in are three different problems with three different
  /// fixes, so they must not all read "enable Anonymous Authentication".
  String get authSetupHint {
    if (Firebase.apps.isEmpty) {
      return 'This build has no Firebase configuration, so secure pairing is '
          'unavailable. Install a build that had google-services.json present '
          'at build time.';
    }
    if (anonymousAuthDisabled) {
      return 'Secure pairing needs Firebase Anonymous Authentication. Enable it '
          'in the Firebase Console, then restart the app.';
    }
    final project = firebaseProjectId;
    final where = project == null ? '' : ' (Firebase project $project)';
    final cause = _lastAuthError;
    if (cause != null) {
      return 'Secure pairing could not sign this device in$where: $cause';
    }
    return 'Secure pairing could not sign this device in$where. Check your '
        'connection and try again.';
  }

  /// True when the last sign-in was refused because the Anonymous provider is
  /// switched off — the one cause the person can fix themselves in the Firebase
  /// Console, and the only one worth naming.
  bool get anonymousAuthDisabled {
    final error = _lastAuthError;
    if (error is FirebaseAuthException) {
      return const {
        'operation-not-allowed',
        'admin-restricted-operation',
      }.contains(error.code);
    }
    final text = error?.toString() ?? '';
    return text.contains('OPERATION_NOT_ALLOWED') ||
        text.contains('CONFIGURATION_NOT_FOUND');
  }

  /// Current custom secret calculator passcode (4–8 digits).
  String get customPasscode => _customPasscode;

  /// Optional decoy calculator passcode (4–8 digits) that opens an empty decoy view.
  String? get decoyPasscode => _decoyPasscode;

  /// Whether fingerprint/biometric verification is required after entering the passcode.
  bool get biometricEnabled => _biometricEnabled;

  /// Disappearing-message timer for new messages; null = off.
  int? get disappearingSeconds => _disappearingSeconds;

  /// How the messaging side should render: follow the system, or force
  /// light/dark. The calculator face stays dark either way.
  ThemeMode get themeMode => _themeMode;

  /// Live view of [themeMode] so the root of the app can re-skin itself the
  /// moment the user flips it, without any plumbing through the tree.
  ValueListenable<ThemeMode> get themeModeChanged => themeModeNotifier;

  /// How an incoming call alerts this phone: 'sound' (ringtone + vibration,
  /// the default), 'vibrate' (vibration only) or 'silent' (nothing).
  String get callAlert => _callAlert;

  /// Live view of [callAlert] for settings UI.
  ValueListenable<String> get callAlertChanged => callAlertNotifier;

  /// Release tag whose "what's new" notes were already shown, so they are
  /// not shown again on the next launch.
  String? get lastSeenRelease => _lastSeenRelease;

  /// Marks [tag]'s release notes as shown so they are not shown again.
  Future<void> markReleaseSeen(String tag) async {
    if (_lastSeenRelease == tag) return;
    _lastSeenRelease = tag;
    await _saveState();
  }

  FirebaseDatabase get _db {
    final db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: defaultDatabaseUrl,
    );
    if (!_persistenceConfigured) {
      _persistenceConfigured = true;
      try {
        db.setPersistenceEnabled(true);
        db.setPersistenceCacheSizeBytes(10 * 1024 * 1024);
      } catch (_) {}
    }
    return db;
  }

  FirebaseFunctions get _functions => FirebaseFunctions.instanceFor(
    app: Firebase.app(),
    region: functionRegion,
  );

  /// Generates a random 6-character room code from [codeAlphabet].
  static String generateRoomCode() {
    return List.generate(
      roomCodeLength,
      (_) => codeAlphabet[_random.nextInt(codeAlphabet.length)],
    ).join();
  }

  /// Generates an independent 256-bit secret for encryption and joining.
  static String generateRoomSecret() => base64UrlEncode(
    List<int>.generate(roomSecretLengthBytes, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');

  /// Parses the out-of-band `ROOMID.SECRET` invite, preserving secret case.
  static ({String roomId, String secret})? parseInviteCode(String invite) {
    final trimmed = invite.trim();
    final separator = trimmed.indexOf('.');
    if (separator < 0 || separator != trimmed.lastIndexOf('.')) return null;
    final roomId = trimmed.substring(0, separator).trim().toUpperCase();
    final secret = trimmed.substring(separator + 1);
    if (!_validCodePattern.hasMatch(roomId) ||
        !_validRoomSecretPattern.hasMatch(secret)) {
      return null;
    }
    try {
      if (base64Url.decode('$secret=').length != roomSecretLengthBytes) {
        return null;
      }
    } on FormatException {
      return null;
    }
    return (roomId: roomId, secret: secret);
  }

  static bool isValidInviteCode(String invite) =>
      parseInviteCode(invite) != null;

  /// Generates a random 16-character peer identifier.
  static String generatePeerId() {
    const hexAlphabet = '0123456789abcdef';
    return List.generate(
      16,
      (_) => hexAlphabet[_random.nextInt(hexAlphabet.length)],
    ).join();
  }

  /// Returns true when [code] is a valid 6-character alphanumeric room code.
  static bool isValidRoomCode(String code) {
    final normalized = code.trim().toUpperCase();
    return _validCodePattern.hasMatch(normalized);
  }

  /// Normalizes a displayed, optionally hyphenated Personal ID for lookup.
  static String? normalizePersonalId(String value) {
    final normalized = value.trim().toUpperCase().replaceAll(
      RegExp(r'[\s-]'),
      '',
    );
    return _validPersonalIdPattern.hasMatch(normalized) ? normalized : null;
  }

  static bool isValidPersonalId(String value) =>
      normalizePersonalId(value) != null;

  static String formatPersonalId(String value) {
    final normalized = normalizePersonalId(value);
    if (normalized == null) return value;
    return '${normalized.substring(0, 5)}-${normalized.substring(5)}';
  }

  /// Returns true when [passcode] is 4–8 numeric digits.
  static bool isValidPasscode(String passcode) {
    return _validPasscodePattern.hasMatch(passcode.trim());
  }

  Future<void> initialize() async {
    await Firebase.initializeApp();
    await ensureAuthenticated();
    await loadSavedState();
  }

  Future<void>? _pendingAuth;

  /// The error from the last failed anonymous sign-in, or null when sign-in has
  /// never failed. Kept so a setup error can name the real cause instead of
  /// guessing at the provider being switched off.
  Object? _lastAuthError;

  /// Creates a persistent anonymous Firebase identity before any paired data is
  /// read or written. Anonymous sign-in must be enabled in Firebase Console.
  ///
  /// Single-flight: startup fires this in the background while the UI is
  /// already up, so pairing can ask again before the first call lands — two
  /// concurrent signInAnonymously() calls would replace one anonymous uid
  /// with a second one, and rooms are keyed by that uid.
  Future<void> ensureAuthenticated() {
    if (Firebase.apps.isEmpty) return Future<void>.value();
    if (FirebaseAuth.instance.currentUser != null) return Future<void>.value();
    return _pendingAuth ??= _signInAnonymously().whenComplete(
      () => _pendingAuth = null,
    );
  }

  /// Sign-in with one retry, because startup fires it without waiting: a single
  /// dropped request used to leave the pairing screen insisting on Firebase
  /// Console setup that was already correct. A refusal that a second attempt
  /// cannot change is not retried — retrying only delays the message.
  Future<void> _signInAnonymously() async {
    for (var attempt = 0; ; attempt++) {
      try {
        await FirebaseAuth.instance.signInAnonymously();
        _lastAuthError = null;
        return;
      } catch (error) {
        _lastAuthError = error;
        if (attempt >= 1 || _isAuthConfigurationRefusal(error)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
  }

  /// Sign-in failures that describe the app's configuration rather than the
  /// network, so repeating the request cannot help.
  static bool _isAuthConfigurationRefusal(Object error) {
    if (error is FirebaseAuthException) {
      return const {
        'operation-not-allowed',
        'admin-restricted-operation',
        'invalid-api-key',
        'api-key-not-valid',
        'app-not-authorized',
      }.contains(error.code);
    }
    final text = error.toString();
    return text.contains('OPERATION_NOT_ALLOWED') ||
        text.contains('CONFIGURATION_NOT_FOUND') ||
        text.contains('API key not valid');
  }

  @visibleForTesting
  File? stateFileOverride;

  Future<String?> _readProtectedValue(String key) async {
    final override = _secureStorageOverride;
    if (override != null) return override[key];
    return _platformSecureStorage.read(key: key);
  }

  Future<void> _writeProtectedValue(String key, String value) async {
    final override = _secureStorageOverride;
    if (override != null) {
      override[key] = value;
      return;
    }
    await _platformSecureStorage.write(key: key, value: value);
  }

  Future<void> _deleteProtectedValue(String key) async {
    final override = _secureStorageOverride;
    if (override != null) {
      override.remove(key);
      return;
    }
    await _platformSecureStorage.delete(key: key);
  }

  static String _roomSecretStorageKey(String room) => 'room_key_v1_$room';

  String _requireAuthenticatedUid() {
    final uid = authUid;
    if (uid == null || uid.isEmpty) {
      throw StateError(authSetupHint);
    }
    return uid;
  }

  Future<File> _stateFile() async {
    if (stateFileOverride != null) return stateFileOverride!;
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      final primary = File('${dir.path}/secret_calc_state.json');
      if (!primary.existsSync()) {
        final legacy = _legacyStateFile();
        if (legacy.existsSync() && legacy.path != primary.path) {
          try {
            await legacy.copy(primary.path);
          } catch (_) {}
        }
      }
      return primary;
    } catch (_) {
      return _legacyStateFile();
    }
  }

  File _legacyStateFile() {
    final parentDir = Directory.systemTemp.parent;
    final filesDir = Directory('${parentDir.path}/files');
    if (filesDir.existsSync()) {
      return File('${filesDir.path}/secret_calc_state.json');
    }
    return File('${Directory.systemTemp.path}/secret_calc_state.json');
  }

  /// Loads non-secret preferences from JSON and passcodes/room keys from
  /// platform secure storage. Legacy rooms without an out-of-band key require
  /// a fresh secure invite rather than silently reusing the public room ID.
  Future<void> loadSavedState() async {
    try {
      final file = await _stateFile();
      if (!file.existsSync()) {
        final protectedPasscode = await _readProtectedValue(
          _customPasscodeStorageKey,
        );
        if (protectedPasscode != null && isValidPasscode(protectedPasscode)) {
          _customPasscode = protectedPasscode.trim();
        } else {
          await _writeProtectedValue(
            _customPasscodeStorageKey,
            _customPasscode,
          );
        }
        final protectedDecoy = await _readProtectedValue(
          _decoyPasscodeStorageKey,
        );
        if (protectedDecoy != null &&
            isValidPasscode(protectedDecoy) &&
            protectedDecoy.trim() != _customPasscode) {
          _decoyPasscode = protectedDecoy.trim();
        }
        await _saveState();
        unawaited(_startContactSync());
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        unawaited(_startContactSync());
        return;
      }

      final savedPeer = decoded['peerId'];
      if (savedPeer is String && savedPeer.length == 16) {
        _peerId = savedPeer;
      }
      final savedPersonalId = decoded['personalId'];
      if (savedPersonalId is String && isValidPersonalId(savedPersonalId)) {
        _personalId = normalizePersonalId(savedPersonalId);
      }
      final savedContactRooms = decoded['contactRooms'];
      if (savedContactRooms is List) {
        _contactRooms.addAll(
          savedContactRooms
              .whereType<String>()
              .map((room) => room.trim().toUpperCase())
              .where(isValidRoomCode),
        );
      }

      final savedPasscode = decoded['customPasscode'];
      final protectedPasscode = await _readProtectedValue(
        _customPasscodeStorageKey,
      );
      if (protectedPasscode != null && isValidPasscode(protectedPasscode)) {
        _customPasscode = protectedPasscode.trim();
      } else if (savedPasscode is String && isValidPasscode(savedPasscode)) {
        _customPasscode = savedPasscode.trim();
        await _writeProtectedValue(_customPasscodeStorageKey, _customPasscode);
      } else {
        await _writeProtectedValue(_customPasscodeStorageKey, _customPasscode);
      }

      final savedDecoy = decoded['decoyPasscode'];
      final protectedDecoy = await _readProtectedValue(
        _decoyPasscodeStorageKey,
      );
      final decoy = protectedDecoy ?? savedDecoy;
      if (decoy is String &&
          isValidPasscode(decoy) &&
          decoy.trim() != _customPasscode) {
        _decoyPasscode = decoy.trim();
        if (protectedDecoy == null) {
          await _writeProtectedValue(_decoyPasscodeStorageKey, _decoyPasscode!);
        }
      }

      final savedBio = decoded['biometricEnabled'];
      if (savedBio is bool) _biometricEnabled = savedBio;
      final savedDisappearing = decoded['disappearingSeconds'];
      if (savedDisappearing is int &&
          const {30, 300, 3600}.contains(savedDisappearing)) {
        _disappearingSeconds = savedDisappearing;
      }
      switch (decoded['darkMode']) {
        case 'light':
          _themeMode = ThemeMode.light;
        case 'dark':
          _themeMode = ThemeMode.dark;
        default:
          _themeMode = ThemeMode.system;
      }
      themeModeNotifier.value = _themeMode;
      final savedAlert = decoded['callAlert'];
      if (savedAlert == 'sound' ||
          savedAlert == 'vibrate' ||
          savedAlert == 'silent') {
        _callAlert = savedAlert as String;
      }
      callAlertNotifier.value = _callAlert;
      final savedSeenRelease = decoded['lastSeenRelease'];
      if (savedSeenRelease is String && savedSeenRelease.isNotEmpty) {
        _lastSeenRelease = savedSeenRelease;
      }
      _needsRePair = decoded['needsRePair'] == true;

      final rooms = decoded['pairedRooms'];
      if (rooms is Map) {
        for (final entry in rooms.entries) {
          if (isValidRoomCode(entry.key.toString())) {
            _pairedRooms[entry.key.toString().trim().toUpperCase()] = entry
                .value
                .toString();
          }
        }
      }
      final profile = decoded['profile'];
      if (profile is Map) {
        _profile = profile.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
      final savedRoom = decoded['roomId'];
      if (savedRoom is String && isValidRoomCode(savedRoom)) {
        _pairedRooms.putIfAbsent(
          savedRoom.trim().toUpperCase(),
          () => 'Paired contact',
        );
      }

      for (final room in _pairedRooms.keys.toList()) {
        final secret = await _readProtectedValue(_roomSecretStorageKey(room));
        if (secret != null && _validRoomSecretPattern.hasMatch(secret)) {
          _roomSecrets[room] = secret;
        } else {
          _pairedRooms.remove(room);
          if (!_contactRooms.contains(room)) _needsRePair = true;
        }
      }

      if (savedRoom is String && isValidRoomCode(savedRoom)) {
        final normalized = savedRoom.trim().toUpperCase();
        final secret = _roomSecrets[normalized];
        if (secret != null && (Firebase.apps.isEmpty || authUid != null)) {
          _roomId = normalized;
          _isPaired = true;
          _encryption.setRoomKey(secret);
          _chatRef = Firebase.apps.isEmpty
              ? null
              : _db.ref('rooms/$normalized/messages');
        } else {
          _roomId = null;
          _chatRef = null;
          _isPaired = false;
          _needsRePair = true;
        }
      }

      // Rewrite migrated state without secrets in the JSON file.
      await _saveState(strict: true);
      unawaited(_startContactSync());
    } catch (_) {
      // Keep startup usable if local state or the platform secure store is damaged.
      unawaited(_startContactSync());
    }
  }

  Future<void> _saveState({bool strict = false}) async {
    try {
      final file = await _stateFile();
      await file.writeAsString(
        jsonEncode({
          'pairedRooms': _pairedRooms,
          'profile': _profile,
          'peerId': _peerId,
          'personalId': _personalId,
          'contactRooms': _contactRooms.toList(),
          'roomId': _isPaired ? _roomId : null,
          'needsRePair': _needsRePair,
          'biometricEnabled': _biometricEnabled,
          'disappearingSeconds': _disappearingSeconds,
          'darkMode': _themeMode.name,
          'callAlert': _callAlert,
          'lastSeenRelease': _lastSeenRelease,
        }),
      );
    } catch (_) {
      if (strict) rethrow;
      // Legacy settings remain best-effort in restricted environments.
    }
  }

  static String _contactRequestPrivateStorageKey(String requestId) =>
      'contact_request_private_v1_$requestId';
  static String _acceptContactPrivateStorageKey(String requestId) =>
      'contact_accept_private_v1_$requestId';
  static String _acceptContactPublicStorageKey(String requestId) =>
      'contact_accept_public_v1_$requestId';

  /// Gets the per-install Personal ID from the authenticated server record.
  Future<String> getOrCreatePersonalId() {
    final knownId = _personalId;
    if (_personalIdVerified && knownId != null) return Future.value(knownId);
    final pending = _personalIdFetch;
    if (pending != null) return pending;
    final fetch = _fetchPersonalId();
    _personalIdFetch = fetch;
    return fetch.whenComplete(() {
      if (identical(_personalIdFetch, fetch)) _personalIdFetch = null;
    });
  }

  Future<String> _fetchPersonalId() async {
    // Anonymous sign-in is fire-and-forget at launch (main.dart) so the
    // calculator comes up before it lands. Pairing is usually the first screen
    // that needs that identity, so wait for the in-flight sign-in here rather
    // than failing on a uid that exists a moment later; only a sign-in that has
    // genuinely failed still throws below.
    await ensureAuthenticated();
    _requireAuthenticatedUid();
    final result = await _functions
        .httpsCallable('getOrCreatePersonalId')
        .call<dynamic>();
    final raw = result.data;
    final data = raw is Map ? Map<String, dynamic>.from(raw) : null;
    final value = data?['personalId'];
    if (value is! String || !isValidPersonalId(value)) {
      throw StateError('The server returned an invalid Personal ID.');
    }
    _personalId = normalizePersonalId(value);
    _personalIdVerified = true;
    await _saveState();
    return _personalId!;
  }

  /// Incoming requests are readable only to this installation's Auth UID.
  /// Broadcast on purpose: the underlying onValue is a single-subscription
  /// generator stream, and the pairing screen stores this once for a
  /// StreamBuilder that can remount (rows appearing above it reshape the
  /// list). A second listen to the stored instance would throw
  /// "Bad state: Stream has already been listened to".
  Stream<DatabaseEvent> incomingContactRequests() {
    final uid = authUid;
    if (Firebase.apps.isEmpty || uid == null) return const Stream.empty();
    return _db.ref('users/$uid/requests').onValue.asBroadcastStream();
  }

  /// Tracks the current installation's outgoing request statuses.
  Stream<DatabaseEvent> sentContactRequests() {
    final uid = authUid;
    if (Firebase.apps.isEmpty || uid == null) return const Stream.empty();
    // Broadcast for the same remount reason as incomingContactRequests().
    return _db.ref('users/$uid/sentRequests').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is Map) {
        for (final entry in raw.values) {
          if (entry is Map && entry['status'] == 'rejected') {
            final requestId = entry['requestId'];
            if (requestId is String) {
              unawaited(discardContactRequestKey(requestId));
            }
          }
        }
      }
      return event;
    }).asBroadcastStream();
  }

  /// Sends an approval request to the owner of [enteredPersonalId].
  Future<String> sendContactRequest(String enteredPersonalId) async {
    final personalId = normalizePersonalId(enteredPersonalId);
    if (personalId == null) {
      throw const FormatException('Enter a valid 10-character Personal ID.');
    }
    // Wait for the same in-flight anonymous sign-in the Personal ID needs: a
    // request sent right after opening pairing must not be rejected for a uid
    // that is about to exist.
    await ensureAuthenticated();
    _requireAuthenticatedUid();
    await getOrCreatePersonalId();
    final requestId = base64UrlEncode(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    final keyPair = KeyAgreementService.generateKeyPair();
    await _writeProtectedValue(
      _contactRequestPrivateStorageKey(requestId),
      keyPair.privateKey,
    );
    try {
      await _functions.httpsCallable('sendContactRequest').call<dynamic>({
        'personalId': personalId,
        'requestId': requestId,
        'peerId': _peerId,
        'publicKey': keyPair.publicKey,
      });
      return requestId;
    } on FirebaseFunctionsException catch (error) {
      if (!_mayHaveCommittedContactRequest(error.code)) {
        await _deleteProtectedValue(
          _contactRequestPrivateStorageKey(requestId),
        );
      }
      rethrow;
    }
  }

  static bool _mayHaveCommittedContactRequest(String code) => const {
    'cancelled',
    'deadline-exceeded',
    'internal',
    'unknown',
    'unavailable',
  }.contains(code);

  /// Accepts a pending request, derives/stores the room key locally, then
  /// opens the new private conversation. No room secret is sent to Functions.
  Future<String> acceptContactRequest(String requestId) async {
    if (!_validContactRequestIdPattern.hasMatch(requestId)) {
      throw const FormatException('Invalid contact request ID.');
    }
    final pending = _contactAcceptanceOperations[requestId];
    if (pending != null) return pending;
    final operation = _acceptContactRequestInternal(requestId);
    _contactAcceptanceOperations[requestId] = operation;
    try {
      return await operation;
    } finally {
      _contactAcceptanceOperations.remove(requestId);
    }
  }

  Future<String> _acceptContactRequestInternal(String requestId) async {
    _requireAuthenticatedUid();
    var privateKey = await _readProtectedValue(
      _acceptContactPrivateStorageKey(requestId),
    );
    var publicKey = await _readProtectedValue(
      _acceptContactPublicStorageKey(requestId),
    );
    if (privateKey == null || publicKey == null) {
      await _deleteProtectedValue(_acceptContactPrivateStorageKey(requestId));
      await _deleteProtectedValue(_acceptContactPublicStorageKey(requestId));
      final keyPair = KeyAgreementService.generateKeyPair();
      await _writeProtectedValue(
        _acceptContactPrivateStorageKey(requestId),
        keyPair.privateKey,
      );
      await _writeProtectedValue(
        _acceptContactPublicStorageKey(requestId),
        keyPair.publicKey,
      );
      privateKey = keyPair.privateKey;
      publicKey = keyPair.publicKey;
    }

    final result = await _functions
        .httpsCallable('acceptContactRequest')
        .call<dynamic>({
          'requestId': requestId,
          'peerId': _peerId,
          'publicKey': publicKey,
        });
    final raw = result.data;
    if (raw is! Map) throw StateError('The server returned invalid room data.');
    final contact = Map<String, dynamic>.from(raw);
    final roomId = contact['roomId'];
    final otherPublicKey = contact['otherPublicKey'];
    if (roomId is! String ||
        !isValidRoomCode(roomId) ||
        otherPublicKey is! String) {
      throw StateError('The server returned invalid contact keys.');
    }
    var secret = _roomSecrets[roomId];
    secret ??= await _readProtectedValue(_roomSecretStorageKey(roomId));
    if (secret == null || !_validRoomSecretPattern.hasMatch(secret)) {
      if (contact['selfPublicKey'] != publicKey) {
        throw StateError(
          'The approved key is not available on this device. Restart pairing.',
        );
      }
      secret = KeyAgreementService.deriveRoomSecret(
        privateKey: privateKey,
        peerPublicKey: otherPublicKey,
        roomId: roomId,
      );
    }
    await _writeProtectedValue(_roomSecretStorageKey(roomId), secret);
    _roomSecrets[roomId] = secret;
    await _deleteProtectedValue(_acceptContactPrivateStorageKey(requestId));
    await _deleteProtectedValue(_acceptContactPublicStorageKey(requestId));
    if (!await _queueContactLinkFromServer(roomId)) {
      throw StateError('This contact was unlinked before setup completed.');
    }
    await selectRoom(roomId);
    await markRoomPaired();
    return roomId;
  }

  /// Removes an unused, rejected request's local ECDH private scalar.
  Future<void> discardContactRequestKey(String requestId) async {
    if (!_validContactRequestIdPattern.hasMatch(requestId)) return;
    await _deleteProtectedValue(_contactRequestPrivateStorageKey(requestId));
  }

  /// Declines a request without creating a room or contact entry.
  Future<void> rejectContactRequest(String requestId) async {
    if (!_validContactRequestIdPattern.hasMatch(requestId)) {
      throw const FormatException('Invalid contact request ID.');
    }
    _requireAuthenticatedUid();
    await _functions.httpsCallable('rejectContactRequest').call<dynamic>({
      'requestId': requestId,
    });
    await _deleteProtectedValue(_acceptContactPrivateStorageKey(requestId));
    await _deleteProtectedValue(_acceptContactPublicStorageKey(requestId));
  }

  Future<bool> _queueContactLinkFromServer(String roomId) {
    var linked = false;
    final uid = _requireAuthenticatedUid();
    final next = _contactDirectoryQueue.then((_) async {
      final snapshot = await _db.ref('users/$uid/contacts/$roomId').get();
      if (!snapshot.exists || snapshot.value is! Map) return;
      linked = true;
      final data = Map<String, dynamic>.from(snapshot.value as Map);
      if (await _applyContactLink(roomId, data)) {
        contactRevisionNotifier.value += 1;
        await _saveState();
      }
    });
    _contactDirectoryQueue = next.catchError((Object _) {});
    return next.then((_) => linked);
  }

  Future<void> _queueContactDirectory(
    Object? value, {
    bool allowPruning = true,
  }) {
    final next = _contactDirectoryQueue.then(
      (_) => _applyContactDirectory(value, allowPruning: allowPruning),
    );
    _contactDirectoryQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _ensurePersonalIdBestEffort() async {
    try {
      await getOrCreatePersonalId();
    } catch (_) {
      // Pairing screen can retry when this installation comes back online.
    }
  }

  Future<void> _startContactSync() async {
    final uid = authUid;
    if (Firebase.apps.isEmpty || uid == null) return;
    unawaited(_ensurePersonalIdBestEffort());
    final reference = _db.ref('users/$uid/contacts');
    try {
      _contactLinksSubscription ??= reference.onValue.listen(
        (event) => unawaited(
          _queueContactDirectory(
            event.snapshot.value,
            allowPruning: _contactsServerConfirmed,
          ).catchError((Object _) {}),
        ),
        onError: (Object _) {},
      );
      _databaseConnectionSubscription ??= _db
          .ref('.info/connected')
          .onValue
          .listen((event) {
            _contactsServerConfirmed = event.snapshot.value == true;
            if (_contactsServerConfirmed) {
              unawaited(_refreshContactDirectory(reference));
            }
          }, onError: (Object _) {});
      _contactsServerConfirmed =
          (await _db.ref('.info/connected').get()).value == true;
      final snapshot = await reference.get();
      await _queueContactDirectory(
        snapshot.value,
        allowPruning: _contactsServerConfirmed,
      );
    } catch (_) {
      // The app remains usable while the user prepares to deploy database rules.
    }
  }

  Future<void> _refreshContactDirectory(DatabaseReference reference) async {
    try {
      final snapshot = await reference.get();
      await _queueContactDirectory(snapshot.value, allowPruning: true);
    } catch (_) {}
  }

  Future<void> _applyContactDirectory(
    Object? value, {
    bool allowPruning = true,
  }) async {
    final records = value is Map ? value : const <Object?, Object?>{};
    final serverRoomIds = <String>{};
    var changed = false;
    for (final entry in records.entries) {
      final roomId = entry.key?.toString().trim().toUpperCase();
      final raw = entry.value;
      if (roomId == null || !isValidRoomCode(roomId) || raw is! Map) continue;
      serverRoomIds.add(roomId);
      final data = Map<String, dynamic>.from(raw);
      if (await _applyContactLink(roomId, data)) changed = true;
    }

    if (allowPruning) {
      final staleRooms = _contactRooms.difference(serverRoomIds).toList();
      for (final roomId in staleRooms) {
        _contactRooms.remove(roomId);
        _pairedRooms.remove(roomId);
        _roomSecrets.remove(roomId);
        _partnerProfileCache.remove(roomId);
        await _deleteProtectedValue(_roomSecretStorageKey(roomId));
        if (_roomId == roomId) {
          _roomId = null;
          _chatRef = null;
          _isPaired = false;
          _encryption.resetKey();
        }
        changed = true;
      }
    }
    if (changed) {
      contactRevisionNotifier.value += 1;
      await _saveState();
      try {
        await _publishProfile();
      } catch (_) {}
      await registerFcmToken();
    }
  }

  Future<bool> _applyContactLink(
    String roomId,
    Map<String, dynamic> data,
  ) async {
    final otherPersonalId = data['otherPersonalId'];
    final otherPublicKey = data['otherPublicKey'];
    final requestId = data['requestId'];
    if (otherPersonalId is! String ||
        !isValidPersonalId(otherPersonalId) ||
        otherPublicKey is! String ||
        requestId is! String ||
        !_validContactRequestIdPattern.hasMatch(requestId)) {
      return false;
    }

    final alreadyRegistered =
        _contactRooms.contains(roomId) &&
        _pairedRooms.containsKey(roomId) &&
        _roomSecrets.containsKey(roomId);
    var secret = _roomSecrets[roomId];
    if (secret == null || !_validRoomSecretPattern.hasMatch(secret)) {
      secret = await _readProtectedValue(_roomSecretStorageKey(roomId));
    }
    if (secret == null || !_validRoomSecretPattern.hasMatch(secret)) {
      final requesterPrivateKey = await _readProtectedValue(
        _contactRequestPrivateStorageKey(requestId),
      );
      final acceptorPrivateKey = await _readProtectedValue(
        _acceptContactPrivateStorageKey(requestId),
      );
      try {
        if (requesterPrivateKey != null) {
          secret = KeyAgreementService.deriveRoomSecret(
            privateKey: requesterPrivateKey,
            peerPublicKey: otherPublicKey,
            roomId: roomId,
          );
          await _deleteProtectedValue(
            _contactRequestPrivateStorageKey(requestId),
          );
        } else if (acceptorPrivateKey != null) {
          secret = KeyAgreementService.deriveRoomSecret(
            privateKey: acceptorPrivateKey,
            peerPublicKey: otherPublicKey,
            roomId: roomId,
          );
          await _deleteProtectedValue(
            _acceptContactPrivateStorageKey(requestId),
          );
          await _deleteProtectedValue(
            _acceptContactPublicStorageKey(requestId),
          );
        }
      } on FormatException {
        return false;
      }
      if (secret == null) return false;
      await _writeProtectedValue(_roomSecretStorageKey(roomId), secret);
    }

    _roomSecrets[roomId] = secret;
    _contactRooms.add(roomId);
    _pairedRooms[roomId] = 'Contact ${formatPersonalId(otherPersonalId)}';
    if (_roomId == roomId) _encryption.setRoomKey(secret);
    if (!alreadyRegistered) {
      _partnerProfileCache.remove(roomId);
      return true;
    }
    return false;
  }

  /// Switches the messaging side between system / light / dark.
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    themeModeNotifier.value = mode;
    await _saveState();
  }

  /// Sets how incoming calls alert this phone: 'sound', 'vibrate' or
  /// 'silent'. Unknown values are ignored.
  Future<void> setCallAlert(String mode) async {
    if (mode != 'sound' && mode != 'vibrate' && mode != 'silent') return;
    _callAlert = mode;
    callAlertNotifier.value = mode;
    await _saveState();
  }

  /// Updates and persists a custom calculator passcode (4–8 digits).
  Future<bool> setCustomPasscode(String code) async {
    final trimmed = code.trim();
    if (!isValidPasscode(trimmed)) return false;
    await _writeProtectedValue(_customPasscodeStorageKey, trimmed);
    _customPasscode = trimmed;
    if (_decoyPasscode == trimmed) {
      _decoyPasscode = null;
      await _deleteProtectedValue(_decoyPasscodeStorageKey);
    }
    await _saveState();
    return true;
  }

  /// Sets or clears an optional decoy passcode (4–8 digits, distinct from real unlock code).
  Future<bool> setDecoyPasscode(String? code) async {
    final trimmed = code?.trim() ?? '';
    if (trimmed.isEmpty) {
      _decoyPasscode = null;
      await _deleteProtectedValue(_decoyPasscodeStorageKey);
      await _saveState();
      return true;
    }
    if (!isValidPasscode(trimmed) || trimmed == _customPasscode) {
      return false;
    }
    await _writeProtectedValue(_decoyPasscodeStorageKey, trimmed);
    _decoyPasscode = trimmed;
    await _saveState();
    return true;
  }

  /// Updates and persists the biometric lock setting.
  Future<void> setBiometricEnabled(bool enabled) async {
    _biometricEnabled = enabled;
    await _saveState();
  }

  /// Hides the one-time legacy-room re-pair migration notice.
  Future<void> acknowledgeSecureRePairNotice() async {
    _needsRePair = false;
    await _saveState();
  }

  /// Updates and persists the disappearing-message timer (null = off).
  Future<void> setDisappearingSeconds(int? seconds) async {
    if (seconds != null && !const {30, 300, 3600}.contains(seconds)) {
      throw ArgumentError.value(seconds, 'seconds', 'Unsupported expiry');
    }
    _disappearingSeconds = seconds;
    await _saveState();
  }

  /// Marks the currently created room as paired and persists it.
  Future<void> markRoomPaired() async {
    final room = _roomId;
    if (room == null || !_roomSecrets.containsKey(room)) {
      throw StateError('This room has no secure invite key.');
    }
    _isPaired = true;
    _pairedRooms.putIfAbsent(room, () => 'Paired contact');
    await _saveState(strict: true);
    try {
      await _publishProfile();
    } catch (_) {
      /* Profile can be retried from You. */
    }
    await registerFcmToken();
  }

  /// Unpairs this device and removes its authenticated room membership.
  Future<void> leaveRoom() async {
    final room = _roomId;
    final uid = authUid;
    try {
      await updateOnlineStatus(false);
    } catch (_) {}
    final isContactRoom = room != null && _contactRooms.contains(room);
    if (isContactRoom && Firebase.apps.isNotEmpty && uid != null) {
      // Do not locally unlink if the server cannot update both private
      // directories; that would leave the other person's contact stale.
      try {
        await _functions.httpsCallable('leaveContactRoom').call<dynamic>({
          'roomId': room,
        });
      } catch (_) {
        try {
          await updateOnlineStatus(true);
        } catch (_) {}
        rethrow;
      }
    } else if (room != null && Firebase.apps.isNotEmpty && uid != null) {
      try {
        final roomRef = _db.ref('rooms/$room');
        await roomRef.child('tokens/$_peerId').remove();
        await roomRef.child('status/$_peerId').remove();
        await roomRef.child('profiles/$_peerId').remove();
        await roomRef.child('members/$uid').remove();
      } catch (_) {
        // Legacy local unpair still completes; a stale membership can be removed later.
      }
    }
    if (room != null) {
      _pairedRooms.remove(room);
      _roomSecrets.remove(room);
      _contactRooms.remove(room);
      try {
        await _deleteProtectedValue(_roomSecretStorageKey(room));
      } catch (_) {}
      contactRevisionNotifier.value += 1;
    }
    _roomId = null;
    _chatRef = null;
    _isPaired = false;
    _encryption.resetKey();
    await _saveState();
  }

  bool _fcmRefreshRegistered = false;

  /// Publishes this device's FCM token at `rooms/{roomId}/tokens/{peerId}`
  /// so the `onNewMessage` Cloud Function can push a disguised Calculator
  /// notification to the partner even when this app is closed.
  ///
  /// Failures are swallowed: local notifications still cover the case where
  /// the app is open or backgrounded.
  Future<void> registerFcmToken() async {
    if ((_roomId == null && _pairedRooms.isEmpty) ||
        Firebase.apps.isEmpty ||
        authUid == null) {
      return;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      try {
        await messaging.requestPermission();
      } catch (_) {
        // Platforms without the notification permission prompt.
      }
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        for (final room in {..._pairedRooms.keys, ?_roomId}) {
          await _db.ref('rooms/$room/tokens/$_peerId').set(token);
        }
      }
      if (!_fcmRefreshRegistered) {
        _fcmRefreshRegistered = true;
        messaging.onTokenRefresh.listen((fresh) async {
          if (fresh.isEmpty) return;
          try {
            for (final code in {..._pairedRooms.keys, ?_roomId}) {
              await _db.ref('rooms/$code/tokens/$_peerId').set(fresh);
            }
          } catch (_) {}
        });
      }
    } catch (e) {
      debugPrint('registerFcmToken failed: $e');
    }
  }

  /// Creates a room through a callable using a one-way invite verifier; the
  /// room encryption secret itself never leaves this device.
  Future<String> createRoom() async {
    _requireAuthenticatedUid();
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = generateRoomCode();
      final secret = generateRoomSecret();
      await _writeProtectedValue(_roomSecretStorageKey(code), secret);
      try {
        await _functions.httpsCallable('createRoomSecure').call({
          'roomId': code,
          'peerId': _peerId,
          'inviteSecretHash': KeyAgreementService.hashInviteSecret(secret),
        });
        _roomSecrets[code] = secret;
        _roomId = code;
        _isPaired = false;
        _encryption.setRoomKey(secret);
        _chatRef = _db.ref('rooms/$code/messages');
        return code;
      } on FirebaseFunctionsException catch (error) {
        await _deleteProtectedValue(_roomSecretStorageKey(code));
        if (error.code == 'already-exists') continue;
        rethrow;
      } catch (_) {
        await _deleteProtectedValue(_roomSecretStorageKey(code));
        rethrow;
      }
    }
    throw StateError('Could not reserve a unique room code. Please retry.');
  }

  /// Joins with the full `ROOMID.SECRET` invite. The callable receives only
  /// its SHA-256 verifier before adding this authenticated device as a member.
  Future<bool> joinRoom(String invitation) async {
    final parsed = parseInviteCode(invitation);
    if (parsed == null) return false;
    _requireAuthenticatedUid();

    await _writeProtectedValue(
      _roomSecretStorageKey(parsed.roomId),
      parsed.secret,
    );
    try {
      await _functions.httpsCallable('joinRoomSecure').call({
        'roomId': parsed.roomId,
        'peerId': _peerId,
        'inviteSecretHash': KeyAgreementService.hashInviteSecret(parsed.secret),
      });
    } on FirebaseFunctionsException catch (error) {
      await _deleteProtectedValue(_roomSecretStorageKey(parsed.roomId));
      if (const {
        'not-found',
        'permission-denied',
        'resource-exhausted',
        'invalid-argument',
      }.contains(error.code)) {
        return false;
      }
      rethrow;
    } catch (_) {
      await _deleteProtectedValue(_roomSecretStorageKey(parsed.roomId));
      rethrow;
    }

    final room = parsed.roomId;
    _roomSecrets[room] = parsed.secret;
    _roomId = room;
    _isPaired = true;
    _encryption.setRoomKey(parsed.secret);
    _chatRef = _db.ref('rooms/$room/messages');
    _pairedRooms.putIfAbsent(room, () => 'Paired contact');
    await _saveState(strict: true);
    try {
      await _publishProfile();
    } catch (_) {
      /* Pairing remains valid if profile sync fails. */
    }
    await registerFcmToken();
    return true;
  }

  /// Switching is only initiated from the directory, with no chat route open.
  Future<void> selectRoom(String code) async {
    if (!_pairedRooms.containsKey(code)) {
      throw ArgumentError('Unknown paired room');
    }
    final secret = _roomSecrets[code];
    if (secret == null) {
      throw StateError('This conversation needs a fresh secure invite.');
    }
    unawaited(updateOnlineStatus(false).catchError((_) {}));
    _roomId = code;
    _isPaired = true;
    _encryption.setRoomKey(secret);
    _chatRef = Firebase.apps.isEmpty ? null : _db.ref('rooms/$code/messages');
    await _saveState();
  }

  Future<void> saveProfile(Map<String, String> profile) async {
    final name = (profile['name'] ?? '').trim();
    if (name.isEmpty || name.length > 40) {
      throw ArgumentError('Name must be 1–40 characters');
    }
    if ((profile['about'] ?? '').length > 140) {
      throw ArgumentError('About must be at most 140 characters');
    }
    _profile = Map.of(profile)..['name'] = name;
    await _saveState(strict: true);
    await _publishProfile();
  }

  Future<void> _publishProfile() async {
    if (Firebase.apps.isEmpty) return;
    for (final room in _pairedRooms.keys.toList()) {
      final secret = _roomSecrets[room];
      if (secret == null) continue;
      final cipher = EncryptionService.withPassphrase(secret);
      await _db
          .ref('rooms/$room/profiles/$_peerId')
          .set(cipher.encrypt(jsonEncode(_profile)));
    }
  }

  /// Decrypts a list preview with that room's locally protected secret.
  String decryptTextForRoom(String room, String ciphertext) {
    final secret = _roomSecrets[room];
    if (secret == null) throw const FormatException('Missing room key.');
    return EncryptionService.withPassphrase(secret).decrypt(ciphertext);
  }

  Map<String, String> partnerProfile(String room, Object? rawProfiles) {
    if (rawProfiles is! Map) return const {};
    for (final entry in rawProfiles.entries) {
      if (entry.key == _peerId || entry.value is! String) continue;
      final cipherText = entry.value as String;
      final cacheKey = '$room:${entry.key}';
      final cached = _partnerProfileCache[cacheKey];
      if (cached != null && cached.cipher == cipherText) {
        return cached.profile;
      }
      try {
        final secret = _roomSecrets[room];
        if (secret == null) return const {};
        final value = jsonDecode(
          EncryptionService.withPassphrase(secret).decrypt(cipherText),
        );
        if (value is Map) {
          final parsed = Map<String, String>.unmodifiable(
            value.map((k, v) => MapEntry(k.toString(), v.toString())),
          );
          _partnerProfileCache[cacheKey] = (
            cipher: cipherText,
            profile: parsed,
          );
          return parsed;
        }
      } catch (_) {
        /* Older clients may not have published a profile. */
      }
    }
    return const {};
  }

  /// How many recent messages the paired-directory screen keeps per room, so
  /// opening the directory never downloads full message history.
  static const int directoryMessageLimit = 50;

  /// Bounded stream of the recent messages in [room] for directory previews,
  /// unread badges, and the recent-calls list.
  Stream<DatabaseEvent> roomMessagesStream(
    String room, {
    int limit = directoryMessageLimit,
  }) {
    if (Firebase.apps.isEmpty || !_pairedRooms.containsKey(room)) {
      return const Stream.empty();
    }
    return _db
        .ref('rooms/$room/messages')
        .orderByChild('timestamp')
        .limitToLast(limit)
        .onValue;
  }

  /// Stream of one metadata child of [room] ('profiles', 'call', ...) so the
  /// directory can watch names and ringing calls without syncing messages.
  Stream<DatabaseEvent> roomChildStream(String room, String child) {
    if (Firebase.apps.isEmpty || !_pairedRooms.containsKey(room)) {
      return const Stream.empty();
    }
    return _db.ref('rooms/$room/$child').onValue;
  }

  /// Lightweight stream of only the latest message in [room] so background
  /// alert listeners do not re-download the entire room or typing/status nodes.
  Stream<DatabaseEvent> roomLatestMessageStream(String room) {
    if (Firebase.apps.isEmpty || !_pairedRooms.containsKey(room)) {
      return const Stream.empty();
    }
    return _db
        .ref('rooms/$room/messages')
        .orderByChild('timestamp')
        .limitToLast(1)
        .onValue;
  }

  DatabaseReference? _ensureChatRef() {
    if (_chatRef == null && _roomId != null && Firebase.apps.isNotEmpty) {
      _chatRef = _db.ref().child('rooms').child(_roomId!).child('messages');
    }
    return _chatRef;
  }

  // Stream of room members so the creator knows when a partner joins.
  Stream<DatabaseEvent> getRoomMembersStream() {
    if (_roomId == null || Firebase.apps.isEmpty) {
      return const Stream.empty();
    }
    return _db.ref().child('rooms').child(_roomId!).child('members').onValue;
  }

  // Send a message with optional image, voice note, reply quote, and disappearing timer.
  Future<void> sendMessage(
    String text, {
    String? imageUrl,
    String? imagePath,
    String? audioBase64,
    int? audioDurationSeconds,
    String? replyToText,
    String? replyToSenderId,
    int? expiresInSeconds,
  }) async {
    final injected = nextSendError;
    if (injected != null) {
      nextSendError = null;
      throw injected;
    }
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    if (expiresInSeconds != null &&
        !const {30, 300, 3600}.contains(expiresInSeconds)) {
      throw ArgumentError.value(
        expiresInSeconds,
        'expiresInSeconds',
        'Unsupported expiry',
      );
    }
    if (imagePath != null &&
        !imagePath.startsWith('images/${_roomId ?? ''}/')) {
      throw ArgumentError.value(imagePath, 'imagePath', 'Wrong room object');
    }

    final encryptedText = text.isNotEmpty ? _encryption.encrypt(text) : null;
    final encryptedAudio = (audioBase64 != null && audioBase64.isNotEmpty)
        ? _encryption.encrypt(audioBase64)
        : null;
    final encryptedReply = (replyToText != null && replyToText.isNotEmpty)
        ? _encryption.encrypt(replyToText)
        : null;
    await chatRef.push().set({
      'text': encryptedText,
      'imageUrl': imageUrl,
      'imagePath': imagePath,
      'timestamp': ServerValue.timestamp,
      'senderId': _peerId,
      'seen': false,
      'audioData': ?encryptedAudio,
      'audioDuration': ?audioDurationSeconds,
      'replyToText': ?encryptedReply,
      'replyToSenderId': ?replyToSenderId,
      'expiresInSeconds': ?expiresInSeconds,
    });
  }

  /// Starts a real-time voice or video call in the current room.
  Future<void> startCall({required bool isVideo}) async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    await _db.ref().child('rooms').child(_roomId!).child('call').set({
      'callerId': _peerId,
      'type': isVideo ? 'video' : 'voice',
      'status': 'ringing',
      'startedAt': ServerValue.timestamp,
    });
  }

  /// Accepts an incoming call in the current room.
  ///
  /// Returns false when the call node is already gone (the caller hung up
  /// first). Accepting must never resurrect a deleted call node — that would
  /// leave a zombie "connected" call the other side can never clear.
  Future<bool> acceptCall() async {
    if (_roomId == null || Firebase.apps.isEmpty) return false;
    final callRef = _db.ref('rooms/$_roomId/call');
    final result = await callRef.runTransaction((Object? value) {
      if (value is! Map) return Transaction.abort();
      return Transaction.success({...value, 'status': 'connected'});
    });
    if (!result.committed) return false;
    try {
      await callRef.update({'connectedAt': ServerValue.timestamp});
    } catch (_) {}
    return true;
  }

  /// True when the live call node has been answered — `status` is
  /// `connected`, or a `connectedAt` stamp exists.
  ///
  /// The ring timeout races the other phone's accept right at the deadline,
  /// so it asks this before ending a call: an answered call must never be
  /// closed as missed. A missing (or unreadable) node counts as not
  /// connected, which is what the timeout already assumed.
  Future<bool> isCallConnected() async {
    if (_roomId == null || Firebase.apps.isEmpty) return false;
    try {
      final snapshot = await _db.ref('rooms/$_roomId/call').get();
      final value = snapshot.value;
      if (value is! Map) return false;
      return value['status']?.toString() == 'connected' ||
          value['connectedAt'] != null;
    } catch (_) {
      return false;
    }
  }

  /// The paired partner's published profile name, or null when the profile is
  /// missing or carries no name (older clients never published one).
  ///
  /// A screen that watches only the `call` node (the calculator's incoming
  /// ring) has no profile snapshot to read, so it asks this once before
  /// pushing [CallScreen].
  Future<String?> partnerName(String room) async {
    if (Firebase.apps.isEmpty) return null;
    try {
      final snapshot = await _db.ref('rooms/$room/profiles').get();
      final name = partnerProfile(room, snapshot.value)['name']?.trim();
      return (name == null || name.isEmpty) ? null : name;
    } catch (_) {
      return null;
    }
  }

  /// Ends or declines the active call in the current room and logs it in the
  /// chat history.
  ///
  /// [outcome] describes how the call ended when it never connected:
  /// 'missed' (nobody accepted — ring timeout, offline callee, or the caller
  /// cancelled) or 'declined' (the callee rejected). A connected call always
  /// logs as 'completed' with its duration.
  ///
  /// Pass [callInfo] (the local copy of the call node) to skip the read
  /// round-trip — the caller's own screen already knows the facts, and a
  /// `get()` that fails on a flaky network must never leave the call ringing
  /// on the other phone.
  Future<void> endCall({String outcome = 'completed', Map? callInfo}) async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    final room = _db.ref('rooms/$_roomId');
    Map? call = callInfo;
    if (call == null) {
      final snapshot = await room.child('call').get();
      if (snapshot.value is! Map) return;
      call = Map.from(snapshot.value as Map);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final connected = (call['connectedAt'] as num?)?.toInt();
    final wasConnected =
        connected != null || call['status']?.toString() == 'connected';
    // The node must always be cleared, even if the timestamp write is still
    // pending — otherwise both sides are stuck on a ringing screen forever.
    final startedRaw = call['startedAt'];
    final startedKey = startedRaw is int ? startedRaw : now;
    const validOutcomes = {'completed', 'missed', 'declined'};
    final resolved = validOutcomes.contains(outcome) ? outcome : 'missed';
    final sender = call['callerId']?.toString() ?? '';
    if (sender.isNotEmpty) {
      try {
        // Log while the call node still exists so the rules can verify this
        // entry against its caller ID and start timestamp.
        await room.child('messages/call_$startedKey').set({
          'senderId': sender,
          'timestamp': now,
          'seen': false,
          'callType': call['type'],
          'callStartedAt': startedKey,
          if (connected != null)
            'callSeconds': max(0, (now - connected) ~/ 1000)
          else if (wasConnected)
            'callSeconds': 0,
          'callOutcome': wasConnected ? 'completed' : resolved,
        });
      } catch (_) {
        // The call must still be cleared if its history entry cannot be saved.
      }
    }
    await room.child('call').remove();
  }

  /// Writes this peer's SDP (offer or answer) under `call/signal/{peerId}`.
  ///
  /// Callers must write this AFTER [startCall]: startCall replaces the whole
  /// `call` node and would wipe an earlier signal.
  Future<void> writeCallSignal(String type, String sdp) async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    await _db
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('call')
        .child('signal')
        .child(_peerId)
        .set({'type': type, 'sdp': sdp, 'ts': ServerValue.timestamp});
  }

  /// Appends one ICE candidate under `call/ice/{peerId}/{pushId}`.
  Future<void> writeCallIceCandidate(
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) async {
    if (_roomId == null || Firebase.apps.isEmpty || candidate.isEmpty) return;
    await _db
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('call')
        .child('ice')
        .child(_peerId)
        .push()
        .set({
          'candidate': candidate,
          'sdpMid': sdpMid,
          'sdpMLineIndex': sdpMLineIndex,
          'ts': ServerValue.timestamp,
        });
  }

  /// Listens to real-time call state and audio stream in the current room.
  Stream<DatabaseEvent> getCallStream() {
    if (_roomId == null || Firebase.apps.isEmpty) {
      return const Stream.empty();
    }
    return _db.ref().child('rooms').child(_roomId!).child('call').onValue;
  }

  /// Toggles an emoji reaction by this peer on [messageKey].
  Future<void> toggleReaction(
    String messageKey,
    String emoji, {
    String? currentReaction,
  }) async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    final reactionRef = chatRef
        .child(messageKey)
        .child('reactions')
        .child(_peerId);
    if (currentReaction == emoji) {
      await reactionRef.remove();
    } else {
      await reactionRef.set(emoji);
    }
  }

  /// Marks incoming partner messages as seen.
  Future<void> markMessagesSeen(Iterable<String> messageKeys) async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    for (final key in messageKeys) {
      await chatRef.child(key).update({'seen': true});
    }
  }

  Future<void> _deleteStorageUrlBestEffort(Object? rawUrl) async {
    if (rawUrl is! String || rawUrl.isEmpty || Firebase.apps.isEmpty) return;
    try {
      await FirebaseStorage.instance.refFromURL(rawUrl).delete();
    } catch (_) {}
  }

  /// Deletes a single message from the room for everyone and removes any cloud image.
  Future<void> deleteMessage(String messageKey, {String? imageUrl}) async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    var urlToDelete = imageUrl;
    if (urlToDelete == null) {
      try {
        final snap = await chatRef.child(messageKey).child('imageUrl').get();
        if (snap.value is String) {
          urlToDelete = snap.value as String;
        }
      } catch (_) {}
    }
    await chatRef.child(messageKey).remove();
    await _deleteStorageUrlBestEffort(urlToDelete);
  }

  /// Clears all messages in the current room and cleans up cloud images.
  /// Deletes each message at its member-authorized path rather than requiring
  /// broad write access to the entire messages collection.
  Future<void> clearAllMessages() async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    try {
      final snap = await chatRef.get();
      final raw = snap.value;
      if (raw is! Map) return;
      for (final entry in raw.entries) {
        final messageKey = entry.key.toString();
        final imageUrl = entry.value is Map
            ? (entry.value as Map)['imageUrl']
            : null;
        try {
          await chatRef.child(messageKey).remove();
          await _deleteStorageUrlBestEffort(imageUrl);
        } catch (_) {
          // Continue clearing other messages if one entry cannot be removed.
        }
      }
    } catch (_) {}
  }

  // Listen for messages (bounded to recent 150 to keep Firebase bandwidth low).
  Stream<DatabaseEvent> getMessagesStream({int limit = 150}) {
    final chatRef = _ensureChatRef();
    if (chatRef == null) {
      return const Stream.empty();
    }
    return chatRef.orderByChild('timestamp').limitToLast(limit).onValue;
  }

  /// Downloads and decrypts a chat photo into bounded memory only. No
  /// plaintext image is ever written to a cache file.
  Future<Uint8List?> downloadDecryptedImage(
    String downloadUrl, {
    required String roomId,
  }) async {
    final secret = _roomSecrets[roomId];
    if (secret == null) throw const FormatException('Missing room key.');
    final encrypted = await FirebaseStorage.instance
        .refFromURL(downloadUrl)
        .getData(5 * 1024 * 1024 + 28);
    if (encrypted == null) return null;
    return EncryptionService.withPassphrase(secret).decryptBytes(encrypted);
  }

  /// Encrypts photo bytes locally before upload, gives the object a random
  /// name, and returns its member-readable download URL plus Storage path.
  Future<({String url, String path})> uploadImage(
    File imageFile, {
    void Function(double progress)? onProgress,
  }) async {
    if (Firebase.apps.isEmpty || authUid == null) {
      throw const MediaUploadException(
        'The photo could not be uploaded because secure Firebase sign-in is unavailable.',
      );
    }
    final room = _roomId;
    final secret = room == null ? null : _roomSecrets[room];
    if (room == null || secret == null) {
      throw const MediaUploadException('Pair securely before sending photos.');
    }

    Reference? objectRef;
    try {
      final plainBytes = await imageFile.readAsBytes();
      if (plainBytes.isEmpty || plainBytes.length > 5 * 1024 * 1024) {
        throw const MediaUploadException('Choose a photo smaller than 5 MB.');
      }
      final encryptedBytes = EncryptionService.withPassphrase(secret)
          .encryptBytes(Uint8List.fromList(plainBytes));
      final objectName = base64UrlEncode(
        List<int>.generate(24, (_) => _random.nextInt(256)),
      ).replaceAll('=', '');
      objectRef = FirebaseStorage.instance.ref('images/$room/$objectName.bin');
      final task = objectRef.putData(
        encryptedBytes,
        SettableMetadata(contentType: 'application/octet-stream'),
      );
      if (onProgress != null) {
        task.snapshotEvents.listen((snapshot) {
          final total = snapshot.totalBytes;
          if (total > 0) onProgress(snapshot.bytesTransferred / total);
        });
      }
      await task;
      final downloadUrl = await objectRef.getDownloadURL();
      return (url: downloadUrl, path: objectRef.fullPath);
    } on FirebaseException catch (e) {
      if (objectRef != null) {
        try {
          await objectRef.delete();
        } catch (_) {}
      }
      debugPrint('uploadImage failed: ${e.code} ${e.message}');
      throw MediaUploadException(_uploadReason(e.code));
    } on MediaUploadException {
      rethrow;
    } catch (e) {
      if (objectRef != null) {
        try {
          await objectRef.delete();
        } catch (_) {}
      }
      debugPrint('uploadImage failed: $e');
      throw const MediaUploadException('The photo could not be uploaded.');
    }
  }

  /// Turns a Storage error code into something a person can act on.
  static String _uploadReason(String code) {
    switch (code) {
      case 'unauthorized':
      case 'permission-denied':
        return 'Storage refused the photo — the storage rules need updating.';
      case 'canceled':
        return 'The photo upload was cancelled.';
      case 'quota-exceeded':
        return 'Storage is full.';
      case 'retry-limit-exceeded':
        return 'The upload kept failing — check your connection.';
      default:
        return 'The photo could not be uploaded ($code).';
    }
  }

  // Update online status keyed by this device's peerId.
  Future<void> updateOnlineStatus(bool isOnline, {bool? isTyping}) async {
    _isOnline = isOnline;
    if (_roomId == null || Firebase.apps.isEmpty) return;
    final nextTyping = isTyping ?? false;
    if (_lastWrittenStatusRoom == _roomId &&
        _lastWrittenOnline == isOnline &&
        _lastWrittenTyping == nextTyping) {
      return;
    }
    _lastWrittenStatusRoom = _roomId;
    _lastWrittenOnline = isOnline;
    _lastWrittenTyping = nextTyping;

    final statusRef = _db
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('status')
        .child(_peerId);

    await statusRef.set({
      'isOnline': isOnline,
      'isTyping': nextTyping,
      'lastSeen': ServerValue.timestamp,
    });
  }

  /// Updates typing status for the current peer.
  Future<void> updateTypingStatus(bool isTyping) async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    await updateOnlineStatus(_isOnline, isTyping: isTyping);
  }

  // Listen for partner's online status.
  Stream<DatabaseEvent> getPartnerStatusStream([String? partnerPeerId]) {
    if (_roomId == null || Firebase.apps.isEmpty) {
      return const Stream.empty();
    }
    final statusRef = _db.ref().child('rooms').child(_roomId!).child('status');
    if (partnerPeerId != null && partnerPeerId.isNotEmpty) {
      return statusRef.child(partnerPeerId).onValue;
    }
    return statusRef.onValue;
  }

  // Current 6-character room code.
  String getShortCode() => _roomId ?? '';

  @visibleForTesting
  void setRoomIdForTesting(
    String? code, {
    bool paired = false,
    String? secret,
  }) {
    if (code == null) {
      _roomId = null;
      _chatRef = null;
      _isPaired = false;
      _encryption.resetKey();
      return;
    }
    final room = code.trim().toUpperCase();
    final key = secret ?? _roomSecrets[room] ?? generateRoomSecret();
    _roomSecrets[room] = key;
    final testStore = _secureStorageOverride;
    if (testStore != null) testStore[_roomSecretStorageKey(room)] = key;
    _roomId = room;
    _isPaired = paired;
    _encryption.setRoomKey(key);
    _chatRef = Firebase.apps.isEmpty ? null : _db.ref('rooms/$room/messages');
  }
}
