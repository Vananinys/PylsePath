import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_scope.dart';

/// One local draft per signed-in account. Queued writes cannot revive a sent draft.
class CommunityDraftStore {
  CommunityDraftStore(this.owner);
  final String owner;
  Future<void> _pending = Future.value();
  String get key => UserScope.keyFor('community_composer_draft_v1', owner);
  Future<Map<String, dynamic>?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (data['version'] != 1) throw const FormatException('Unknown draft');
      return data['cleared'] == true ? null : data;
    } catch (_) {
      // Preserve the original before allowing the editor to create another draft.
      await prefs.setString('${key}_unreadable_backup', raw);
      rethrow;
    }
  }

  Future<void> write(Map<String, dynamic> value) {
    final raw = jsonEncode({'version': 1, ...value});
    final next = _pending.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(key, raw))
        throw StateError('Draft storage failed');
    });
    _pending = next;
    return next;
  }

  Future<void> clear() => write({'cleared': true});
  Future<String> stagePhoto(String source) async {
    final root = await getApplicationSupportDirectory();
    final folder = Directory(
      '${root.path}/community_drafts/${Uri.encodeComponent(owner)}',
    );
    await folder.create(recursive: true);
    final suffix = source.split('.').last.toLowerCase();
    if (!const [
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'heic',
      'heif',
    ].contains(suffix))
      throw const FormatException('Unsupported photo format');
    final random = Random.secure().nextInt(1 << 32).toRadixString(16);
    final path =
        '${folder.path}/${DateTime.now().microsecondsSinceEpoch}-$random.$suffix';
    await File(source).copy(path);
    return path;
  }
}
