import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/screens/clubs_screen.dart';
import 'package:pulsepath/screens/group_ride_screen.dart';
import 'package:pulsepath/services/club_service.dart';
import 'package:pulsepath/services/group_ride_service.dart';
import 'package:pulsepath/services/group_workout_navigation.dart';
import 'package:pulsepath/widgets/group_invitation_card.dart';
import 'package:pulsepath/ui/app_theme.dart';
import 'package:pulsepath/config/app_variant.dart';

import 'group_coordination_test.dart' show FakeCoordination, me, room;

class TestClubs extends ClubService {
  bool failSend = false, revokeAccess = false;
  final sent = <Map<String, dynamic>>[];
  final snapshotData = <String, dynamic>{
    'id': 'club',
    'name': 'Вело Томск',
    'description': 'Встречи по выходным',
    'member': true,
    'is_open': false,
    'role': 'owner',
    'members': [
      {'user_id': me, 'username': 'Сергей', 'role': 'owner'},
    ],
    'messages': <Map<String, dynamic>>[],
    'events': <Map<String, dynamic>>[],
  };
  @override
  String? get userId => me;
  @override
  Future<List<Map<String, dynamic>>> home() async => [
    {...snapshotData, 'members_count': 1},
    {
      'id': 'open',
      'name': 'Беговой клуб',
      'description': 'В городе',
      'member': false,
      'is_open': true,
      'members_count': 3,
    },
  ];
  @override
  Future<Map<String, dynamic>> snapshot(String id) async {
    if (revokeAccess)
      throw const ClubException('Доступ закрыт', accessLost: true);
    return Map.from(snapshotData);
  }

