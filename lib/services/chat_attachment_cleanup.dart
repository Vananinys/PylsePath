import 'package:flutter/foundation.dart';

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Durable deletion intents. A message that still exists always keeps its files.
class ChatAttachmentCleanup {
  ChatAttachmentCleanup({
    required this.currentOwner,
    required this.messageExists,
    required this.removeRemote,
    required this.removeLocal,
  });

  final String? Function() currentOwner;
  final Future<bool> Function(String owner, String id) messageExists;
  final Future<void> Function(List<String> paths) removeRemote;
  final Future<void> Function(String owner, String id, List<String> paths)
  removeLocal;
  Future<void> _tail = Future.value();

  Future<void> _run(Future<void> Function() action) {
    final next = _tail.catchError((Object _) {}).then((_) => action());
    _tail = next;
    return next;
  }

  static bool safeId(String value) =>
      RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(value);

  static bool ownsPath(String owner, String id, String path) =>
      safeId(owner) &&
      safeId(id) &&
      RegExp(
        '^${RegExp.escape(owner)}/chat_(photo|video|poster|voice)_${RegExp.escape(id)}\\.[a-z0-9]+\$',
      ).hasMatch(path);

  List<Map<String, dynamic>> _read(SharedPreferences prefs, String key) {
    final value = prefs.getString(key);
    if (value == null) return [];
    // Preserve a corrupt queue rather than silently replacing its deletion intents.
    return (jsonDecode(value) as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  Future<void> enqueue(
    String owner,
    String id,
    List<String> remote,
    List<String> local,
  ) => _run(() async {
    if (!safeId(owner) || !safeId(id) || currentOwner() != owner) {
      throw StateError('Account changed');
    }
    final prefs = await SharedPreferences.getInstance();
    if (currentOwner() != owner) throw StateError('Account changed');
    final key = 'chat_attachment_cleanup_v1_$owner';
    final jobs = _read(prefs, key);
    final previous = jobs.where((job) => job['id'] == id).firstOrNull;
    final paths = {
      ...?((previous?['remote'] as List?)?.cast<String>()),
      ...remote.where((p) => ownsPath(owner, id, p)),
    };
    final localPaths = {
      ...?((previous?['local'] as List?)?.cast<String>()),
      ...local,
    };
    jobs.removeWhere((job) => job['id'] == id);
    jobs.add({
      'id': id,
      'remote': paths.toList(),
      'local': localPaths.toList(),
    });
    if (!await prefs.setString(key, jsonEncode(jobs))) {
      throw StateError('Cannot save cleanup queue');
    }
  });

  Future<void> flush(String owner) => _run(() async {
    if (currentOwner() != owner) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'chat_attachment_cleanup_v1_$owner';
    final jobs = _read(prefs, key);
    for (final job in List<Map<String, dynamic>>.from(jobs)) {
      if (currentOwner() != owner) return;
      final id = job['id'] as String;
      if (!safeId(id)) continue;
      try {
        if (await messageExists(owner, id) || currentOwner() != owner) continue;
        final paths = (job['remote'] as List)
            .cast<String>()
            .where((p) => ownsPath(owner, id, p))
            .toList();
        if (paths.isNotEmpty) await removeRemote(paths);
        if (currentOwner() != owner) return;
        await removeLocal(owner, id, (job['local'] as List).cast<String>());
        if (currentOwner() != owner) return;
        jobs.remove(job);
        if (!await prefs.setString(key, jsonEncode(jobs))) {
          throw StateError('Cannot save cleanup result');
        }
      } catch (error) {
        debugPrint('[ChatCleanup] retry deferred: ${error.runtimeType}');
        // Retain the intent for the next foreground retry. Never undo message deletion.
      }
    }
  });
}
