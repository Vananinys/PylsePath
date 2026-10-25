import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/progress_backup_repository.dart';

class _Remote extends ProgressBackupRemote {
  Map<String, dynamic> state = {};
  bool offline = false;
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>> exchange(
    String owner,
    Map<String, dynamic> sent,
  ) async {
    if (offline) throw StateError('offline');
    if (gate != null) await gate!.future;
    state = ProgressBackupRepository.merge(state, sent);
    return state;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Remote remote;
  String? owner;
  ProgressBackupRepository repo([String account = 'a']) =>
      ProgressBackupRepository.forTesting(
        owner: account,
        currentOwner: () => owner,
        remote: remote,
      );
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    remote = _Remote();
    owner = 'a';
  });
  test(
    'offline data survives restart and retries without losing receipts',
    () async {
      final first = repo();
      await first.update({
        'days': {'2026-10-22': 1234},
        'unlocked': {
          'builtin:Первый заезд': {'earnedAt': 'first'},
        },
      });
      remote.offline = true;
      await expectLater(first.sync(), throwsStateError);
      expect((await first.read())['pending'], true);
      final restarted = repo();
      expect((await restarted.read())['days']['2026-10-22'], 1234);
      remote.offline = false;
      await restarted.sync();
      expect((await restarted.read())['pending'], false);
      expect(
        remote.state['unlocked']['builtin:Первый заезд']['earnedAt'],
        'first',
      );
    },
  );
  test(
    'fresh install restores cloud and never uploads an empty replacement',
    () async {
      remote.state = {
        'days': {'2026-10-21': 6000},
        'unlocked': {
          'builtin:Первый заезд': {'earnedAt': 'old'},
        },
      };
      await repo().sync();
      final restored = await repo().read();
      expect(restored['days']['2026-10-21'], 6000);
      expect(restored['unlocked'], contains('builtin:Первый заезд'));
      expect(restored['pending'], false);
    },
  );
  test('local writes are not blocked by upload and remain queued after an older acknowledgement', () async {
    final repository = repo();
    await repository.update({
      'days': {'2026-10-22': 100},
    });
    remote.gate = Completer<void>();
    final uploading = repository.sync();
    await Future<void>.delayed(Duration.zero);
    await repository.update({
      'days': {'2026-10-22': 150},
    });
    remote.gate!.complete();
    await uploading;
    final local = await repository.read();
    expect(local['days']['2026-10-22'], 150);
    expect(local['pending'], true);
    remote.gate = null;
    await repository.sync();
    expect(remote.state['days']['2026-10-22'], 150);
    expect((await repository.read())['pending'], false);
  });
  test(
    'account switch during upload never writes into the next account',
    () async {
      final repository = repo();
      await repository.update({
        'days': {'2026-10-22': 100},
      });
      remote.gate = Completer<void>();
      final uploading = repository.sync();
      final rejected = expectLater(uploading, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      owner = 'b';
      remote.gate!.complete();
      await rejected;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('progress_backup_v1_b'), isNull);
      expect(
        jsonDecode(prefs.getString('progress_backup_v1_a')!)['pending'],
        true,
      );
    },
  );
  test('repeated or older readings do not reduce or duplicate steps', () async {
    final repository = repo();
    await repository.update({
      'days': {'2026-10-22': 100},
    });
    await repository.update({
      'days': {'2026-10-22': 100, '2026-10-21': 10},
    });
    await repository.update({
      'days': {'2026-10-22': 50},
    });
    expect((await repository.read())['days'], {
      '2026-10-21': 10,
      '2026-10-22': 100,
    });
  });
  test('first receipt and newest settings survive merging', () {
    final result = ProgressBackupRepository.merge(
      {
        'unlocked': {
          'builtin:first': {'earnedAt': 'old'},
        },
        'preferences': {'goal': 8000, 'updatedAt': 100},
      },
      {
        'unlocked': {
          'builtin:first': {'earnedAt': 'new'},
          'catalog:fake': {},
        },
        'preferences': {'goal': 2000, 'updatedAt': 10},
      },
    );
    expect(result['unlocked']['builtin:first']['earnedAt'], 'old');
    expect(result['unlocked'], isNot(contains('catalog:fake')));
    expect(result['preferences']['goal'], 8000);
  });
  test('damaged local envelope is retained before cloud recovery', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('progress_backup_v1_a', '{damaged');
    remote.state = {
      'days': {'2026-10-22': 700},
    };
    await repo().sync();
    expect((await repo().read())['days']['2026-10-22'], 700);
    final damaged = prefs.getKeys().where(
      (k) => k.startsWith('progress_backup_v1_a_damaged_'),
    );
    expect(damaged, isNotEmpty);
    expect(prefs.getString(damaged.first), '{damaged');
  });
  test(
    'server preferences win migration timestamp tie on a new device',
    () async {
      final repository = repo();
      await repository.update({
        'preferences': {'goal': 6000, 'updatedAt': 0},
      });
      remote.state = {
        'preferences': {'goal': 9000, 'updatedAt': 0},
      };
      await repository.sync();
      expect((await repository.read())['preferences']['goal'], 9000);
    },
  );
}
