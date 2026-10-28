import 'package:pulsepath/data/navigation_preferences.dart';
import 'package:pulsepath/services/app_update_service.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/data/chat_local_store.dart';
import 'package:pulsepath/models/chat_message.dart';
import 'package:pulsepath/models/saved_route.dart';

import 'upgrade_qa/qa_support.dart';

// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class BackupFailure extends QaPreferencesStore {
  bool reject = true;
  int attempts = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.contains('_damaged_')) {
      attempts++;
      if (reject) return false;
    }
    return super.setValue(type, key, value);
  }
}

class ReadAndWriteFailure extends QaPreferencesStore {
  bool failReads = false;
  @override
  Future<Map<String, Object>> getAll() async {
    if (failReads) throw StateError('test read failure');
    return super.getAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform previous;
  late BackupFailure platform;
  setUp(() {
    previous = SharedPreferencesStorePlatform.instance;
    platform = BackupFailure();
    SharedPreferencesStorePlatform.instance = platform;
    SharedPreferences.resetStatic();
    SavedRoutesRepository.resetInstancesForTesting();
    WorkoutHistoryRepository.resetInstancesForTesting();
  });
  tearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
    SavedRoutesRepository.resetInstancesForTesting();
    WorkoutHistoryRepository.resetInstancesForTesting();
  });
  Future<String?> durable(String key) async =>
      (await platform.getAll())['flutter.$key'] as String?;
  test('history envelope and row unknown fields are durably archived, failed backup blocks overwrite', () async {
    final original = jsonEncode({
      'version': 2,
      'future_epoch': 99,
      'workouts': [
        workoutRow(
          localId: 'old',
          extra: {
            'weather_v2': {'temp': 9},
          },
        ),
      ],
    });
    await (await SharedPreferences.getInstance()).setString(
      'workout_history_guest',
      original,
    );
    final history = WorkoutHistoryRepository();
    for (var i = 0; i < 2; i++)
      await expectLater(
        history.addWorkout(SavedRoute.fromJson(workoutRow(localId: 'new'))),
        throwsStateError,
      );
    expect(platform.attempts, 2);
    expect(await durable('workout_history_guest'), original);
    platform.reject = false;
    await history.addWorkout(SavedRoute.fromJson(workoutRow(localId: 'new')));
    expect(
      (await platform.getAll()).entries
          .where((e) => e.key.contains('_damaged_'))
          .single
          .value,
      original,
    );
    expect(history.workoutHistory, hasLength(2));
  });
  test(
    'fresh library save and clear never erase an unreadable original',
    () async {
      const original = '{"version":99,"future_routes":[]}';
      await (await SharedPreferences.getInstance()).setString(
        'saved_routes_guest',
        original,
      );
      platform.reject = false;
      final routes = SavedRoutesRepository();
      await expectLater(routes.save(), throwsFormatException);
      await expectLater(routes.clear(), throwsFormatException);
      expect(await durable('saved_routes_guest'), original);
      expect(
        (await platform.getAll()).entries
            .where((e) => e.key.contains('_damaged_'))
            .single
            .value,
        original,
      );
    },
  );
  test(
    'failed library backup blocks migration and leaves all original bytes',
    () async {
      final original = jsonEncode([
        workoutRow(extra: {'future_field': 42}),
      ]);
      await (await SharedPreferences.getInstance()).setString(
        'saved_routes_guest',
        original,
      );
      final routes = SavedRoutesRepository();
      await expectLater(routes.load(), throwsStateError);
      await expectLater(routes.save(), throwsStateError);
      expect(await durable('saved_routes_guest'), original);
      platform.reject = false;
      await routes.load();
      expect(routes.savedRoutes, hasLength(1));
      expect(
        (await platform.getAll()).entries
            .where((e) => e.key.contains('_damaged_'))
            .single
            .value,
        original,
      );
    },
  );
  test('chat preserves corrupt primary and persists new pending messages in recovery across restart', () async {
    const key = 'chat_v1_friend_me';
    const original = '[{"id":"old-pending",';
    await (await SharedPreferences.getInstance()).setString(key, original);
    final store = ChatLocalStore('me', 'friend', currentOwner: () => 'me');
    await expectLater(store.readMessages(), throwsStateError);
    await expectLater(store.saveMessages([]), throwsStateError);
    expect(await durable(key), original);
    expect(await durable('${key}_recovery_v1'), isNull);
    platform.reject = false;
    await store.saveMessages([
      ChatMessage(
        id: 'new-pending',
        senderId: 'me',
        receiverId: 'friend',
        createdAt: DateTime.utc(2026),
        body: 'new',
        delivery: MessageDelivery.sending,
      ),
    ]);
    SharedPreferences.resetStatic();
    final reopened = ChatLocalStore('me', 'friend', currentOwner: () => 'me');
    expect((await reopened.readMessages()).single.id, 'new-pending');
    expect(reopened.recoveryNotice, isNotNull);
    expect(await durable(key), original);
    expect(
      (await platform.getAll()).entries
          .where((e) => e.key.contains('_damaged_'))
          .single
          .value,
      original,
    );
  });
  test(
    'stale draft save reports error and cannot write to the next account',
    () async {
      String? owner = 'me';
      final store = ChatLocalStore('me', 'friend', currentOwner: () => owner);
      await store.saveDraft('kept');
      owner = 'other';
      await expectLater(store.saveDraft('lost'), throwsStateError);
      expect(await durable('chat_v1_friend_me_draft'), 'kept');
      expect(await durable('chat_v1_friend_other_draft'), isNull);
    },
  );
  test('failed channel write and failed cache reload never expose unconfirmed beta', () async {
    final broken = ReadAndWriteFailure();
    SharedPreferencesStorePlatform.instance = broken;
    SharedPreferences.resetStatic();
    await SharedPreferences.getInstance();
    broken.throwOnWritesTo('app_update_channel_v1');
    broken.failReads = true;
    await expectLater(
      AppUpdateService.selectChannel(UpdateChannel.beta),
      throwsA(anything),
    );
    expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
    broken.failReads = false;
    expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
  });
  test('wrong-typed navigation preferences cannot prevent startup or discard valid zoom', () async {
    SharedPreferences.setMockInitialValues({
      'nav_color': 'old',
      'nav_line_width': 'wide',
      'nav_follow_zoom': 18.0,
      'nav_cached_map_only': 123,
    });
    await NavigationPreferences.instance.load();
    expect(NavigationPreferences.instance.colorIndex, 0);
    expect(NavigationPreferences.instance.lineWidth, 5.5);
    expect(NavigationPreferences.instance.followZoom, 18);
    expect(NavigationPreferences.instance.cachedMapOnly, false);
  });
}
