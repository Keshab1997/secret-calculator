// Sticker categories with searchable tags
class Sticker {
  final String id;
  final String emoji;
  final String name;
  final List<String> tags;

  const Sticker({
    required this.id,
    required this.emoji,
    required this.name,
    required this.tags,
  });
}

class StickerCategory {
  final String id;
  final String name;
  final String icon;
  final List<Sticker> stickers;

  const StickerCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.stickers,
  });
}

// Searchable sticker packs
final List<StickerCategory> stickerCategories = [
  StickerCategory(
    id: 'love',
    name: 'Love & Hearts',
    icon: '❤️',
    stickers: const [
      Sticker(
        id: 'heart',
        emoji: '❤️',
        name: 'Red Heart',
        tags: ['heart', 'love', 'red', 'valentine'],
      ),
      Sticker(
        id: 'sparkling_heart',
        emoji: '💖',
        name: 'Sparkling Heart',
        tags: ['heart', 'sparkle', 'love', 'pink'],
      ),
      Sticker(
        id: 'heart_eyes',
        emoji: '😍',
        name: 'Heart Eyes',
        tags: ['love', 'eyes', 'heart', 'face'],
      ),
      Sticker(
        id: 'kiss',
        emoji: '💋',
        name: 'Kiss Mark',
        tags: ['kiss', 'love', 'lips', 'romance'],
      ),
      Sticker(
        id: 'two_hearts',
        emoji: '💕',
        name: 'Two Hearts',
        tags: ['hearts', 'love', 'couple', 'pink'],
      ),
      Sticker(
        id: 'gift_heart',
        emoji: '💝',
        name: 'Gift Heart',
        tags: ['gift', 'heart', 'present', 'love'],
      ),
      Sticker(
        id: 'revolving_hearts',
        emoji: '💞',
        name: 'Revolving Hearts',
        tags: ['hearts', 'love', 'revolving', 'romance'],
      ),
      Sticker(
        id: 'heart_arrow',
        emoji: '💘',
        name: 'Heart Arrow',
        tags: ['heart', 'arrow', 'love', 'cupid'],
      ),
      Sticker(
        id: 'cupid',
        emoji: '💘',
        name: 'Cupid',
        tags: ['cupid', 'arrow', 'heart', 'love'],
      ),
      Sticker(
        id: 'love_letter',
        emoji: '💌',
        name: 'Love Letter',
        tags: ['letter', 'love', 'envelope', 'mail'],
      ),
    ],
  ),
  StickerCategory(
    id: 'fun',
    name: 'Fun & Party',
    icon: '🎉',
    stickers: const [
      Sticker(
        id: 'party',
        emoji: '🎉',
        name: 'Party Popper',
        tags: ['party', 'celebration', 'popper', 'fun'],
      ),
      Sticker(
        id: 'fire',
        emoji: '🔥',
        name: 'Fire',
        tags: ['fire', 'hot', 'lit', 'awesome'],
      ),
      Sticker(
        id: 'rocket',
        emoji: '🚀',
        name: 'Rocket',
        tags: ['rocket', 'launch', 'space', 'fast'],
      ),
      Sticker(
        id: 'star',
        emoji: '⭐',
        name: 'Star',
        tags: ['star', 'favorite', 'rating', 'best'],
      ),
      Sticker(
        id: 'sparkles',
        emoji: '✨',
        name: 'Sparkles',
        tags: ['sparkles', 'magic', 'shine', 'glitter'],
      ),
      Sticker(
        id: 'confetti',
        emoji: '🎊',
        name: 'Confetti',
        tags: ['confetti', 'party', 'celebration', 'fun'],
      ),
      Sticker(
        id: 'balloon',
        emoji: '🎈',
        name: 'Balloon',
        tags: ['balloon', 'party', 'celebration', 'birthday'],
      ),
      Sticker(
        id: 'clown',
        emoji: '🤡',
        name: 'Clown Face',
        tags: ['clown', 'funny', 'joke', 'laugh'],
      ),
      Sticker(
        id: 'laughing',
        emoji: '😂',
        name: 'Joy',
        tags: ['laugh', 'joy', 'funny', 'haha'],
      ),
      Sticker(
        id: 'dancer',
        emoji: '💃',
        name: 'Dancer',
        tags: ['dancer', 'dance', 'party', 'fun'],
      ),
    ],
  ),
  StickerCategory(
    id: 'cute',
    name: 'Cute & Animals',
    icon: '🐶',
    stickers: const [
      Sticker(
        id: 'dog',
        emoji: '🐶',
        name: 'Dog Face',
        tags: ['dog', 'pet', 'animal', 'cute'],
      ),
      Sticker(
        id: 'cat',
        emoji: '🐱',
        name: 'Cat Face',
        tags: ['cat', 'pet', 'animal', 'cute'],
      ),
      Sticker(
        id: 'panda',
        emoji: '🐼',
        name: 'Panda',
        tags: ['panda', 'bear', 'cute', 'animal'],
      ),
      Sticker(
        id: 'rabbit',
        emoji: '🐰',
        name: 'Rabbit',
        tags: ['rabbit', 'bunny', 'cute', 'animal'],
      ),
      Sticker(
        id: 'fox',
        emoji: '🦊',
        name: 'Fox',
        tags: ['fox', 'animal', 'cute', 'clever'],
      ),
      Sticker(
        id: 'bear',
        emoji: '🐻',
        name: 'Bear',
        tags: ['bear', 'animal', 'cute', 'strong'],
      ),
      Sticker(
        id: 'koala',
        emoji: '🐨',
        name: 'Koala',
        tags: ['koala', 'bear', 'cute', 'sleep'],
      ),
      Sticker(
        id: 'penguin',
        emoji: '🐧',
        name: 'Penguin',
        tags: ['penguin', 'bird', 'cute', 'cold'],
      ),
      Sticker(
        id: 'unicorn',
        emoji: '🦄',
        name: 'Unicorn',
        tags: ['unicorn', 'magic', 'cute', 'fantasy'],
      ),
      Sticker(
        id: 'dragon',
        emoji: '🐉',
        name: 'Dragon',
        tags: ['dragon', 'myth', 'power', 'fantasy'],
      ),
    ],
  ),
  StickerCategory(
    id: 'food',
    name: 'Food & Drinks',
    icon: '🍕',
    stickers: const [
      Sticker(
        id: 'pizza',
        emoji: '🍕',
        name: 'Pizza',
        tags: ['pizza', 'food', 'cheese', 'delicious'],
      ),
      Sticker(
        id: 'burger',
        emoji: '🍔',
        name: 'Burger',
        tags: ['burger', 'food', 'fast', 'delicious'],
      ),
      Sticker(
        id: 'taco',
        emoji: '🌮',
        name: 'Taco',
        tags: ['taco', 'food', 'mexican', 'delicious'],
      ),
      Sticker(
        id: 'ice_cream',
        emoji: '🍦',
        name: 'Ice Cream',
        tags: ['ice cream', 'dessert', 'sweet', 'cold'],
      ),
      Sticker(
        id: 'cake',
        emoji: '🎂',
        name: 'Birthday Cake',
        tags: ['cake', 'birthday', 'celebration', 'sweet'],
      ),
      Sticker(
        id: 'coffee',
        emoji: '☕',
        name: 'Coffee',
        tags: ['coffee', 'drink', 'morning', 'energy'],
      ),
      Sticker(
        id: 'beer',
        emoji: '🍺',
        name: 'Beer Mug',
        tags: ['beer', 'drink', 'party', 'alcohol'],
      ),
      Sticker(
        id: 'wine',
        emoji: '🍷',
        name: 'Wine Glass',
        tags: ['wine', 'drink', 'celebration', 'alcohol'],
      ),
      Sticker(
        id: 'champagne',
        emoji: '🥂',
        name: 'Champagne',
        tags: ['champagne', 'celebration', 'toast', 'party'],
      ),
      Sticker(
        id: 'popcorn',
        emoji: '🍿',
        name: 'Popcorn',
        tags: ['popcorn', 'movie', 'snack', 'cinema'],
      ),
    ],
  ),
  StickerCategory(
    id: 'gestures',
    name: 'Gestures & Hands',
    icon: '👍',
    stickers: const [
      Sticker(
        id: 'thumbs_up',
        emoji: '👍',
        name: 'Thumbs Up',
        tags: ['thumbs up', 'like', 'good', 'yes'],
      ),
      Sticker(
        id: 'thumbs_down',
        emoji: '👎',
        name: 'Thumbs Down',
        tags: ['thumbs down', 'dislike', 'no', 'bad'],
      ),
      Sticker(
        id: 'clap',
        emoji: '👏',
        name: 'Clapping Hands',
        tags: ['clap', 'applause', 'congratulations', 'good'],
      ),
      Sticker(
        id: 'pray',
        emoji: '🙏',
        name: 'Folded Hands',
        tags: ['pray', 'please', 'thank you', 'respect'],
      ),
      Sticker(
        id: 'wave',
        emoji: '👋',
        name: 'Waving Hand',
        tags: ['wave', 'hello', 'hi', 'greeting'],
      ),
      Sticker(
        id: 'ok',
        emoji: '👌',
        name: 'OK Hand',
        tags: ['ok', 'perfect', 'good', 'approve'],
      ),
      Sticker(
        id: 'pinch',
        emoji: '🤏',
        name: 'Pinching Hand',
        tags: ['pinch', 'small', 'tiny', 'hand'],
      ),
      Sticker(
        id: 'love_you',
        emoji: '🤟',
        name: 'Love You Gesture',
        tags: ['love you', 'ILY', 'heart', 'hands'],
      ),
      Sticker(
        id: 'call_me',
        emoji: '🤙',
        name: 'Call Me Hand',
        tags: ['call me', 'phone', 'hand', 'gesture'],
      ),
      Sticker(
        id: 'crossed_fingers',
        emoji: '🤞',
        name: 'Crossed Fingers',
        tags: ['luck', 'hope', 'wish', 'fingers'],
      ),
    ],
  ),
  StickerCategory(
    id: 'expressions',
    name: 'Expressions',
    icon: '😊',
    stickers: const [
      Sticker(
        id: 'smile',
        emoji: '😊',
        name: 'Smiling Face',
        tags: ['smile', 'happy', 'joy', 'positive'],
      ),
      Sticker(
        id: 'sad',
        emoji: '😢',
        name: 'Crying Face',
        tags: ['sad', 'cry', 'tears', 'emotional'],
      ),
      Sticker(
        id: 'angry',
        emoji: '😠',
        name: 'Angry Face',
        tags: ['angry', 'mad', 'annoyed', 'emotion'],
      ),
      Sticker(
        id: 'surprised',
        emoji: '😲',
        name: 'Astonished Face',
        tags: ['surprise', 'shock', 'amazed', 'wow'],
      ),
      Sticker(
        id: 'cool',
        emoji: '😎',
        name: 'Smiling Face with Sunglasses',
        tags: ['cool', 'sunglasses', 'style', 'confident'],
      ),
      Sticker(
        id: 'wink',
        emoji: '😉',
        name: 'Winking Face',
        tags: ['wink', 'flirt', 'playful', 'fun'],
      ),
      Sticker(
        id: 'tongue',
        emoji: '😛',
        name: 'Face with Tongue',
        tags: ['tongue', 'silly', 'playful', 'funny'],
      ),
      Sticker(
        id: 'nerd',
        emoji: '🤓',
        name: 'Nerd Face',
        tags: ['nerd', 'geek', 'smart', 'glasses'],
      ),
      Sticker(
        id: 'sleepy',
        emoji: '😴',
        name: 'Sleeping Face',
        tags: ['sleep', 'tired', 'zzz', 'rest'],
      ),
      Sticker(
        id: 'shy',
        emoji: '😳',
        name: 'Flushed Face',
        tags: ['shy', 'embarrassed', 'flushed', 'blush'],
      ),
    ],
  ),
];

// Search stickers by name or tags
List<Sticker> searchStickers(String query) {
  if (query.isEmpty) return [];

  final lowerQuery = query.toLowerCase();
  final results = <Sticker>[];

  for (final category in stickerCategories) {
    for (final sticker in category.stickers) {
      if (sticker.name.toLowerCase().contains(lowerQuery) ||
          sticker.tags.any((tag) => tag.contains(lowerQuery))) {
        results.add(sticker);
      }
    }
  }

  return results;
}

// Get all stickers for display
List<StickerCategory> getAllStickerCategories() {
  return stickerCategories;
}
