import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:pulsepath/services/usage_statistics.dart';

class RejectUsageWrites extends InMemorySharedPreferencesStore {
  RejectUsageWrites() : super.empty();
  @override
  Future<bool> setValue(String type, String key, Object value) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String? owner;
  late DateTime now;
  late UsageStatistics service;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    owner = 'test-owner-email@example.test';
    now = DateTime(2026, 10, 28);
    service = UsageStatistics(ownerResolver: () => owner, clock: () => now)
      ..version = '1.12.16+69';
  });
  test('default is off and previous activity is never collected', () async {
    service.record(UsageEvent.workoutStarted);
    expect((await service.snapshot())['enabled'], false);
    expect((await service.snapshot())['counts'], isEmpty);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });
  test(
    'consent produces counters with no account or coordinate fields',
    () async {
      await service.setEnabled(true);
      service.record(UsageEvent.routeBuilt);
      service.record(UsageEvent.routeBuilt);
      final report = await service.exportReport();
      final data = jsonDecode(report) as Map;
      expect(data['automatic_upload'], false);
      expect(data['counters'], [
        {
          'day': '2026-10-28',
          'version': '1.12.16+69',
          'event': 'routeBuilt',
          'count': 2,
        },
      ]);
      expect(report.contains(owner!), false);
      for (final field in [
        'latitude',
        'longitude',
        'user_id',
        'email',
        'track',
        'message',
      ]) {
        expect(report.contains('"$field"'), false);
      }
    },
  );
  test('withdrawal stops pending and future collection', () async {
    await service.setEnabled(true);
    service.record(UsageEvent.workoutStarted);
    final disabling = service.setEnabled(false);
    service.record(UsageEvent.workoutSaved);
    await disabling;
    expect((await service.snapshot())['counts'], isEmpty);
    expect((await service.snapshot())['enabled'], false);
  });
  test('accounts never inherit counts or consent', () async {
    await service.setEnabled(true);
    service.record(UsageEvent.workoutSaved);
    await service.snapshot();
    owner = 'other-account';
    expect((await service.snapshot())['enabled'], false);
    expect((await service.snapshot())['counts'], isEmpty);
    service.record(UsageEvent.routeBuilt);
    expect((await service.snapshot())['counts'], isEmpty);
    owner = 'test-owner-email@example.test';
    expect((await service.snapshot())['counts'], hasLength(1));
  });
  test(
    'account switch before consent storage cannot enable the next account',
    () async {
      final saving = service.setEnabled(true);
      owner = 'next';
      await expectLater(saving, throwsStateError);
      expect((await service.snapshot())['enabled'], false);
    },
  );
  test('expiry prunes old counters from storage and export', () async {
    await service.setEnabled(true);
    service.record(UsageEvent.workoutStarted);
    await service.snapshot();
    now = now.add(const Duration(days: 30));
    expect((await service.snapshot())['counts'], isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonDecode(prefs.getString('local_usage_v1_$owner')!);
    expect(raw['counts'], isEmpty);
  });
  test('clearing counters leaves explicit consent enabled', () async {
    await service.setEnabled(true);
    service.record(UsageEvent.workoutSaved);
    await service.clear();
    expect((await service.snapshot())['enabled'], true);
    expect((await service.snapshot())['counts'], isEmpty);
  });
  test('failed consent storage cannot enable via optimistic cache', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = RejectUsageWrites();
    SharedPreferences.resetStatic();
    try {
      await expectLater(service.setEnabled(true), throwsStateError);
      service.record(UsageEvent.routeBuilt);
      expect((await service.snapshot())['enabled'], false);
      expect((await service.snapshot())['counts'], isEmpty);
    } finally {
      SharedPreferencesStorePlatform.instance = previous;
      SharedPreferences.resetStatic();
    }
  });
}
