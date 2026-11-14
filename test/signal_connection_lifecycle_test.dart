import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pulsepath/data/signal_state_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test(
    'closing a sibling connection cannot close an active Signal handle',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp(
        'signal-connection-qa-',
      );
      Future<SignalStateDatabase> open() => SignalStateDatabase.open(
        path: '${dir.path}/state.db',
        owner: 'qa',
        currentOwner: () => 'qa',
      );
      final foreground = await open();
      await foreground.enrollNewDevice();
      final background = await open();
      await background.close();
      expect(await foreground.run((_, s) async => s['device']), isA<int>());
      await foreground.close();
    },
  );
  test('close rolls back an in-flight operation and is idempotent', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('signal-close-qa-');
    Future<SignalStateDatabase> open() => SignalStateDatabase.open(
      path: '${dir.path}/state.db',
      owner: 'qa',
      currentOwner: () => 'qa',
    );
    final db = await open();
    await db.enrollNewDevice();
    final entered = Completer<void>(), finish = Completer<void>();
    final operation = db.run((_, s) async {
      s['uncommitted'] = true;
      entered.complete();
      await finish.future;
    });
    final rejected = expectLater(operation, throwsStateError);
    await entered.future;
    final closed = db.close();
    expect(identical(closed, db.close()), isTrue);
    finish.complete();
    await rejected;
    await closed;
    final reopened = await open();
    expect(await reopened.run((_, s) async => s['uncommitted']), isNull);
    await reopened.close();
  });
}
