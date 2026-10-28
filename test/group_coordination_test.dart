import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/models/group_coordination.dart';
import 'package:pulsepath/services/group_ride_service.dart';
import 'package:pulsepath/widgets/group_coordination_panel.dart';
import 'package:pulsepath/screens/group_ride_screen.dart';
import 'package:pulsepath/screens/group_meeting_editor.dart';
import 'package:pulsepath/data/navigation_preferences.dart';

const me = 'f8128000-0000-4000-8000-000000000001';
const other = 'f8128000-0000-4000-8000-000000000002';
const room = 'f8128000-0000-4000-8000-000000000010';
Map<String, dynamic> snapshot({
  String ready = 'waiting',
  String host = me,
  DateTime? serverNow,
}) => {
  'id': room,
  'code': 'ABCDEF123456',
  'title': 'Тестовый заезд',
  'host_id': host,
  'server_now': (serverNow ?? DateTime.now().toUtc()).toIso8601String(),
  'members': [
    for (final id in [me, other])
      {
        'user_id': id,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'distance_m': 0,
        'duration_seconds': 0,
        'workout_state': 'waiting',
        'profile': {'username': id == me ? 'Сергей' : 'Друг'},
      },
  ],
  'coordination': {
    'settings': null,
    'readiness': [
      {'user_id': me, 'state': ready},
    ],
    'signals': [],
  },
};

class FakeCoordination extends GroupRideService {
  FakeCoordination() : super.forTesting() {
    activeRoomId = room;
    activeCode = 'ABCDEF123456';
    hostId = me;
    isHost = true;
    members = [
      for (final id in [me, other])
        GroupMember(
          userId: id,
          username: id == me ? 'Сергей' : 'Друг',
          distanceMeters: 0,
          durationSeconds: 0,
          updatedAt: DateTime.now(),
        ),
    ];
  }
  int signalCalls = 0, readyCalls = 0;
  String? response;
  String? transferred;
  bool? leftAsHost;
  @override
  String? get userId => me;
  @override
  Future<void> restoreSession() async {}
  @override
  Future<void> refreshMembers() async {}
  @override
  Future<void> setReadiness(GroupReadiness state) async {
    readyCalls++;
    coordination = GroupCoordination(
      readiness: {me: state},
      signals: coordination.signals,
    );
    notifyListeners();
  }

  @override
  Future<void> sendSignal(
    GroupSignalKind kind, {
    double? latitude,
    double? longitude,
    String note = '',
  }) async {
    signalCalls++;
    coordination = GroupCoordination(
      readiness: coordination.readiness,
      signals: [
        GroupSignal(
          id: 'event',
          authorId: me,
          kind: kind,
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        ),
      ],
    );
    notifyListeners();
  }

  @override
  Future<void> respondToSignal(String id, String response) async {
    this.response = response;
    notifyListeners();
  }

  @override
  Future<void> transferHost(String target) async {
    transferred = target;
    hostId = target;
    isHost = false;
    notifyListeners();
  }

