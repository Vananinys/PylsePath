// Account-switch behaviour of repositories that hold an owner captured at
// construction time. Futures are controlled explicitly; no timing sleeps.
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/data/progress_backup_repository.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../deepseek_integrity/network_guard.dart';
import 'qa_support.dart';

class _Remote extends ProgressBackupRemote {
  @override
  Future<Map<String, dynamic>> exchange(
    String owner,
    Map<String, dynamic> state,
  ) async => state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NetworkGuard.install);
  tearDownAll(NetworkGuard.restore);

  late QaPreferencesStore platform;
  late SharedPreferencesStorePlatform previousPlatform;

  setUp(() {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    platform = QaPreferencesStore();
    SharedPreferencesStorePlatform.instance = platform;
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = previousPlatform;
    SharedPreferences.resetStatic();
  });

  test(
    'an old chat instance must not report success after the account changes',
    () async {
      const ownerA = 'account-a';
      const ownerB = 'account-b';
      const friend = 'friend-1';
      String? current = ownerA;
      final store = ChatLocalStore(ownerA, friend, currentOwner: () => current);

      current = ownerB;
      var threw = false;
      try {
        await store.saveMessages([
          ChatMessage(
            id: 'pending-A',
            senderId: ownerA,
            receiverId: friend,
            body: 'не отправлено',
            createdAt: DateTime.utc(2026, 10, 28, 10),
            delivery: MessageDelivery.sending,
          ),
        ]);
      } catch (_) {
        threw = true;
      }

      final all = await platform.getAll();
      expect(
        all['flutter.chat_v1_${friend}_$ownerB'],
        isNull,
        reason: 'account B storage must stay untouched',
      );
      expect(
        threw ||
            (all['flutter.chat_v1_${friend}_$ownerA'] as String?)?.contains(
                  'pending-A',
                ) ==
                true,
        isTrue,
        reason:
            'saveMessages completed successfully after the switch but did '
            'not preserve account A\'s pending message anywhere',
      );
    },
  );

  test(
    'an old progress-backup instance cannot write after another login',
    () async {
      String? current = 'account-a';
      final repository = ProgressBackupRepository.forTesting(
        owner: 'account-a',
        currentOwner: () => current,
        remote: _Remote(),
      );
      await repository.update({
        'days': {'2026-10-22': 100},
      });
      final before = (await platform
          .getAll())['flutter.progress_backup_v1_account-a'];

      current = 'account-b';
      await expectLater(
        repository.update({
          'days': {'2026-10-23': 5},
        }),
        throwsStateError,
      );

      final all = await platform.getAll();
      expect(all['flutter.progress_backup_v1_account-b'], isNull);
      expect(all['flutter.progress_backup_v1_account-a'], before);
    },
  );
}
