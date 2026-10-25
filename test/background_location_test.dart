import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/services/background_location_service.dart';
import 'package:pulsepath/widgets/background_location_settings.dart';

class _Platform extends BackgroundLocationPlatform {
  bool permission = true;
  bool failStart = false;
  final calls = <String>[];
  Map<String, dynamic>? startArguments;
  final state = <String, dynamic>{
    'owner': 'rider-a',
    'enabled': false,
    'running': false,
    'precisePermission': true,
    'backgroundPermission': true,
    'locationEnabled': true,
    'servicesAvailable': true,
    'expiresAt': DateTime.now()
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch,
  };
  @override
  bool get supported => true;
  @override
  Future<bool> requestPermissions() async => permission;
  @override
  Future<Map<dynamic, dynamic>> invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    calls.add(method);
    if (method == 'start') {
      if (failStart) throw PlatformException(code: 'BACKGROUND_LOCATION');
      startArguments = arguments;
      state.addAll({
        'owner': arguments!['owner'],
        'enabled': true,
        'running': true,
      });
    } else if (method == 'stop' &&
        (arguments?['owner'] == null ||
            arguments!['owner'] == state['owner'])) {
      state.addAll({'enabled': false, 'running': false});
    }
    return Map.of(state);
  }
}

class _Repository extends BackgroundLocationRepository {
  int issued = 0;
  int revoked = 0;
  Completer<void>? gate;
  Object? failure;
  @override
  Future<Map<String, dynamic>> issue(String deviceId) async {
    if (failure != null) throw failure!;
    issued++;
    if (gate != null) await gate!.future;
    return {
      'token': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' * 2,
      'expires_at': DateTime.now()
          .add(const Duration(days: 30))
          .toIso8601String(),
    };
  }

  @override
  Future<void> revoke(String token) async {
    revoked++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Platform platform;
  late _Repository repository;
  late BackgroundLocationService service;
  String? owner;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = _Platform();
    repository = _Repository();
    owner = 'rider-a';
    service = BackgroundLocationService.forTesting(
      platform: platform,
      repository: repository,
      owner: () => owner,
    );
  });
  tearDown(() {
    service.dispose();
  });

  test('background sharing stays off until the user enables it', () async {
    await service.restore(shareAllowed: true);
    expect(service.enabled, false);
    expect(repository.issued, 0);
    expect(platform.calls, isNot(contains('start')));
  });
  test('permission denial cannot start location collection', () async {
    platform.permission = false;
    await service.setEnabled(true);
    expect(service.enabled, false);
    expect(repository.issued, 0);
    expect(service.notice, contains('Всегда'));
  });
  test(
    'enabling passes a scoped capability without account session tokens',
    () async {
      await service.setEnabled(true);
      expect(service.enabled, true);
      expect(service.running, true);
      expect(repository.issued, 1);
      expect(platform.startArguments!['owner'], 'rider-a');
      expect(platform.startArguments!['token'], hasLength(72));
      expect(platform.startArguments!.keys, isNot(contains('refreshToken')));
      expect(platform.startArguments!.keys, isNot(contains('accessToken')));
    },
  );
  test(
    'restoring an existing native subscription does not rotate its credential',
    () async {
      platform.state.addAll({'enabled': true, 'running': true});
      await service.restore(shareAllowed: true);
      expect(service.enabled, true);
      expect(repository.issued, 0);
      expect(platform.startArguments, {'owner': 'rider-a'});
    },
  );
  test('nearly expired credentials renew when the app opens', () async {
    platform.state.addAll({
      'enabled': true,
      'running': true,
      'expiresAt': DateTime.now()
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch,
    });
    await service.restore(shareAllowed: true);
    expect(repository.issued, 1);
    expect(service.running, true);
  });
  test('global privacy switch stops native collection', () async {
    await service.setEnabled(true);
    service.setSharingAllowed(false);
    await service.refreshStatus();
    expect(service.enabled, false);
    expect(platform.calls, contains('stop'));
  });
  test(
    'logout stops the old native owner without needing an account JWT',
    () async {
      platform.state.addAll({'enabled': true, 'running': true});
      owner = null;
      await service.bindToUser(null);
      expect(platform.state['enabled'], false);
      expect(platform.calls, contains('stop'));
      expect(repository.issued, 0);
    },
  );
  test(
    'identity changes during activation revoke the unused credential',
    () async {
      repository.gate = Completer<void>();
      final operation = service.setEnabled(true);
      while (repository.issued == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      owner = 'rider-b';
      repository.gate!.complete();
      await operation;
      expect(platform.calls, isNot(contains('start')));
      expect(repository.revoked, 1);
    },
  );
  test(
    'stopping through the system notification is reflected in settings',
    () async {
      await service.setEnabled(true);
      platform.state.addAll({'enabled': false, 'running': false});
      await service.refreshStatus();
      expect(service.enabled, false);
      await service.restore(shareAllowed: true);
      expect(repository.issued, 1);
      expect(service.enabled, false);
    },
  );
  test(
    'revoked background permission does not trigger a hidden restart',
    () async {
      platform.state.addAll({
        'enabled': true,
        'running': false,
        'backgroundPermission': false,
      });
      await service.restore(shareAllowed: true);
      expect(platform.calls, isNot(contains('start')));
      expect(service.notice?.toLowerCase(), contains('всегда'));
    },
  );
  test('failed native startup revokes the newly issued credential', () async {
    platform.failStart = true;
    await service.setEnabled(true);
    expect(service.enabled, false);
    expect(service.busy, false);
    expect(repository.revoked, 1);
    expect(service.notice, isNotNull);
  });
  test('server activation pending is explained without starting GPS', () async {
    repository.failure = const BackgroundLocationSetupException();
    await service.setEnabled(true);
    expect(service.enabled, false);
    expect(platform.calls, isNot(contains('start')));
    expect(service.notice, contains('обновления сервера'));
  });

  testWidgets('settings fit a narrow screen and explain required access', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    service.notice = 'Разрешите геопозицию «Всегда» в настройках телефона.';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BackgroundLocationSettings(
              shareAllowed: true,
              service: service,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Местоположение при закрытом приложении'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
