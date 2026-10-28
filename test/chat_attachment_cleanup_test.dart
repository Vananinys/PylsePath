import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/services/chat_attachment_cleanup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String? owner;
  late bool exists, offline;
  late List<List<String>> removed;
  late List<String> local;
  ChatAttachmentCleanup queue() => ChatAttachmentCleanup(
    currentOwner: () => owner,
    messageExists: (uid, id) async => exists,
    removeRemote: (paths) async {
      if (offline) throw StateError('offline');
      removed.add(paths);
    },
    removeLocal: (uid, id, paths) async {
      local.add(id);
    },
  );
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    owner = 'owner';
    exists = false;
    offline = false;
    removed = [];
    local = [];
  });
  test('Existing message prevents deleting even queued objects', () async {
    final q = queue();
    await q.enqueue('owner', 'id', ['owner/chat_video_id.mp4'], []);
    exists = true;
    await q.flush('owner');
    expect(removed, isEmpty);
    expect(local, isEmpty);
    exists = false;
    await q.flush('owner');
    expect(removed.single, ['owner/chat_video_id.mp4']);
    expect(local, ['id']);
  });
  test(
    'Offline deletion survives restart, filters forged paths and is idempotent',
    () async {
      await queue().enqueue('owner', 'id', [
        'owner/chat_video_id.mp4',
        'owner/chat_poster_id.jpg',
        'other/chat_video_id.mp4',
        'owner/chat_video_other.mp4',
        '../owner/chat_video_id.mp4',
      ], []);
      offline = true;
      await queue().flush('owner');
      expect(local, isEmpty);
      offline = false;
      await queue().flush('owner');
      expect(removed.single, [
        'owner/chat_video_id.mp4',
        'owner/chat_poster_id.jpg',
      ]);
      await queue().flush('owner');
      expect(removed, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('chat_attachment_cleanup_v1_owner')!),
        isEmpty,
      );
    },
  );
  test('Account switch keeps old-owner cleanup dormant', () async {
    final q = queue();
    await q.enqueue('owner', 'id', ['owner/chat_voice_id.m4a'], []);
    owner = 'other';
    await q.flush('owner');
    expect(removed, isEmpty);
    owner = 'owner';
    await q.flush('owner');
    expect(removed, hasLength(1));
  });
  test(
    'Switch while checking message blocks remote and local deletion',
    () async {
      final q = ChatAttachmentCleanup(
        currentOwner: () => owner,
        messageExists: (_, id) async {
          owner = 'other';
          return false;
        },
        removeRemote: (p) async {
          removed.add(p);
        },
        removeLocal: (_, id, p) async {
          local.add(id);
        },
      );
      await q.enqueue('owner', 'id', ['owner/chat_photo_id.jpg'], []);
      await q.flush('owner');
      expect(removed, isEmpty);
      expect(local, isEmpty);
    },
  );
}
