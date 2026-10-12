# Rules for the release build. Flutter turns on R8 for `flutter build apk
# --release`, and R8 cannot see reflection — which is exactly how Firebase
# finds half of itself.

# Every Firebase SDK ships a "registrar" whose class name is written into the
# merged AndroidManifest (the ComponentDiscoveryService metadata entries) and
# instantiated by name at startup. R8 sees no ordinary reference to that
# constructor, so it deleted it, and the SDKs quietly vanished from the release
# APK:
#
#   W ComponentDiscovery: Could not instantiate com.google.firebase.crashlytics.CrashlyticsRegistrar
#   Caused by: java.lang.NoSuchMethodException: ...CrashlyticsRegistrar.<init> []
#
# The app noticed only at the very end of the chain: with no Crashlytics
# component registered, FirebaseCrashlytics.getInstance() throws
# "FirebaseCrashlytics component is not present." while firebase_core collects
# plugin constants, so Firebase.initializeApp() itself fails. Firebase.apps
# stays empty, anonymous sign-in never happens, and the pairing screen shows a
# Firebase Console message about Anonymous Authentication that has nothing to do
# with the real cause. App Check, Installations and Messaging lost their
# registrars the same way.
#
# Keeping the registrar classes *and their members* — the constructor R8 is
# throwing away is a member — is the whole fix. `*` on the members also keeps
# the names, which matters because the manifest spells them out.
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }

# Crashlytics reads its own public API and report models back reflectively too.
-keep class com.google.firebase.crashlytics.** { *; }
