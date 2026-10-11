import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

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

  Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(initSettings);

    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      // Android 13+ silently drops notifications unless POST_NOTIFICATIONS
      // is granted — request it explicitly on startup.
      await android.requestNotificationsPermission();
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
  }

  Future<void> showFakeNotification({String? customMessage}) async {
    final message =
        customMessage ??
        _fakeMessages[DateTime.now().millisecond % _fakeMessages.length];

    const androidDetails = AndroidNotificationDetails(
      'calculator_channel_v2',
      'Calculator',
      channelDescription: 'Calculator notifications',
      importance: Importance.high,
      priority: Priority.high,
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
      DateTime.now().millisecond,
      'Calculator',
      message,
      details,
    );
  }
}
