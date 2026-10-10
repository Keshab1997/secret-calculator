import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

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
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
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
  }

  Future<void> showFakeNotification({String? customMessage}) async {
    final message = customMessage ?? _fakeMessages[DateTime.now().millisecond % _fakeMessages.length];
    
    const androidDetails = AndroidNotificationDetails(
      'calculator_channel',
      'Calculator',
      channelDescription: 'Calculator notifications',
      importance: Importance.low,
      priority: Priority.low,
      showWhen: false,
      icon: '@mipmap/ic_launcher',
    );
    
    const iosDetails = DarwinNotificationDetails(
      presentAlert: false,
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