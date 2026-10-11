import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'screens/calculator_screen.dart';
import 'widgets/messaging_style.dart';
import 'services/firebase_service.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  await FirebaseService().loadSavedState();
  await NotificationService().initialize();
  // Fire-and-forget: publishes the FCM token for closed-app notifications.
  FirebaseService().registerFcmToken();
  runApp(const CalculatorApp());
}

class CalculatorApp extends StatelessWidget {
  const CalculatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The app-level theme IS the messaging theme: light by default, with a
    // full dark variant the user can switch to from the profile. Flipping it
    // republishes through the service's notifier, so the whole tree re-skins
    // in place. The calculator face carries its own dark theme and never
    // follows the mode.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: FirebaseService().themeModeChanged,
      builder: (context, mode, _) => MaterialApp(
        title: 'Calculator',
        debugShowCheckedModeBanner: false,
        navigatorKey: NotificationService().navigatorKey,
        theme: messagingTheme,
        darkTheme: messagingDarkTheme,
        themeMode: mode,
        home: const CalculatorScreen(),
      ),
    );
  }
}
