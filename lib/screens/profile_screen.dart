import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/firebase_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/messaging_style.dart';
import '../widgets/option_sheet.dart';
import '../widgets/security_settings.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _service = FirebaseService();
  late final TextEditingController _name;
  late final TextEditingController _about;
  late final TextEditingController _decoyCode;
  String? _photo;
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: _service.profile['name']);
    _about = TextEditingController(text: _service.profile['about']);
    _decoyCode = TextEditingController(text: _service.decoyPasscode ?? '');
    _photo = _service.profile['photo'];
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _decoyCode.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 65,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.length > 180000) {
        setState(() => _error = 'Please choose a smaller photo.');
        return;
      }
      setState(() {
        _photo = base64Encode(bytes);
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open this photo.');
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final decoy = _decoyCode.text.trim();
      final decoyOk = await _service.setDecoyPasscode(decoy);
      if (!decoyOk) {
        if (mounted) {
          setState(
            () => _error = 'Decoy code must be 4–8 digits and different from your unlock code.',
          );
        }
        return;
      }
      await _service.saveProfile({
        'name': _name.text,
        'about': _about.text,
        'photo': ?_photo,
      });
      if (mounted) {
        AppToast.show(context, 'Profile saved', kind: AppToastKind.success);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Use a name of 1–40 characters and check your connection. Profile sync can be retried with Save.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// One section of the profile, on a soft card so the settings read as
  /// groups instead of a single page of loose fields.
  Widget _card({required Widget child}) {
    final palette = MessagingPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.cardBorder),
      ),
      child: child,
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
        color: MessagingPalette.of(context).sub,
      ),
    ),
  );

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: chatGreen.withValues(alpha: 0.10),
            ),
            child: Icon(icon, size: 20, color: chatGreen),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: MessagingPalette.of(context).sub,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: 20,
            color: MessagingPalette.of(context).sub,
          ),
        ],
      ),
    ),
  );

  InputDecoration _fieldDecoration(String label, IconData icon) =>
      InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        filled: true,
        fillColor: MessagingPalette.of(context).fieldFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: MessagingPalette.of(context).fieldBorder,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: chatGreen, width: 1.4),
        ),
      );

  String _darkModeLabel() {
    switch (FirebaseService().themeMode) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'Follow the phone';
    }
  }

  Future<void> _showDarkModeOptions() async {
    final current = FirebaseService().themeMode;
    final choice = await showOptionSheet(
      context,
      title: 'Dark mode',
      subtitle: 'Only the messaging side changes — the calculator stays dark',
      items: [
        OptionSheetItem(
          value: 'system',
          icon: Icons.brightness_auto_outlined,
          label: 'Automatic',
          subtitle: current == ThemeMode.system ? 'In use' : 'Follow the phone',
        ),
        OptionSheetItem(
          value: 'light',
          icon: Icons.light_mode_outlined,
          label: 'Light',
          subtitle: current == ThemeMode.light ? 'In use' : null,
        ),
        OptionSheetItem(
          value: 'dark',
          icon: Icons.dark_mode_outlined,
          label: 'Dark',
          subtitle: current == ThemeMode.dark ? 'In use' : null,
        ),
      ],
    );
    if (choice == null || !mounted) return;
    final mode = switch (choice) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    await FirebaseService().setThemeMode(mode);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          child: Column(
            children: [
              Center(
                child: Stack(
                  children: [
                    ProfileAvatar(photo: _photo, radius: 52),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: chatGreen),
                        tooltip: 'Change profile photo',
                        onPressed: _saving ? null : _pickPhoto,
                        icon: const Icon(Icons.camera_alt),
                      ),
                    ),
                  ],
                ),
              ),
              if (_photo != null)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _photo = null),
                  child: const Text('Remove photo'),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                enabled: !_saving,
                maxLength: 40,
                decoration: _fieldDecoration('Name', Icons.person_outline),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _about,
                enabled: !_saving,
                maxLength: 140,
                maxLines: 2,
                decoration: _fieldDecoration('About', Icons.info_outline),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionLabel('Privacy & security'),
        _card(
          child: Column(
            children: [
              _tile(
                icon: Icons.fingerprint,
                title: 'Passcode & Biometric Lock',
                subtitle: 'Change your secret code and the unlock prompt',
                onTap: _saving
                    ? () {}
                    : () => showSecuritySettingsSheet(context),
              ),
              const Divider(height: 20),
              _tile(
                icon: Icons.dark_mode_outlined,
                title: 'Dark mode',
                subtitle: _darkModeLabel(),
                onTap: _saving ? () {} : _showDarkModeOptions,
              ),
              TextField(
                controller: _decoyCode,
                enabled: !_saving,
                maxLength: 8,
                keyboardType: TextInputType.number,
                decoration:
                    _fieldDecoration(
                      'Decoy passcode (optional, 4–8 digits)',
                      Icons.shield_outlined,
                    ).copyWith(
                      helperText: 'Opens an empty chat list if someone forces you to unlock',
                      helperStyle: TextStyle(
                        fontSize: 12,
                        color: MessagingPalette.of(context).sub,
                      ),
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionLabel('Sharing'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your profile is shared with paired contacts. The calculator name and icon on your phone do not change.',
                style: TextStyle(
                  color: MessagingPalette.of(context).sub,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'To invite someone, open Chats → Pair new contact. Each conversation has its own pairing code. Unpair a contact from that chat\'s menu.',
                style: TextStyle(fontSize: 13, height: 1.35),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: chatGreen,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: Text(_saving ? 'Saving…' : 'Save profile'),
        ),
      ],
    ),
  );
}
