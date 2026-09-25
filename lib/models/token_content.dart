import 'package:flutter/foundation.dart';

/// A Magic: The Gathering token to lay out on the card template.
///
/// Power and toughness are kept as strings even though the editor only takes digits: they're only
/// ever displayed, and it leaves room for `*` or `X` later without a change to the saved format.
@immutable
class TokenContent {
  const TokenContent({
    this.name = 'Gobby',
    this.type = 'Creature — Goblin',
    this.power = '1',
    this.toughness = '1',
    this.ability = '',
    this.art,
  });

  final String name;

  /// Drawn exactly as typed — no "Token" prefix is added.
  final String type;

  final String power;
  final String toughness;

  /// Rules text, e.g. "Flying, haste". May run to several lines; empty means no text box at all.
  final String ability;

  /// A [CreatureArt] id for the art box, or null for the plain hatch.
  ///
  /// Stored as an id rather than the art itself, so saved tokens pick up any redrawn art.
  final String? art;

  TokenContent copyWith({
    String? name,
    String? type,
    String? power,
    String? toughness,
    String? ability,
    // A getter, so art can be cleared back to null — a plain `String?` can't tell "clear" from
    // "leave alone".
    ValueGetter<String?>? art,
  }) {
    return TokenContent(
      name: name ?? this.name,
      type: type ?? this.type,
      power: power ?? this.power,
      toughness: toughness ?? this.toughness,
      ability: ability ?? this.ability,
      art: art == null ? this.art : art(),
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    'power': power,
    'toughness': toughness,
    'ability': ability,
    if (art != null) 'art': art,
  };

  factory TokenContent.fromJson(Map<String, Object?> json) => TokenContent(
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? '',
    power: json['power'] as String? ?? '',
    toughness: json['toughness'] as String? ?? '',
    // Tokens saved before ability text existed have none.
    ability: json['ability'] as String? ?? '',
    art: json['art'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is TokenContent &&
      other.name == name &&
      other.type == type &&
      other.power == power &&
      other.toughness == toughness &&
      other.ability == ability &&
      other.art == art;

  @override
  int get hashCode => Object.hash(name, type, power, toughness, ability, art);
}
