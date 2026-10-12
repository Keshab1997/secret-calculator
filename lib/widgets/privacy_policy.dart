import 'package:flutter/material.dart';

import 'messaging_style.dart';

const privacyPolicyEffectiveDate = '12 October 2026';

Future<void> showPrivacyPolicy(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: MessagingPalette.of(context).page,
    builder: (_) => const PrivacyPolicySheet(),
  );
}

class PrivacyPolicySheet extends StatelessWidget {
  const PrivacyPolicySheet({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = MessagingPalette.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.55,
      maxChildSize: 0.96,
      builder: (context, controller) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: palette.sub.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Privacy, safety & acceptable use',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: const [
                Text(
                  'Effective $privacyPolicyEffectiveDate',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 16),
                _PolicySection(
                  title: 'What this app is',
                  body:
                      'Calculator includes an optional private messaging area. '
                      'Use it only with people you know and trust. A disguised '
                      'interface does not make unlawful activity lawful and does '
                      'not guarantee anonymity.',
                ),
                _PolicySection(
                  title: 'Information handled',
                  body:
                      'The app may process an anonymous Firebase account ID, '
                      'Personal ID, profile name/photo/about text, pairing records, '
                      'messages and media, presence and last-seen information, call '
                      'records, notification tokens, and basic app/device crash '
                      'diagnostics. Calculator history, preferences, passcodes and '
                      'encryption keys are also stored on your device.',
                ),
                _PolicySection(
                  title: 'How information is used and shared',
                  body:
                      'Information is used to pair contacts, deliver messages, '
                      'media, calls and disguised notifications, remember settings, '
                      'and diagnose crashes. Firebase and related Google services '
                      'process cloud data needed to provide these features. Your '
                      'profile and conversation content are shared with contacts '
                      'you pair with. The app does not provide a public people '
                      'directory.',
                ),
                _PolicySection(
                  title: 'Encryption and its limits',
                  body:
                      'Message text and supported media are encrypted on the device '
                      'before upload, and room keys are kept in protected device '
                      'storage. Some metadata—such as account, pairing, delivery, '
                      'presence and notification information—is not message content '
                      'and may be visible to service providers. First contact is '
                      'not cryptographically authenticated against a trusted '
                      'identity, so verify a contact’s Personal ID through another '
                      'trusted channel. A compromised/unlocked phone or an unsafe '
                      'recipient can still expose content.',
                ),
                _PolicySection(
                  title: 'Permissions',
                  body:
                      'Camera/photos, microphone, notifications and biometric or '
                      'device authentication are requested only for the feature you '
                      'choose to use. You can deny or revoke permissions in your '
                      'phone settings, although the related feature may stop working.',
                ),
                _PolicySection(
                  title: 'Retention and deletion',
                  body:
                      'Local app data remains until you clear it or uninstall the '
                      'app. Cloud records may remain according to conversation '
                      'settings and Firebase configuration. Unpairing removes a '
                      'contact from this device but may not delete shared history, '
                      'backups, server records, or copies already saved by a '
                      'recipient. Do not send information that requires guaranteed '
                      'erasure.',
                ),
                _PolicySection(
                  title: 'Safety and acceptable use',
                  body:
                      'Do not use this app for harassment, stalking, threats, fraud, '
                      'impersonation, unauthorized access, malware, trafficking, '
                      'exploitation, non-consensual intimate content, child sexual '
                      'abuse material, planning violence, hiding evidence, or any '
                      'other illegal or harmful activity. Do not contact or record '
                      'people without any consent required by law. You are '
                      'responsible for your messages and for complying with local law.',
                ),
                _PolicySection(
                  title: 'Children',
                  body:
                      'This app is not intended for children under 13. Anyone below '
                      'the digital-consent age in their country should not use the '
                      'messaging features without a parent or legal guardian.',
                ),
                _PolicySection(
                  title: 'Your choices and incident response',
                  body:
                      'You can decline permissions, avoid pairing, remove local '
                      'profile information, unpair contacts, clear conversations '
                      'where supported, or uninstall the app. If you receive harmful '
                      'or illegal content, stop engaging, preserve evidence when '
                      'safe, block contact outside the app, and report it to the '
                      'appropriate platform or local authority. For policy questions '
                      'or a data request, use the repository’s support/Issues channel.',
                ),
                _PolicySection(
                  title: 'Changes',
                  body:
                      'This notice may change when app features or service providers '
                      'change. The effective date above identifies this version.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  const _PolicySection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(body, style: const TextStyle(fontSize: 13.5, height: 1.45)),
      ],
    ),
  );
}
