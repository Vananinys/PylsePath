/// Stable server identifiers; labels can change independently.
enum CommunityPostTopic {
  travel('Путешествия'),
  memes('Мемы'),
  routes('Интересные маршруты'),
  cycling('Велопоездки'),
  running('Пробежки'),
  other('Другое');

  const CommunityPostTopic(this.label);
  final String label;
  String get id => name;
  static List<String> normalize(Iterable<String> ids) => values
      .where((topic) => ids.contains(topic.id))
      .map((topic) => topic.id)
      .toList(growable: false);
}
