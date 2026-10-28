import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/services/recording_daily_activity_service.dart';

class _Platform extends StepRecordingPlatform {
  bool services = true;
  bool permission = true;
  bool recording = false;
  Object? failure;
  Completer<void>? gate;
  final Map<String, int> days = {};
  final List<String> calls = [];
  final bindings = <Map<String, dynamic>>[];
  Map<String, dynamic>? initializedWith;

  @override
  bool get supported => true;
  @override
  Future<bool> requestPermission() async => permission;
  @override
  Future<Map<dynamic, dynamic>> invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    calls.add(method);
    if (method == 'bindOwner') bindings.add(Map.of(arguments!));
    if (method == 'status') {
      return {'available': services, 'permissionGranted': permission};
    }
    if (method == 'initialize') {
      initializedWith = arguments;
      days.addAll(Map<String, int>.from(arguments!['seedDays'] as Map));
      recording = arguments['legacyEnabled'] == true;
    }
    if (gate != null && method == 'refresh') await gate!.future;
    if (failure != null) throw failure!;
    if (method == 'setEnabled') recording = arguments!['enabled'] == true;
    return {
      'enabled': recording,
      'days': Map.of(days),
      'lastSyncedAt': DateTime(2026, 10, 21, 15).millisecondsSinceEpoch,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Platform platform;
  late DailyActivityService service;
  late DateTime now;
  String? owner;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = _Platform();
    now = DateTime(2026, 10, 21, 15);
    owner = 'rider-a';
    service = DailyActivityService.forTesting(
      platform: platform,
      owner: () => owner,
      now: () => now,
    );
  });
  tearDown(() async {
    await service.stop();
  });

  test(
    'migrates legacy totals and goals without modifying the old record',
    () async {
      final legacy = jsonEncode({
        'day': '2026-10-21',
        'steps': 1234,
        'enabled': true,
        'history': {'2026-10-20': 4000},
        'goal': 8000,
        'stride': .8,
      });
      SharedPreferences.setMockInitialValues({
        'daily_steps_v1_rider-a': legacy,
      });
      await service.initialize();
      expect(service.steps, 1234);
      expect(service.history['2026-10-20'], 4000);
      expect(service.goal, 8000);
      expect(service.strideMeters, .8);
      expect(platform.initializedWith!['legacyEnabled'], true);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'daily_steps_v1_rider-a',
        ),
        legacy,
      );
    },
  );

  test('repeated reads replace totals rather than double counting', () async {
    await service.initialize();
    await service.setEnabled(true);
    platform.days['2026-10-21'] = 300;
    await service.refresh();
    await service.refresh();
    expect(service.steps, 300);
    platform.days['2026-10-21'] = 380;
    await service.refresh();
    expect(service.steps, 380);
  });

  test('resume restores steps accumulated while the UI is stopped', () async {
    await service.initialize();
    await service.setEnabled(true);
    await service.stop();
    expect(platform.calls.where((c) => c == 'setEnabled').length, 1);
    expect(platform.recording, true);
    platform.days['2026-10-21'] = 2100;
    await service.initialize();
    // The fake seeds cache like first native launch. A refresh supplies device totals.
    platform.days['2026-10-21'] = 2100;
    await service.refresh();
    expect(service.steps, 2100);
    expect(service.enabled, true);
  });

  test('midnight shows a new day and retains yesterday', () async {
    await service.initialize();
    await service.setEnabled(true);
    platform.days['2026-10-21'] = 5000;
    await service.refresh();
    now = DateTime(2026, 10, 22, 0, 1);
    expect(service.steps, 0);
    expect(service.history['2026-10-21'], 5000);
    platform.days['2026-10-22'] = 42;
    await service.refresh();
    expect(service.steps, 42);
    expect(service.history, {'2026-10-21': 5000});
  });

  test(
    'disable keeps saved history and returns to enabled on request',
    () async {
      await service.initialize();
      await service.setEnabled(true);
      platform.days['2026-10-21'] = 800;
      await service.setEnabled(false);
      expect(service.enabled, false);
      expect(service.steps, 800);
      await service.setEnabled(true);
      expect(service.steps, 800);
    },
  );

  test('permission refusal does not start a subscription', () async {
    await service.initialize();
    platform.permission = false;
    await service.setEnabled(true);
    expect(service.enabled, false);
    expect(platform.calls, isNot(contains('setEnabled')));
    expect(service.notice, contains('не разрешён'));
    expect(service.busy, false);
  });

  test('failed reads keep totals and can be retried', () async {
    await service.initialize();
    platform.days['2026-10-21'] = 700;
    await service.refresh();
    platform.failure = PlatformException(code: 'RECORDING_FAILED');
    await service.refresh();
    expect(service.steps, 700);
    expect(service.notice, isNotNull);
    platform.failure = null;
    platform.days['2026-10-21'] = 900;
    await service.refresh();
    expect(service.steps, 900);
    expect(service.notice, isNull);
  });

  test('late readings from a previous account are discarded', () async {
    await service.initialize();
    platform.gate = Completer<void>();
    platform.days['2026-10-21'] = 600;
    final request = service.refresh();
    await Future<void>.delayed(Duration.zero);
    owner = 'rider-b';
    expect(service.steps, 0);
    expect(service.history, isEmpty);
    platform.gate!.complete();
    await request;
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('daily_steps_recording_v1_rider-b'), isNull);
  });

  test('missing Play Services reports a recoverable state', () async {
    platform.services = false;
    await service.initialize();
    expect(service.available, false);
    expect(service.notice, contains('Google Play'));
    platform.services = true;
    await service.refresh();
    expect(service.available, true);
    expect(service.notice, isNull);
  });

  test(
    'foreign and future legacy data do not migrate to the current owner',
    () async {
      SharedPreferences.setMockInitialValues({
        'daily_steps_v1_rider-b': jsonEncode({
          'day': '2026-10-21',
          'steps': 9000,
        }),
        'daily_steps_v1_rider-a': jsonEncode({
          'day': '2026-10-22',
          'steps': 1000,
        }),
      });
      await service.initialize();
      expect(service.steps, 0);
      expect(platform.initializedWith!['seedDays'], isEmpty);
    },
  );

  test('reads use the native Recording API channel', () async {
    final channelCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(StepRecordingPlatform.channel, (call) async {
          channelCalls.add(call);
          return {
            'enabled': true,
            'days': {'2026-10-21': 73},
          };
        });
    try {
      final snapshot = await StepRecordingPlatform().invoke('refresh', {
        'owner': 'rider-a',
      });
      expect(snapshot['days'], {'2026-10-21': 73});
      expect(channelCalls.single.method, 'refresh');
      expect(channelCalls.single.arguments, {'owner': 'rider-a'});
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(StepRecordingPlatform.channel, null);
    }
  });

  testWidgets('background UI stops polling without stopping system recording', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await service.initialize();
      await service.setEnabled(true);
    });
    service.beginLiveUpdates();
    await tester.pump();
    service.setForeground(false);
    final count = platform.calls.length;
    await tester.pump(const Duration(minutes: 5));
    expect(platform.calls.length, count);
    expect(platform.recording, true);
    service.endLiveUpdates();
  });
  test(
    'Auth binding is immediate, owner-scoped and independent from UI disposal',
    () async {
      await service.initialize();
      expect(platform.bindings.last['owner'], 'rider-a');
      final count = platform.bindings.length;
      await service.stop();
      await service.initialize();
      expect(platform.bindings.length, count);
      platform.gate = Completer<void>();
      final pending = service.refresh();
      await Future<void>.delayed(Duration.zero);
      owner = 'rider-b';
      await service.bindToUser(owner);
      expect(platform.bindings.last['owner'], 'rider-b');
      expect(platform.bindings.last['at'], now.millisecondsSinceEpoch);
      platform.gate!.complete();
      await pending;
      expect(service.steps, 0);
      await service.bindToUser(null);
      expect(platform.bindings.last['owner'], isNull);
    },
  );
}
