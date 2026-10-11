import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/firebase_service.dart';
import '../widgets/messaging_style.dart';

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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Profile saved')));
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

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Stack(
            children: [
              ProfileAvatar(photo: _photo, radius: 58),
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
            onPressed: _saving ? null : () => setState(() => _photo = null),
            child: const Text('Remove photo'),
          ),
        const SizedBox(height: 28),
        TextField(
          controller: _name,
          enabled: !_saving,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Name',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _about,
          enabled: !_saving,
          maxLength: 140,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'About',
            prefixIcon: Icon(Icons.info_outline),
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _decoyCode,
          enabled: !_saving,
          maxLength: 8,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Decoy passcode (optional, 4–8 digits)',
            helperText:
                'Opens an empty chat list if someone forces you to unlock',
            prefixIcon: Icon(Icons.shield_outlined),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Your profile is shared with paired contacts. The calculator name and icon on your phone do not change.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 12),
        const Text(
          'To invite someone, open Chats → Pair new contact. Each conversation has its own pairing code.',
          style: TextStyle(fontSize: 13),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(backgroundColor: chatGreen),
          child: Text(_saving ? 'Saving…' : 'Save profile'),
        ),
      ],
    ),
  );
}
