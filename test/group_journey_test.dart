import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/services/group_ride_service.dart';
import 'package:pulsepath/services/group_workout_navigation.dart';
import 'package:pulsepath/screens/clubs_screen.dart';
import 'package:pulsepath/widgets/group_journey_panel.dart';
import 'package:pulsepath/widgets/group_workout_lobby.dart';
import 'package:pulsepath/widgets/group_ride_result_sheet.dart';
import 'package:pulsepath/widgets/group_invitation_card.dart';
import 'package:pulsepath/ui/app_theme.dart';
import 'package:pulsepath/widgets/club_overview.dart';
import 'package:pulsepath/widgets/pre_ride_widget.dart';
import 'package:pulsepath/widgets/group_start_choice.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart'
    show SportMode;

import 'group_coordination_test.dart' show me, other, room, snapshot;
import 'clubs_invitation_flow_test.dart' show TestClubs;

const nextRoom = 'f8128000-0000-4000-8000-000000000011';

class JourneyClubs extends TestClubs {
  int reads = 0;
  @override
  Future<dynamic> action(
    String action, {
    String? club,
    Map<String, dynamic> data = const {},
  }) async {
    if (action == 'notifications')
      snapshotData['notification_mode'] = data['mode'];
    if (action == 'read') {
      reads++;
      snapshotData['unread_count'] = 0;
    }
    return super.action(action, club: club, data: data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late GroupRideService service;
  late Future<http.Response> Function(http.Request) handle;
  late http.Request request;
  http.Response json(Object? data, {int status = 200}) => http.Response(
    jsonEncode(data),
    status,
    request: request,
    headers: {'content-type': 'application/json'},
  );
  Map<String, dynamic> envelope({
    String id = room,
    String status = 'pending',
    String ownState = 'waiting',
  }) {
    final data = snapshot();
    data['id'] = id;
    (data['members'] as List).first['workout_state'] = ownState;
    return {
      'room': data,
      'invitations': [
        {
          'id': 'f8128000-0000-4000-8000-000000000099',
          'sender_id': me,
          'receiver_id': other,
          'username': 'Друг',
          'title': 'Заезд',
          'status': status,
        },
      ],
    };
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    handle = (_) async => json(envelope());
    client = SupabaseClient(
      'https://journey.example.invalid',
      'test-only',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        request = r;
        if (r.url.path.endsWith('/token')) {
          String part(Object d) =>
              base64Url.encode(utf8.encode(jsonEncode(d))).replaceAll('=', '');
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
              'created_at': '2026-10-31T00:00:00Z',
            },
          });
        }
        return handle(r);
      }),
    );
    await client.auth.signInWithPassword(
      email: 'qa@example.invalid',
      password: 'test-only',
    );
    service = GroupRideService.forTesting(client: client, uiFlow: true);
    await service.restoreSession();
  });
  tearDown(() async {
    GroupWorkoutNavigation.instance.consume();
    service.clearSession();
    service.dispose();
    await client.dispose();
  });
  if (const bool.fromEnvironment('CAPTURE_JOURNEY'))
    testWidgets('capture complete journey in both themes', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        for (final font in {
          'JourneyCapture': 'C:/Windows/Fonts/arial.ttf',
          'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
      });
      service.invitations.first['username'] = 'Александр';
      final club = JourneyClubs();
      club.snapshotData.addAll({
        'notification_mode': 'invitations',
        'unread_count': 3,
        'events': [
          {
            'title': 'Воскресная прогулка',
            'starts_at': DateTime.now()
                .add(const Duration(days: 1))
                .toIso8601String(),
            'attendees': [
              {'username': 'Мария'},
            ],
          },
        ],
      });
      for (final brightness in Brightness.values) {
        for (final page in {
          'waiting': GroupWorkoutLobby(
            service: service,
            busy: false,
            onInvite: () {},
            onPrepare: () {},
            onJoin: () {},
            onDetails: () {},
            onLeave: () {},
            onNewRide: () {},
          ),
          'preparation': Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 740),
                  child: PreRideWidget(
                    selectedVehicle: null,
                    onSelectVehicle: () {},
                    autoPauseEnabled: true,
                    onAutoPauseChanged: (_) {},
                    sportMode: SportMode.vehicle,
                    onSportModeChanged: (_) {},
                    onStartRide: () {},
                    onCollapse: () {},
                    onPlanRoute: () {},
                    groupChoice: GroupStartChoice(
                      service: service,
                      selectedRoomId: room,
                      onChanged: (_) {},
                      onManage: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
          'club-home': ClubDetailScreen(id: 'club', service: club),
          'result': Scaffold(
            body: GroupRideResultSheet(
              members: service.members,
              service: service,
              distanceKm: 12.5,
              minutes: 43,
              left: false,
            ),
          ),
        }.entries) {
          final key = GlobalKey();
          final theme = pulsePathTheme(brightness: brightness);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'JourneyCapture'),
              ),
              home: RepaintBoundary(key: key, child: page.value),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final img =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            final dir = Directory('audit/journey-previews')
              ..createSync(recursive: true);
            await File('${dir.path}/${page.key}-${brightness.name}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            img.dispose();
          });
        }
      }
      await tester.pumpWidget(const SizedBox());
    });
  test('new API snapshot keeps invitations distinct from membership', () {
    expect(service.activeRoomId, room);
    expect(service.members.length, 2);
    expect(service.invitations.single['status'], 'pending');
    expect(service.error, isNull);
  });
  test('uncertain fresh creation retries the same intent and accepts a new room only after acknowledgement', () async {
    final payloads = <Map>[];
    bool fail = true;
    handle = (r) async {
      payloads.add(jsonDecode(r.body) as Map);
      if (fail)
        return json({'code': '503', 'message': 'transient'}, status: 503);
      return json(envelope(id: nextRoom));
    };
    await expectLater(
      service.newRide(replace: true),
      throwsA(isA<GroupRideException>()),
    );
    expect(service.activeRoomId, room);
    fail = false;
    await service.newRide(replace: true);
    expect(
      payloads[0]['p_data']['request_id'],
      payloads[1]['p_data']['request_id'],
    );
    expect(service.activeRoomId, nextRoom);
    expect(service.error, isNull);
  });
  test('personal finish persists across stale server snapshots and does not repeat in the same ride', () async {
    handle = (r) async => r.method == 'PATCH'
        ? json([
            {'id': 'member'},
          ])
        : json(envelope());
    await service.finishPersonalWorkout(room, 1250, 300);
    expect(service.ownFinished, true);
    expect(service.members.first.workoutState, 'finished');
    final restored = GroupRideService.forTesting(client: client, uiFlow: true);
    await restored.restoreSession();
    expect(restored.ownFinished, true);
    handle = (_) async => json(envelope(id: nextRoom));
    await restored.newRide(replace: true);
    expect(restored.ownFinished, false);
    restored.clearSession();
    restored.dispose();
  });
  test('departure uses safe API and retains the result snapshot', () async {
    Map? payload;
    handle = (r) async {
      payload = jsonDecode(r.body) as Map;
      return json({'room': null, 'invitations': [], 'previous': snapshot()});
    };
    await service.endParticipation();
    expect(payload!['p_action'], 'depart');
    expect(payload!['p_data']['room_id'], room);
    expect(service.activeRoomId, isNull);
    expect(service.lastParticipants.length, 2);
  });
  testWidgets(
    'pending invitation can be cancelled and is never shown as accepted',
    (tester) async {
      String status = 'pending';
      handle = (r) async {
        if (r.url.path.endsWith('/group_ui_action')) {
          final p = jsonDecode(r.body);
          expect(p['p_action'], 'revoke');
          status = 'revoked';
          return json({'status': status});
        }
        return json(envelope(status: status));
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: service,
              builder: (c, _) => SingleChildScrollView(
                child: GroupJourneyPanel(service: service),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Приглашён · ожидаем ответа'), findsOneWidget);
      await tester.tap(find.byTooltip('Отменить приглашение'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отменить приглашение'));
      await tester.pumpAndSettle();
      expect(find.text('Приглашение отменено'), findsOneWidget);
      expect(GroupWorkoutNavigation.instance.roomId, isNull);
    },
  );
  testWidgets('recipient refusal never requests preparation or a join', (
    tester,
  ) async {
    final actions = <String>[];
    handle = (r) async {
      if (r.url.path.endsWith('/group_ui_snapshot'))
        return json(envelope(status: 'declined'));
      final p = jsonDecode(r.body);
      actions.add(p['p_action']);
      return json({
        'status': p['p_action'] == 'view' ? 'active' : 'declined',
        'sender_id': other,
        'receiver_id': me,
      });
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupInvitationDetails(id: 'invite', service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отказаться от приглашения'));
    await tester.pumpAndSettle();
    expect(actions, ['view', 'decline']);
    expect(GroupWorkoutNavigation.instance.roomId, isNull);
    expect(find.text('Вы отказались от приглашения'), findsOneWidget);
  });
  testWidgets(
    'club home shows nearest event, notification settings and unread chat',
    (tester) async {
      final club = JourneyClubs();
      club.snapshotData.addAll({
        'notification_mode': 'invitations',
        'unread_count': 5,
        'events': [
          {
            'id': 'later',
            'title': 'Поздняя встреча',
            'starts_at': DateTime.now()
                .add(const Duration(days: 4))
                .toIso8601String(),
            'attendees': [],
          },
          {
            'id': 'nearest',
            'title': 'Ближайшая прогулка',
            'starts_at': DateTime.now()
                .add(const Duration(days: 1))
                .toIso8601String(),
            'attendees': [],
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ClubDetailScreen(id: 'club', service: club),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ближайшая прогулка'), findsOneWidget);
      expect(find.text('Поздняя встреча'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Уведомления клуба'),
        180,
        scrollable: find.descendant(
          of: find.byType(ClubOverview),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.text('Уведомления клуба'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выключены'));
      await tester.pumpAndSettle();
      expect(club.snapshotData['notification_mode'], 'off');
      await tester.scrollUntilVisible(
        find.text('Чат клуба'),
        -180,
        scrollable: find.descendant(
          of: find.byType(ClubOverview),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.text('Чат клуба'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(club.reads, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets(
      'journey and result remain usable at 320px and 200% ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Widget app(Widget child) => MaterialApp(
          theme: pulsePathTheme(brightness: brightness),
          builder: (c, w) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: w!,
          ),
          home: child,
        );
        await tester.pumpWidget(
          app(
            GroupWorkoutLobby(
              service: service,
              busy: false,
              onInvite: () {},
              onPrepare: () {},
              onJoin: () {},
              onDetails: () {},
              onLeave: () {},
              onNewRide: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          app(
            Scaffold(
              body: GroupRideResultSheet(
                members: service.members,
                service: service,
                distanceKm: 1.25,
                minutes: 5,
                left: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Ваша тренировка сохранена'), findsOneWidget);
      },
    );
  }
}
