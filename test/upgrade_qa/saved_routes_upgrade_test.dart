// Compatibility of the saved-route library (a bare JSON array, no envelope).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../deepseek_integrity/network_guard.dart';
import 'qa_support.dart';

const routesKey = 'saved_routes_guest';

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
    SavedRoutesRepository.resetInstancesForTesting();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = previousPlatform;
    SharedPreferences.resetStatic();
    SavedRoutesRepository.resetInstancesForTesting();
  });

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  Future<Object?> durable(String key) async =>
      (await platform.getAll())['flutter.$key'];

  Future<List<String>> damagedValues(String key) async {
    final all = await platform.getAll();
    return [
      for (final entry in all.entries)
        if (entry.key.startsWith('flutter.${key}_damaged_'))
          entry.value as String,
    ];
  }

  test(
    'a legacy route array gets stable IDs on first open and reopens unchanged',
    () async {
      final store = await prefs();
      await store.setString(
        routesKey,
        jsonEncode([
          workoutRow(
            remoteId: 'cloud-route-1',
            activityType: null,
            activityIndex: 4,
            createdAt: 1790848800000,
            newFields: false,
          ),
          workoutRow(
            activityType: null,
            activityIndex: 1,
            createdAt: 1790935200000,
            newFields: false,
          ),
        ]),
      );

      final loaded = await SavedRoutesRepository().getSavedRoutes();
      expect(loaded, hasLength(2));
      final ids = loaded.map((route) => route.localId).toList();
      expect(ids.first, 'cloud-route-1');
      expect(ids.last, isNotEmpty);
      expect(loaded.first.activityType.name, 'cycling');
      expect(
        loaded.first.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1790848800000),
      );

      final persisted =
          jsonDecode((await durable(routesKey)) as String) as List<dynamic>;
      expect(
        persisted.map((row) => (row as Map<String, dynamic>)['localId']),
        ids,
        reason: 'the first open must persist the generated identities',
      );

      SharedPreferences.resetStatic();
      SavedRoutesRepository.resetInstancesForTesting();
      final reopened = await SavedRoutesRepository().getSavedRoutes();
      expect(reopened.map((route) => route.localId), ids);
      expect(
        await damagedValues(routesKey),
        isEmpty,
        reason: 'assigning IDs to legacy rows is a migration, not damage',
      );
    },
  );

  test(
    'unknown route fields survive opening the library or are archived',
    () async {
      final store = await prefs();
      await store.setString(
        routesKey,
        jsonEncode([
          workoutRow(
            localId: 'route-future',
            details: {
              'effort': 5,
              'sensor_v2': {'watts': 123.4, 'source': 'qa'},
            },
            extra: {
              'weather_v2': {'temp_c': 7},
              'schema_rev': 99,
            },
          ),
        ]),
      );

      final original = await durable(routesKey) as String;
      final loaded = await SavedRoutesRepository().getSavedRoutes();
      expect(loaded.single.localId, 'route-future');

      expect(await damagedValues(routesKey), contains(original));
      final stored = await durable(routesKey) as String;
      final archived = (await damagedValues(routesKey))
          .any((value) => value.contains('sensor_v2'));
      expect(
        stored.contains('sensor_v2') || archived,
        isTrue,
        reason:
            'opening the saved-route library rewrote and discarded fields '
            'written by a newer build, without keeping a backup',
      );
      expect(
        stored.contains('weather_v2') || archived,
        isTrue,
        reason:
            'a top-level route field written by a newer build was silently '
            'discarded while merely reading the library',
      );
    },
  );

  test(
    'unreadable route libraries are never replaced by an empty or partial list',
    () async {
      final cases = <String>[
        '{broken',
        jsonEncode({
          'version': 3,
          'routes': [workoutRow(localId: 'future-route')],
        }),
        jsonEncode([
          workoutRow(localId: 'good'),
          {'localId': 'truncated'},
        ]),
      ];

      for (final original in cases) {
        SharedPreferences.resetStatic();
        SavedRoutesRepository.resetInstancesForTesting();
        final store = await prefs();
        await store.setString(routesKey, original);
        final repository = SavedRoutesRepository();
        await expectLater(repository.getSavedRoutes(), throwsA(anything));
        await expectLater(
          repository.addRoute(SavedRoute.fromJson(workoutRow(localId: 'x'))),
          throwsA(anything),
        );
        expect(
          await durable(routesKey),
          original,
          reason: 'unreadable stored bytes must remain untouched',
        );
      }
    },
  );
}
