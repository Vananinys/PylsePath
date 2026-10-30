import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/data/navigation_preferences.dart';
import 'package:pulsepath/data/workout_draft_store.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/group_coordination.dart';
import 'package:pulsepath/screens/group_ride_screen.dart';
import 'package:pulsepath/screens/group_meeting_editor.dart';
import 'package:pulsepath/widgets/group_start_choice.dart';
import 'package:pulsepath/widgets/group_ride_actions.dart';
import 'package:pulsepath/widgets/group_coordination_panel.dart';

import 'group_coordination_test.dart' show FakeCoordination, me, other, room;

class FlowGroup extends FakeCoordination {
  final progress = <Map<String, Object?>>[];
  String? lastNote;
  LatLng? lastPoint;
  @override
  Future<String> createRoom({
    String title = 'Наша поездка',
    bool replace = false,
  }) async {
    activeRoomId = room;
    activeCode = 'ABCDEF123456';
    this.title = title;
    isHost = true;
    hostId = me;
    notifyListeners();
    return room;
  }

  @override
  Future<void> sendSignal(
    GroupSignalKind kind, {
    double? latitude,
    double? longitude,
    String note = '',
  }) async {
    signalCalls++;
    lastNote = note;
    lastPoint = latitude == null || longitude == null
        ? null
        : LatLng(latitude, longitude);
    coordination = GroupCoordination(
      plan: coordination.plan,
      readiness: coordination.readiness,
      signals: [
        GroupSignal(
          id: 'new',
          authorId: me,
          kind: kind,
          note: note,
          point: lastPoint,
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        ),
      ],
    );
    notifyListeners();
  }

