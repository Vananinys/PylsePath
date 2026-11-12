import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pulsepath/data/signal_state_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory directory;
  late String path;
  String? owner = 'alice';
  Future<SignalStateDatabase> open() => SignalStateDatabase.open(
    path: path,
    owner: 'alice',
    currentOwner: () => owner,
  );
  setUp(() async {
    owner = 'alice';
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'pulsepath-signal-state-',
    );
    path = '${directory.path}/state.db';
  });
  // Leave only synthetic fixtures in the OS temp directory; never touch app data.
  test(
    'encrypted state survives reopening and failed operations roll back',
    () async {
      var db = await open();
      await db.enrollNewDevice();
      await db.run((_, state) async {
        state['pending'] = 'synthetic secret';
      });
      await expectLater(
        db.run((_, state) async {
          state['pending'] = 'must roll back';
          throw StateError('simulated failure');
        }),
        throwsStateError,
      );
      await db.close();
      db = await open();
      expect(
        await db.run((_, state) async => state['pending']),
        'synthetic secret',
      );
      await db.close();
      final bytes = await File(path).readAsBytes();
      expect(String.fromCharCodes(bytes), isNot(contains('synthetic secret')));
    },
  );
  test(
    'concurrent operations serialize and callbacks cannot escape a transaction',
    () async {
      final db = await open();
      await db.enrollNewDevice();
      dynamic escaped;
      await Future.wait(
        List.generate(
          12,
          (_) => db.run((stores, state) async {
            escaped = stores;
            final n = state['count'] as int? ?? 0;
            await Future<void>.delayed(const Duration(milliseconds: 2));
            state['count'] = n + 1;
          }),
        ),
      );
      expect(await db.run((_, state) async => state['count']), 12);
      await expectLater(
        escaped.getLocalRegistrationId() as Future<int>,
        throwsStateError,
      );
      await db.close();
    },
  );
  test('account switch rolls back writes and a missing master never resets identity', () async {
    var db = await open();
    await db.enrollNewDevice();
    await expectLater(
      db.run((_, state) async {
        state['wrong'] = true;
        owner = 'bob';
      }),
      throwsStateError,
    );
    owner = 'alice';
    expect(await db.run((_, state) async => state['wrong']), isNull);
    await db.close();
    FlutterSecureStorage.setMockInitialValues({});
    db = await open();
    await expectLater(db.run((_, state) async => state), throwsStateError);
    await expectLater(db.enrollNewDevice(), throwsStateError);
    await db.close();
  });
}
