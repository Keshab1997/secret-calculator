import 'dart:async' show unawaited;
import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'screens/calculator_screen.dart';
import 'widgets/messaging_style.dart';
import 'services/firebase_service.dart';
import 'services/native_bridge_service.dart';
import 'services/notification_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Paint the calculator before touching plugins, disk or the network. A
  // release-mode exception during startup is otherwise indistinguishable from
  // the app opening and immediately closing. The calculator remains usable
  // while the guarded bootstrap finishes in the background.
  final startupComplete = _bootstrapApp();
  runApp(CalculatorApp(startupComplete: startupComplete));
}

Future<void> _bootstrapApp() async {
  try {
    await NativeBridgeService().cleanupStaleVoicePlaybackFiles();
  } catch (error) {
    debugPrint('Voice-file cleanup failed: $error');
  }

  // Firebase init throws on a bad or missing config (google-services.json is a
  // CI secret, not in the repo) and can hang when it neither returns nor
  // throws — the timeout covers both. Neither case may take down the already
  // visible calculator.
  try {
    await Firebase.initializeApp().timeout(const Duration(seconds: 10));
  } catch (error) {
    debugPrint('Firebase initialization failed: $error');
  }

  // Crashlytics needs a live Firebase app. Reaching for its instance when init
  // failed throws (`No Firebase App '[DEFAULT]' has been created`) right here —
  // before runApp() — which strands the splash the same way, so the whole
  // error-reporting block is gated on the app actually existing. The instance
  // lookup itself can also throw on a device where the Crashlytics component
  // never registered, so it stays inside a guard too: error reporting must
  // never be the thing that kills startup.
  if (Firebase.apps.isNotEmpty) {
    try {
      // Report uncaught errors to Crashlytics: framework errors come through
      // FlutterError.onError, everything else (async, platform) through the
      // platform dispatcher. presentError keeps the normal debug output.
      final crashlytics = FirebaseCrashlytics.instance;
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        crashlytics.recordFlutterFatalError(details);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        crashlytics.recordError(error, stack, fatal: true);
        return true;
      };
    } catch (error) {
      debugPrint('Crashlytics unavailable: $error');
    }
  }

  try {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (error) {
    debugPrint('Background messaging unavailable: $error');
  }
  final firebaseService = FirebaseService();
  // Only local work may sit between the launch screen and the first frame.
  // A network sign-in held that spot before, and signInAnonymously() has no
  // timeout of its own: on a device that cannot reach Firebase the app sat
  // on the native splash forever — a try/catch catches errors, not a hang.
  // loadSavedState() swallows its own errors, but only a timeout bounds the
  // secure-store read it waits on: a wedged platform keystore would otherwise
  // hold the first frame back the same way.
  try {
    await firebaseService.loadSavedState().timeout(const Duration(seconds: 10));
  } catch (error) {
    debugPrint('Loading saved state failed: $error');
  }
  unawaited(
    firebaseService
        .ensureAuthenticated()
        .then((_) {
          // Fire-and-forget: publishes the FCM token for closed-app
          // notifications once the anonymous identity exists.
          return firebaseService.registerFcmToken();
        })
        .catchError((Object error) {
          // Keep the calculator usable even if Anonymous Auth has not yet been
          // enabled in Firebase Console; secure pairing will explain the setup
          // need.
          debugPrint('Firebase anonymous sign-in unavailable: $error');
        }),
  );
  unawaited(
    NotificationService().initialize().catchError((Object error) {
      debugPrint('Notification initialization failed: $error');
    }),
  );
}

class CalculatorApp extends StatelessWidget {
  const CalculatorApp({super.key, this.startupComplete});

  /// Completes after local state and Firebase startup have been attempted.
  /// The first frame never waits for it.
  final Future<void>? startupComplete;

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
        home: CalculatorScreen(startupComplete: startupComplete),
      ),
    );
  }
}
