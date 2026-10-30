import 'package:shared_preferences/shared_preferences.dart';

import 'user_scope.dart';

class RecentStickers {
  Future<void> _tail = Future.value();
  Future<List<String>> load(String? owner) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.get(UserScope.keyFor('recent_map_stickers_v1', owner));
    return value is List<String> ? value.take(32).toSet().toList() : [];
  }

  Future<void> used(String sticker, String? owner) {
    final result = _tail.then((_) async {
      final recent = await load(owner);
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setStringList(
        UserScope.keyFor('recent_map_stickers_v1', owner),
        [sticker, ...recent.where((s) => s != sticker)].take(32).toList(),
      )) {
        throw StateError('Не удалось сохранить порядок стикеров');
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static List<String> order(List<String> catalog, List<String> recent) => [
    ...recent.where(catalog.contains),
    ...catalog.where((s) => !recent.contains(s)),
  ].toSet().toList();
}