  @override
  Future<void> updateProgress(
    String roomId, {
    required double distanceMeters,
    required int durationSeconds,
    double? latitude,
    double? longitude,
    String workoutState = 'waiting',
  }) async {
    progress.add({
      'room': roomId,
      'meters': distanceMeters,
      'seconds': durationSeconds,
      'lat': latitude,
      'state': workoutState,
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://group-flow.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        http.Response json(Object data) => http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
        if (request.url.path.endsWith('/token')) {
          String part(Object data) => base64Url
              .encode(utf8.encode(jsonEncode(data)))
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
              'created_at': '2026-10-27T00:00:00Z',
            },
          });
        }
        return json([]);
      }),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'group-flow@example.invalid',
      password: 'test-only',
    );
  });
  tearDownAll(() async => Supabase.instance.dispose());
  setUp(() => NavigationPreferences.instance.cachedMapOnly = true);
  tearDown(() => NavigationPreferences.instance.cachedMapOnly = false);

  test(
    'Room membership alone never opts a workout into group progress',
    () async {
      final group = FlowGroup();
      final controller = MapNavigationController(groupRideService: group);
      controller.startWorkout();
      expect(controller.workoutGroupRoomId, isNull);
      expect(controller.isGroupWorkout, false);
      await controller.publishGroupProgressForTesting();
      expect(group.progress.last['state'], 'waiting');
      expect(group.progress.last['lat'], isNull);
      expect(group.progress.last['meters'], 0);
      controller.dispose();
      group.dispose();
    },
  );
  test('Explicit group binding refuses another room and cannot follow a membership switch', () async {
    final group = FlowGroup();
    final controller = MapNavigationController(groupRideService: group);
    expect(
      () => controller.startWorkout(groupRoomId: 'another-room'),
      throwsStateError,
    );
    expect(controller.isWorkoutActive, false);
    controller.startWorkout(groupRoomId: room);
    expect(controller.groupWorkoutConnected, true);
    await controller.publishGroupProgressForTesting();
    expect(group.progress.last['state'], 'active');
    group.activeRoomId = 'different-room';
    group.membershipRevision++;
    await controller.publishGroupProgressForTesting();
    expect(controller.workoutGroupRoomId, room);
    expect(controller.groupWorkoutConnected, false);
    expect(group.progress.last['room'], 'different-room');
    expect(group.progress.last['state'], 'waiting');
    expect(group.progress.last['meters'], 0);
    controller.dispose();
    group.dispose();
  });
  test(
    'Interrupted binding survives checkpoint JSON; legacy drafts remain solo',
    () {
      final draft = WorkoutDraft(
        ownerId: me,
        localId: 'draft',
        startedAt: DateTime.now(),
        activeMilliseconds: 1000,
        distanceMeters: 10,
        elevationGainMeters: 0,
        activity: ActivityType.cycling,
        path: const [LatLng(55, 37)],
        groupRoomId: room,
      );
      final restored = WorkoutDraft.fromJson(draft.toJson(), me);
      expect(restored.groupRoomId, room);
      final legacy = WorkoutDraft.fromJson({
        ...draft.toJson(),
        'groupRoomId': null,
      }, me);
      expect(legacy.groupRoomId, isNull);
      expect(legacy.path.length, 1);
      final group = FlowGroup();
      final controller = MapNavigationController(groupRideService: group);
      controller.restoreInterruptedWorkout(restored);
      expect(controller.isWorkoutPaused, true);
      expect(controller.workoutGroupRoomId, room);
      controller.dispose();
      group.dispose();
    },
  );
  test(
    'Finishing one recording leaves the group open and clears only its binding',
    () async {
      final group = FlowGroup();
      final controller = MapNavigationController(groupRideService: group);
      controller.startWorkout(groupRoomId: room);
      await controller.discardWorkout();
      await Future<void>.delayed(Duration.zero);
      expect(controller.workoutGroupRoomId, isNull);
      expect(group.activeRoomId, room);
      expect(group.progress.last['state'], 'finished');
      expect(controller.isWorkoutActive, false);
      controller.dispose();
      group.dispose();
    },
  );

  testWidgets(
    'Create group is preparation; returning to main does not start recording',
    (tester) async {
      final group = FlowGroup()..activeRoomId = null;
      final controller = MapNavigationController(groupRideService: group);
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GroupRideScreen(
                        service: group,
                        navigationController: controller,
                      ),
                    ),
                  );
                },
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать группу'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Вечерняя поездка');
      await tester.tap(find.text('Создать'));
      await tester.pumpAndSettle();
      expect(group.title, 'Вечерняя поездка');
      expect(controller.isWorkoutActive, false);
      await tester.tap(find.text('Перейти к старту тренировки'));
      await tester.pumpAndSettle();
      expect(result, 'prepare_group');
      expect(controller.isWorkoutActive, false);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      group.dispose();
    },
  );
  testWidgets(
    'Start choice is explicit and never silently adopts a changed group',
    (tester) async {
      final group = FlowGroup();
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => GroupStartChoice(
                service: group,
                selectedRoomId: chosen,
                onChanged: (id) => setState(() => chosen = id),
                onManage: () {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('В группе'));
      await tester.pumpAndSettle();
      expect(chosen, room);
      group.activeRoomId = 'other-room';
      group.notifyListeners();
      await tester.pump();
      expect(chosen, room);
      expect(find.textContaining('Группа изменилась'), findsOneWidget);
      await tester.tap(find.text('Без группы'));
      await tester.pumpAndSettle();
      expect(chosen, isNull);
      await tester.pumpWidget(const SizedBox());
      group.dispose();
    },
  );
  testWidgets(
    'Group dashboard fits 320 large text; stop requires map choice and keeps note',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final group = FlowGroup();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: GroupRideScreen(service: group),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('В пути'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('В пути'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Предложить остановку').hitTestable(),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Предложить остановку'));
      await tester.pumpAndSettle();
      expect(find.byType(GroupMeetingEditor), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Предложить группе'),
            )
            .onPressed,
        isNull,
      );
      await tester.tapAt(tester.getRect(find.byType(FlutterMap)).center);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Предложить группе'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.enterText(find.byType(TextField), 'Вода у парка');
      await tester.ensureVisible(find.text('Предложить группе'));
      await tester.tap(find.text('Предложить группе'));
      await tester.pumpAndSettle();
      expect(group.signalCalls, 1);
      expect(group.lastNote, 'Вода у парка');
      expect(group.lastPoint, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      group.dispose();
    },
  );
  testWidgets(
    'Stop card supports coming acknowledgement and selected point without changing route',
    (tester) async {
      final group = FlowGroup();
      final now = DateTime.now();
      LatLng? chosen;
      group.coordination = GroupCoordination(
        signals: [
          GroupSignal(
            id: 'peer-stop',
            authorId: other,
            kind: GroupSignalKind.stop,
            note: 'Вода у парка',
            point: const LatLng(55, 37),
            createdAt: now,
            expiresAt: now.add(const Duration(minutes: 10)),
          ),
        ],
      );
      final original = group.route;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupEventsCarousel(
              service: group,
              onPoint: (p) => chosen = p,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Я за'));
      await tester.pumpAndSettle();
      expect(group.response, 'coming');
      await tester.tap(find.text('Место на карте'));
      await tester.pump();
      expect(chosen, const LatLng(55, 37));
      expect(group.route, same(original));
      await tester.pumpWidget(const SizedBox());
      group.dispose();
    },
  );
  testWidgets(
    'Solo HUD hides group commands; stale action scope cannot send into another room',
    (tester) async {
      final group = FlowGroup();
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              page = context;
              return Scaffold(
                body: GroupRideQuickActions(service: group, onOpen: () {}),
              );
            },
          ),
        ),
      );
      expect(find.textContaining('Группа ·'), findsNothing);
      expect(find.text('Остановка'), findsNothing);
      final scope = GroupActionScope(group);
      group.activeRoomId = 'changed';
      group.membershipRevision++;
      expect(
        await scope.run(page, () => group.sendSignal(GroupSignalKind.wait)),
        false,
      );
      expect(group.signalCalls, 0);
      await tester.pumpWidget(const SizedBox());
      group.dispose();
    },
  );
}