  @override
  Future<dynamic> action(
    String action, {
    String? club,
    Map<String, dynamic> data = const {},
  }) async {
    if (action == 'message') {
      sent.add(Map.from(data));
      if (failSend) throw const ClubException('Проверьте интернет');
      (snapshotData['messages'] as List).add({
        'id': data['id'],
        'body': data['body'],
        'sender_id': me,
        'username': 'Сергей',
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    return Map.from(snapshotData);
  }
}

class InviteGroup extends FakeCoordination {
  final actions = <String>[];
  String status = 'active';
  bool fail = false;
  @override
  Future<Map<String, dynamic>> invitation(
    String id, {
    String action = 'view',
    bool replace = false,
  }) async {
    actions.add(action);
    if (fail) throw const GroupRideException('Приглашение больше недоступно');
    if (action == 'accept') status = 'joined';
    return {
      'status': status,
      'title': 'Поездка с другом',
      'sender_id': 'friend',
      'receiver_id': me,
      'members_count': 2,
    };
  }
}

void main() {
  if (const bool.fromEnvironment('CAPTURE_CLUBS')) {
    testWidgets('capture club pages and invitation lobby', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        for (final font in {
          'ClubCapture': 'C:/Windows/Fonts/arial.ttf',
          'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
      });
      for (final brightness in Brightness.values) {
        final service = TestClubs();
        (service.snapshotData['messages'] as List).addAll(
          <Map<String, dynamic>>[
            {
              'id': 'greeting',
              'body': 'В субботу встречаемся у парка. Кто с нами?',
              'username': 'Мария',
              'sender_id': 'friend',
              'created_at': DateTime.now().toIso8601String(),
            },
            {
              'id': 'ride',
              'body': 'Приглашаю на совместную тренировку',
              'username': 'Сергей',
              'sender_id': me,
              'created_at': DateTime.now().toIso8601String(),
              'ride_id': room,
              'ride_open': true,
            },
          ],
        );
        (service.snapshotData['events'] as List).add({
          'id': 'event',
          'title': 'Субботняя прогулка',
          'description': 'Встречаемся у главного входа в парк. Спокойный темп, около часа в пути.',
          'starts_at': DateTime.now()
              .add(const Duration(days: 2))
              .toIso8601String(),
          'attendees': [
            {'user_id': me, 'username': 'Сергей'},
          ],
          'attending': true,
        });
        for (final page in {
          'clubs': ClubsScreen(service: service),
          'club': ClubDetailScreen(id: 'club', service: service),
          'lobby': GroupRideScreen(service: FakeCoordination()),
        }.entries) {
          final key = GlobalKey();
          final theme = pulsePathTheme(brightness: brightness);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'ClubCapture'),
              ),
              home: RepaintBoundary(key: key, child: page.value),
            ),
          );
          await tester.pumpAndSettle();
          Future<void> capture(String name) async {
            await tester.runAsync(() async {
              final img =
                  await (key.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await img.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final dir = Directory('audit/club-previews')
                ..createSync(recursive: true);
              await File('${dir.path}/$name-${brightness.name}.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
              img.dispose();
            });
          }

          await capture(page.key);
          if (page.key == 'club') {
            await tester.tap(find.text('События'));
            await tester.pumpAndSettle();
            await capture('club-events');
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      }
    });
  }
  tearDown(() => GroupWorkoutNavigation.instance.consume());
  testWidgets(
    'club discovery keeps private membership distinct from open clubs',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ClubsScreen(service: TestClubs())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Вело Томск'), findsOneWidget);
      expect(find.text('Беговой клуб'), findsNothing);
      await tester.tap(find.text('Найти клуб'));
      await tester.pumpAndSettle();
      expect(find.text('Беговой клуб'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Томск');
      await tester.pumpAndSettle();
      expect(find.text('Беговой клуб'), findsNothing);
    },
  );
  testWidgets(
    'failed club message retains text and reuses the same id on retry',
    (tester) async {
      final service = TestClubs()..failSend = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ClubDetailScreen(id: 'club', service: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Жду у парка');
      await tester.tap(find.byTooltip('Отправить'));
      await tester.pumpAndSettle();
      expect(find.text('Жду у парка'), findsOneWidget);
      service.failSend = false;
      await tester.tap(find.byTooltip('Отправить'));
      await tester.pumpAndSettle();
      expect(service.sent.length, 2);
      expect(service.sent[0]['id'], service.sent[1]['id']);
      expect(find.text('Жду у парка'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('revoked membership clears the visible private chat', (
    tester,
  ) async {
    final service = TestClubs();
    (service.snapshotData['messages'] as List).add({
      'id': 'one',
      'body': 'Закрытый текст',
      'sender_id': me,
      'created_at': DateTime.now().toIso8601String(),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ClubDetailScreen(id: 'club', service: service),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Закрытый текст'), findsOneWidget);
    service.revokeAccess = true;
    await tester.tap(find.byTooltip('Обновить'));
    await tester.pumpAndSettle();
    expect(find.text('Закрытый текст'), findsNothing);
    expect(find.text('Доступ закрыт'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'club tabs and lobby fit 320px with large text ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Widget app(Widget child) => MaterialApp(
          theme: pulsePathTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: child,
        );
        await tester.pumpWidget(
          app(ClubDetailScreen(id: 'club', service: TestClubs())),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('События'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Участники'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (AppVariant.uiBeta) {
          await tester.pumpWidget(
            app(GroupRideScreen(service: FakeCoordination())),
          );
          await tester.pumpAndSettle();
          expect(find.text('Настроить тренировку'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'accepting invitation requests normal preparation and never starts recording',
    (tester) async {
      final group = InviteGroup();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      GroupInvitationDetails(id: 'invite', service: group),
                ),
                child: const Text('Приглашение'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Приглашение'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Принять и настроить тренировку'));
      await tester.pumpAndSettle();
      expect(group.actions, ['view', 'accept']);
      expect(GroupWorkoutNavigation.instance.roomId, room);
      expect(GroupWorkoutNavigation.instance.userId, me);
      expect(group.signalCalls, 0);
      expect(group.readyCalls, 0);
    },
    skip: !AppVariant.uiBeta,
  );
  testWidgets('unavailable invitation does not navigate to preparation', (
    tester,
  ) async {
    final group = InviteGroup()..fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupInvitationDetails(id: 'invite', service: group),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Приглашение больше недоступно'), findsOneWidget);
    expect(GroupWorkoutNavigation.instance.roomId, isNull);
  });
}