  @override
  Future<void> leaveRoom(String roomId, {required bool isHost}) async {
    leftAsHost = isHost;
    activeRoomId = null;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Expired and malformed signals cannot become active', () {
    final now = DateTime.utc(2026, 10, 26, 10);
    final raw = {
      'id': 's',
      'author_id': me,
      'kind': 'help',
      'created_at': now.subtract(const Duration(minutes: 10)).toIso8601String(),
      'expires_at': now.subtract(const Duration(seconds: 1)).toIso8601String(),
      'latitude': 999,
      'longitude': 37,
    };
    final signal = GroupSignal.tryParse(raw)!;
    expect(signal.activeAt(now), isFalse);
    expect(signal.point, isNull);
    expect(GroupSignal.tryParse({...raw, 'kind': 'unknown'}), isNull);
    expect(GroupSignal.tryParse({...raw, 'expires_at': 'bad'}), isNull);
  });
  test(
    'Server clock offset corrects expiration without shifting meeting time',
    () {
      final data = GroupCoordination.fromRow({
        'settings': {
          'starts_at': '2026-10-26T10:00:00Z',
          'ride_style': 'training',
        },
        'signals': [
          {
            'id': 's',
            'author_id': me,
            'kind': 'wait',
            'created_at': '2026-10-26T09:00:00Z',
            'expires_at': '2026-10-26T09:10:00Z',
          },
        ],
      }, clockOffset: const Duration(hours: 2));
      expect(data.plan.startsAt, DateTime.utc(2026, 10, 26, 10));
      expect(data.signals.single.expiresAt, DateTime.utc(2026, 10, 26, 11, 10));
    },
  );
  test('Acknowledgements deduplicate readers and reject unknown responses', () {
    final signal = GroupSignal.tryParse({
      'id': 's',
      'author_id': me,
      'kind': 'help',
      'created_at': '2026-10-26T09:00:00Z',
      'expires_at': '2026-10-26T09:30:00Z',
      'responses': [
        {'user_id': other, 'response': 'seen'},
        {'user_id': other, 'response': 'coming'},
        {'user_id': 'x', 'response': 'invented'},
      ],
    })!;
    expect(signal.responses, {other: 'coming'});
    expect(() => signal.responses['x'] = 'seen', throwsUnsupportedError);
  });
  test('Pending intents expire and never survive a backward clock jump', () {
    final now = DateTime.utc(2026);
    final intent = GroupPendingIntent(id: 'r', payload: {}, createdAt: now);
    expect(intent.reusableAt(now.add(const Duration(seconds: 29))), isTrue);
    expect(intent.reusableAt(now.add(const Duration(seconds: 30))), isFalse);
    expect(
      intent.reusableAt(now.subtract(const Duration(seconds: 1))),
      isFalse,
    );
  });

  group('Real service with isolated HTTP transport', () {
    late SupabaseClient client;
    late GroupRideService service;
    late List<http.Request> requests;
    bool fail = false;
    String? rejection;
    Completer<Map<String, dynamic>>? slowRead;
    Completer<Map<String, dynamic>>? slowAction;
    late DateTime serverNow;
    setUp(() async {
      requests = [];
      fail = false;
      rejection = null;
      slowRead = null;
      slowAction = null;
      serverNow = DateTime.now().toUtc();
      client = SupabaseClient(
        'https://group-qa.example.invalid',
        'test-only',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          http.Response json(Object? value, int status) => http.Response(
            jsonEncode(value),
            status,
            headers: {'content-type': 'application/json'},
            request: request,
          );
          if (request.url.path.endsWith('/token')) {
            String part(Object value) => base64Url
                .encode(utf8.encode(jsonEncode(value)))
                .replaceAll('=', '');
            return json({
              'access_token':
                  '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.signature',
              'refresh_token': 'fake',
              'expires_in': 3600,
              'token_type': 'bearer',
              'user': {
                'id': me,
                'aud': 'authenticated',
                'role': 'authenticated',
                'app_metadata': {},
                'user_metadata': {},
                'created_at': '2026-10-26T00:00:00Z',
              },
            }, 200);
          }
          if (request.url.path.endsWith('/group_room_snapshot_v2')) {
            if (slowRead != null) return json(await slowRead!.future, 200);
            return json(snapshot(serverNow: serverNow), 200);
          }
          if (request.url.path.endsWith('/group_coordination_action')) {
            if (slowAction != null) return json(await slowAction!.future, 200);
            if (rejection != null) {
              return json({'code': 'P0001', 'message': rejection}, 400);
            }
            if (fail) {
              return json({'code': '503', 'message': 'temporary failure'}, 503);
            }
            return json(snapshot(ready: 'ready', serverNow: serverNow), 200);
          }
          throw StateError('Unexpected request ${request.url.path}');
        }),
      );
      await client.auth.signInWithPassword(
        email: 'qa@example.invalid',
        password: 'test-only',
      );
      service = GroupRideService.forTesting(client: client);
      await service.refreshMembers();
      requests.clear();
    });
    tearDown(() async {
      service.clearSession();
      service.dispose();
      await client.dispose();
    });
    test(
      'Uncertain retry keeps request ID; confirmed intent gets a fresh ID',
      () async {
        fail = true;
        await expectLater(
          service.setReadiness(GroupReadiness.ready),
          throwsA(isA<GroupRideException>()),
        );
        final first = jsonDecode(requests.last.body) as Map;
        fail = false;
        await service.setReadiness(GroupReadiness.ready);
        final retry = jsonDecode(requests.last.body) as Map;
        expect(retry['p_request'], first['p_request']);
        expect(service.coordination.readiness[me], GroupReadiness.ready);
        await service.setReadiness(GroupReadiness.ready);
        expect(
          (jsonDecode(requests.last.body) as Map)['p_request'],
          isNot(first['p_request']),
        );
      },
    );
    test('Old room snapshot cannot overwrite confirmed readiness', () async {
      slowRead = Completer();
      final pending = service.refreshMembers();
      await Future<void>.delayed(Duration.zero);
      await service.setReadiness(GroupReadiness.ready);
      slowRead!.complete(snapshot());
      await pending;
      expect(service.coordination.readiness[me], GroupReadiness.ready);
    });
    test(
      'Failed action keeps the last confirmed snapshot and releases busy state',
      () async {
        await service.setReadiness(GroupReadiness.ready);
        fail = true;
        await expectLater(
          service.setReadiness(GroupReadiness.late),
          throwsA(isA<GroupRideException>()),
        );
        expect(service.coordination.readiness[me], GroupReadiness.ready);
        expect(service.coordinating, isFalse);
      },
    );
    test(
      'Signal deadline uses server time and no location is added by default',
      () async {
        serverNow = DateTime.now().toUtc().subtract(const Duration(hours: 2));
        await service.refreshMembers();
        await service.sendSignal(GroupSignalKind.wait);
        final body = jsonDecode(requests.last.body) as Map;
        final payload = body['p_payload'] as Map;
        final deadline = DateTime.parse(payload['valid_until']);
        expect(
          deadline.difference(serverNow).inSeconds,
          inInclusiveRange(29, 35),
        );
        expect(payload['latitude'], isNull);
        expect(payload['longitude'], isNull);
      },
    );
    test(
      'Concurrent actions rejected rather than overwriting each other',
      () async {
        slowAction = Completer();
        final first = service.setReadiness(GroupReadiness.ready);
        await Future<void>.delayed(Duration.zero);
        await expectLater(
          service.setReadiness(GroupReadiness.late),
          throwsA(isA<GroupRideException>()),
        );
        slowAction!.complete(snapshot(ready: 'ready'));
        await first;
        expect(
          requests
              .where((r) => r.url.path.endsWith('/group_coordination_action'))
              .length,
          1,
        );
      },
    );
    test('Account switch discards a late mutation result', () async {
      slowAction = Completer();
      final pending = service.setReadiness(GroupReadiness.ready);
      final rejected = expectLater(pending, throwsA(isA<GroupRideException>()));
      await Future<void>.delayed(Duration.zero);
      service.bindToUser(other);
      slowAction!.complete(snapshot(ready: 'ready'));
      await rejected;
      expect(service.activeRoomId, isNull);
      expect(service.coordination.readiness, isEmpty);
      expect(service.coordinating, isFalse);
    });
    test(
      'Expired server intent is not reused on a fresh explicit attempt',
      () async {
        rejection = 'SIGNAL_EXPIRED';
        await expectLater(
          service.sendSignal(GroupSignalKind.wait),
          throwsA(isA<GroupRideException>()),
        );
        final first = (jsonDecode(requests.last.body) as Map)['p_request'];
        rejection = null;
        await service.sendSignal(GroupSignalKind.wait);
        expect(
          (jsonDecode(requests.last.body) as Map)['p_request'],
          isNot(first),
        );
      },
    );
  });

  testWidgets('Ready status and help cancellation do not start a workout', (
    tester,
  ) async {
    final service = FakeCoordination();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GroupCoordinationPanel(service: service),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Готов'));
    await tester.pumpAndSettle();
    expect(service.readyCalls, 1);
    await tester.ensureVisible(find.text('Нужна помощь'));
    await tester.tap(find.text('Нужна помощь'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(service.signalCalls, 0);
  });
  testWidgets('Expired commands hidden, live command can be acknowledged', (
    tester,
  ) async {
    final service = FakeCoordination();
    addTearDown(service.dispose);
    final now = DateTime.now();
    service.coordination = GroupCoordination(
      signals: [
        GroupSignal(
          id: 'old',
          authorId: other,
          kind: GroupSignalKind.stopped,
          createdAt: now.subtract(const Duration(hours: 1)),
          expiresAt: now.subtract(const Duration(seconds: 1)),
        ),
        GroupSignal(
          id: 'new',
          authorId: other,
          kind: GroupSignalKind.wait,
          createdAt: now,
          expiresAt: now.add(const Duration(minutes: 10)),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GroupCoordinationPanel(service: service),
          ),
        ),
      ),
    );
    expect(find.text('Друг: Остановился'), findsNothing);
    expect(find.text('Друг: Подождите меня'), findsOneWidget);
    await tester.ensureVisible(find.text('Увидел'));
    await tester.tap(find.text('Увидел'));
    await tester.pumpAndSettle();
    expect(service.response, 'seen');
  });
  testWidgets('Host can transfer and leave without closing peers room', (
    tester,
  ) async {
    final old = NavigationPreferences.instance.cachedMapOnly;
    NavigationPreferences.instance.cachedMapOnly = true;
    addTearDown(() => NavigationPreferences.instance.cachedMapOnly = old);
    final service = FakeCoordination();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(home: GroupRideScreen(service: service)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Настройки группы'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Закрыть группу'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Передать и выйти'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Друг'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Передать'));
    await tester.pumpAndSettle();
    expect(service.transferred, other);
    expect(service.leftAsHost, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Meeting map does not publish its initial center without a chosen point',
    (tester) async {
      final old = NavigationPreferences.instance.cachedMapOnly;
      NavigationPreferences.instance.cachedMapOnly = true;
      addTearDown(() => NavigationPreferences.instance.cachedMapOnly = old);
      await tester.pumpWidget(
        const MaterialApp(
          home: GroupMeetingEditor(initial: GroupMeetPlan(), pointOnly: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Подтвердить'),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('Coordination panel fits 320px and large text', (tester) async {
    final service = FakeCoordination();
    addTearDown(service.dispose);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: GroupCoordinationPanel(service: service),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
