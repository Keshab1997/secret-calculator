import 'package:flutter/material.dart';

import '../services/firebase_service.dart';
import 'app_toast.dart';
import 'messaging_style.dart';

/// The device-wide unlock settings: the custom secret code and the biometric
/// prompt in front of Secret Chat.
///
/// These belong to the phone, not to one conversation, so the entry point
/// lives on the profile instead of inside a chat's menu.
Future<void> showSecuritySettingsSheet(BuildContext context) async {
  final service = FirebaseService();
  final codeCtrl = TextEditingController(text: service.customPasscode);
  var bioEnabled = service.biometricEnabled;
  String? localError;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (sheetContext, setDialogState) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.fingerprint, color: chatGreen),
            SizedBox(width: 10),
            Flexible(child: Text('Passcode & Biometric Lock')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Custom Secret Calculator Code (4–8 digits):',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 8,
              style: const TextStyle(
                color: chatInk,
                fontSize: 20,
                letterSpacing: 4,
                fontWeight: FontWeight.bold,
              ),
              decoration: InputDecoration(
                hintText: '1997',
                filled: true,
                fillColor: const Color(0xFFF2F3F5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                errorText: localError,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Fingerprint / Screen Lock'),
              subtitle: const Text(
                'Ask for device fingerprint before opening Secret Chat',
                style: TextStyle(fontSize: 12),
              ),
              value: bioEnabled,
              onChanged: (val) {
                setDialogState(() => bioEnabled = val);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: chatGreen),
            onPressed: () async {
              final ok = await service.setCustomPasscode(codeCtrl.text);
              if (!ok) {
                setDialogState(() {
                  localError = 'Enter 4 to 8 digits (0-9)';
                });
                return;
              }
              await service.setBiometricEnabled(bioEnabled);
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              if (!context.mounted) return;
              AppToast.show(
                context,
                'Saved! Passcode: ${service.customPasscode} • Biometric: ${bioEnabled ? "ON" : "OFF"}',
                kind: AppToastKind.success,
              );
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    ),
  );
  codeCtrl.dispose();
}
