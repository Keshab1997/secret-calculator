/// Small, local-only reactions for affection messages. No reaction metadata is
/// written to Firebase; each device recognizes the decrypted message text.
enum RomanticMessageEffect { kiss, love }

RomanticMessageEffect? romanticEffectForMessage(String? message) {
  if (message == null) return null;
  final raw = message
      .trim()
      .toLowerCase()
      .replaceAll('\uFE0F', '')
      .replaceAll('’', "'")
      .replaceAll('‘', "'");
  if (raw.isEmpty || raw.startsWith('sticker:v1:')) return null;

  final text = raw
      .replaceAll(RegExp(r'[.,!?;:()\[\]{}"“”।॥—–-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  bool hasPhrase(String phrase) {
    final pattern = RegExp.escape(phrase.toLowerCase());
    return RegExp(r'(^|\s)' + pattern + r'($|\s)').hasMatch(text);
  }

  const negativeKiss = [
    "don't kiss",
    'dont kiss',
    'do not kiss',
    'kiss na',
    'chumu na',
    'চুমু না',
  ];
  const kissPhrases = [
    'kiss',
    'kiss me',
    'mwah',
    'muah',
    'chumu',
    'chumu dao',
    'চুমু',
    'চুমু দাও',
    'চুমু খাও',
    '😘',
    '💋',
  ];
  final hasKiss =
      kissPhrases.any(hasPhrase) || text.contains('😘') || text.contains('💋');
  if (hasKiss && !negativeKiss.any(hasPhrase)) {
    return RomanticMessageEffect.kiss;
  }

  const negativeLove = [
    "don't love",
    'dont love',
    'do not love',
    'never love',
    'love you not',
    'bhalobashi na',
    'bhalobasi na',
    'valobashi na',
    'valobasi na',
    'bhalo bashi na',
    'valo bashi na',
    'ভালোবাসি না',
    'ভালবাসি না',
  ];
  if (negativeLove.any(hasPhrase)) return null;

  const lovePhrases = [
    'i love you',
    'i love u',
    'love you',
    'love u',
    'love ya',
    'i love ya',
    'i luv you',
    'i luv u',
    'i luv ya',
    'luv you',
    'luv u',
    'luv ya',
    'i adore you',
    'adore you',
    'in love with you',
    'ily',
    'ami tomake bhalobashi',
    'ami tomake valobashi',
    'ami tomay bhalobashi',
    'ami tomay valobashi',
    'ami toke bhalobashi',
    'ami toke valobashi',
    'bhalobashi',
    'bhalo bashi',
    'bhalobasi',
    'valobashi',
    'valo bashi',
    'valobasi',
    'ভালোবাসি',
    'ভালবাসি',
    'আমি তোমাকে ভালোবাসি',
    'আমি তোমাকে ভালবাসি',
    'আমি তোমায় ভালোবাসি',
    'আমি তোমায় ভালোবাসি',
    '❤️',
    '❤',
    '💖',
    '💗',
    '💕',
    '💞',
    '💘',
    '💝',
  ];
  if (lovePhrases.any(hasPhrase) ||
      ['❤️', '❤', '💖', '💗', '💕', '💞', '💘', '💝'].any(text.contains)) {
    return RomanticMessageEffect.love;
  }

  return null;
}
