import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (_) {}
  if (message.notification == null && message.data.isNotEmpty) {
    await NotificationService().initialize(requestPermission: false);
    await NotificationService().showFakeNotification(
      messageId: message.data['messageId']?.toString(),
    );
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _fcmListenersRegistered = false;
  DateTime? _lastAlertAt;
  String? _lastAlertMessageId;

  /// Fixed notification ID so multiple SMS alerts replace the single banner
  /// instead of stacking suspicious multiple notifications on the lock screen.
  static const int disguisedNotificationId = 1997;

  /// Android notification tag — together with [disguisedNotificationId] this
  /// keeps every disguised alert in one replaceable slot.
  static const String disguisedNotificationTag = 'calculator_sync';

  /// Navigator key so a disguised alert tap can force the root Calculator
  /// screen (wired up by `main.dart`).
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Minimum interval between disguised alerts to keep notifications subtle.
  static const Duration minAlertCooldown = Duration(seconds: 25);

  // Fake notification messages that look like calculator notifications
  static const List<String> _fakeMessages = [
    '📊 New calculation saved',
    '🔢 Memory cleared',
    '📱 Calculator history updated',
    '📎 Attachment added to memory',
    '⚙️ Settings modified',
    '📐 Formula saved',
    '🧮 Calculation complete',
    '📊 Statistics updated',
    '💾 Data backed up',
    '🔄 Sync complete',
  ];

  Future<void> initialize({bool requestPermission = true}) async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    final iosSettings = DarwinInitializationSettings(
      requestAlertPermission: requestPermission,
      requestBadgePermission: requestPermission,
      requestSoundPermission: requestPermission,
    );

    final initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      if (requestPermission) {
        // Android 13+ silently drops notifications unless POST_NOTIFICATIONS
        // is granted — request it explicitly on startup.
        await android.requestNotificationsPermission();
      }
      // Fresh channel id: Android refuses importance changes on an already
      // created channel, so existing installs would stay stuck on the old
      // silent/low-importance channel otherwise.
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          'calculator_channel_v2',
          'Calculator',
          description: 'Calculator notifications',
          importance: Importance.high,
        ),
      );
    }

    if (requestPermission &&
        !_fcmListenersRegistered &&
        Firebase.apps.isNotEmpty) {
      _fcmListenersRegistered = true;
      try {
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(
              alert: true,
              badge: false,
              sound: true,
            );
        FirebaseMessaging.onMessage.listen((message) {
          final msgId = message.data['messageId']?.toString();
          showFakeNotification(
            customMessage: message.notification?.body,
            messageId: msgId,
          );
        });
      } catch (_) {}
    }
  }

  @visibleForTesting
  bool shouldAllowAlert({String? messageId, DateTime? now}) {
    final current = now ?? DateTime.now();
    if (messageId != null &&
        messageId.isNotEmpty &&
        _lastAlertMessageId == messageId) {
      return false;
    }
    if (_lastAlertAt != null &&
        current.difference(_lastAlertAt!) < minAlertCooldown) {
      return false;
    }
    _lastAlertAt = current;
    if (messageId != null && messageId.isNotEmpty) {
      _lastAlertMessageId = messageId;
    }
    return true;
  }

  @visibleForTesting
  void resetThrottleForTesting() {
    _lastAlertAt = null;
    _lastAlertMessageId = null;
  }

  /// Tapping a disguised alert always opens the app at the root Calculator
  /// screen — never a secret screen — even if the messaging stack is up.
  void _onNotificationTapped(NotificationResponse response) {
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  Future<void> showFakeNotification({
    String? customMessage,
    String? messageId,
  }) async {
    if (!shouldAllowAlert(messageId: messageId)) return;

    final message =
        customMessage ??
        _fakeMessages[DateTime.now().millisecond % _fakeMessages.length];

    const androidDetails = AndroidNotificationDetails(
      'calculator_channel_v2',
      'Calculator',
      channelDescription: 'Calculator notifications',
      importance: Importance.high,
      priority: Priority.high,
      tag: disguisedNotificationTag,
      onlyAlertOnce: true,
      showWhen: false,
      icon: '@mipmap/ic_launcher',
    );

    // No banner on iOS while the app is open; without presentAlert the
    // notification would never be visible in the background either.
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(
      disguisedNotificationId,
      'Calculator',
      message,
      details,
    );
  }
}
