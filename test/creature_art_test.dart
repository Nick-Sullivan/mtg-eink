import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_eink/models/creature_art.dart';
import 'package:mtg_eink/models/token_content.dart';

void main() {
  test('ids are unique', () {
    final ids = CreatureArt.all.map((a) => a.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('every silhouette parses to something picture-sized', () {
    for (final art in CreatureArt.all) {
      final bounds = art.path.getBounds();
      expect(bounds.isEmpty, isFalse, reason: art.id);
      // Big enough to be the picture, not a stray fragment of the icon. Bounds include control
      // points, so they can overshoot the 512 viewBox a little; the painter fits and clips to them.
      expect(bounds.longestSide, greaterThan(200), reason: art.id);
      expect(
        bounds.longestSide,
        lessThan(CreatureArt.viewBox * 1.2),
        reason: art.id,
      );
    }
  });

  test('an unknown or missing id is no art, not a crash', () {
    expect(CreatureArt.byId(null), isNull);
    expect(CreatureArt.byId('mind-flayer'), isNull);
    expect(CreatureArt.byId('goblin')?.label, 'Goblin');
  });

  test('the credit names every artist whose icons are used', () {
    const names = {
      'lorc': 'Lorc',
      'delapouite': 'Delapouite',
      'skoll': 'Skoll',
      'caro-asercion': 'Caro Asercion',
      'cathelineau': 'Cathelineau',
    };
    for (final art in CreatureArt.all) {
      final artist = art.source.split('/').first;
      expect(names, contains(artist), reason: 'no credit name for $artist');
      expect(creatureArtCredit, contains(names[artist]));
    }
  });

  group('on a token', () {
    test('art round-trips through JSON', () {
      const token = TokenContent(art: 'zombie');
      expect(TokenContent.fromJson(token.toJson()).art, 'zombie');
    });

    test('tokens saved before art existed load with none', () {
      expect(TokenContent.fromJson(const {'name': 'Gobby'}).art, isNull);
    });

    test('copyWith can set, keep and clear art', () {
      const token = TokenContent(art: 'wolf');
      expect(token.copyWith(name: 'Big Wolf').art, 'wolf');
      expect(token.copyWith(art: () => 'cat').art, 'cat');
      expect(token.copyWith(art: () => null).art, isNull);
    });
  });
}
