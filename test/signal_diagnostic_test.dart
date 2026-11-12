import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pulsepath/services/signal_diagnostic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  test(
    'diagnostic completes repeatedly using persistent synthetic identities',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp(
        'pulsepath-signal-diagnostic-',
      );
      await databaseFactory.setDatabasesPath(dir.path);
      expect(await runSignalDiagnostic(), hasLength(6));
      expect(await runSignalDiagnostic(), hasLength(6));
    },
  );
}
