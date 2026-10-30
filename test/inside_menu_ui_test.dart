import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/screens/events_screen.dart';
import 'package:pulsepath/services/events_service.dart';
import 'package:pulsepath/widgets/event_overview_card.dart';
import 'package:pulsepath/widgets/group_ride_dashboard.dart';
import 'package:pulsepath/ui/app_theme.dart';

import 'group_ride_flow_test.dart' show FlowGroup;

Map<String, dynamic> event({
  String kind = 'challenge',
  bool joined = true,
  bool earned = false,
  int days = 7,
}) => {
  'id': 'sample',
  'creator_id': 'staff',
  'kind': kind,
  'metric': kind == 'challenge' ? 'rides' : 'feedback',
  'title': kind == 'challenge'
      ? 'Три тренировки за неделю'
      : 'Помогите улучшить PulsePath',
  'description':
      'Двигайтесь в удобном темпе и сохраните результат. Участие добровольное.',
  'xp': 100,
  'badge': 'В движении',
  'target': 3,
  'starts_at': DateTime.now()
      .subtract(const Duration(days: 1))
      .toIso8601String(),
  'ends_at': DateTime.now().add(Duration(days: days)).toIso8601String(),
  'joined': joined,
  'earned': earned,
};

class MenuEvents extends EventsService {
  MenuEvents({this.creator = false});
  final bool creator;
  final actions = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    actions.add(action);
    return {
      'owner': false,
      'creator': creator,
      'moderator': false,
      'xp': 100,
      'rewards': [],
      'items': [
        event(),
        event(kind: 'beta', joined: false),
        {...event(days: -2), 'title': 'Прошлая встреча'},
      ],
    };
  }
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('event actions fit 320 px at 200%, ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var claims = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: pulsePathTheme(brightness: brightness),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: EventOverviewCard(
                  event: event(),
                  busy: false,
                  onJoin: () {},
                  onFeedback: () =>
                      fail('A workout challenge must not send a survey'),
                  onClaim: () => claims++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Пройти опрос'), findsNothing);
      await tester.ensureVisible(find.text('Проверить прогресс'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Проверить прогресс'));
      expect(claims, 1);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('expired and rewarded cards never offer another claim', (
    tester,
  ) async {
    for (final value in [event(days: -1), event(earned: true)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EventOverviewCard(
                event: value,
                busy: false,
                onJoin: () => fail('closed'),
                onFeedback: () => fail('closed'),
                onClaim: () => fail('closed'),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Проверить прогресс'), findsNothing);
      expect(find.text('Пройти опрос'), findsNothing);
    }
  });
  testWidgets('filters show actual participation and closed events', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: EventsScreen(service: MenuEvents())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Завершённые'));
    await tester.pumpAndSettle();
    expect(find.text('Прошлая встреча'), findsOneWidget);
    expect(find.text('Три тренировки за неделю'), findsNothing);
  });

  testWidgets('invalid event form keeps entered values and does not publish', (
    tester,
  ) async {
    final service = MenuEvents(creator: true);
    await tester.pumpWidget(MaterialApp(home: EventsScreen(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Событие'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Моя встреча');
    await tester.tap(find.text('Продолжить'));
    await tester.pumpAndSettle();
    expect(find.text('От 1 до 90 дней'), findsOneWidget);
    expect(find.text('Моя встреча'), findsOneWidget);
    expect(service.actions, isNot(contains('create')));
  });

  if (const bool.fromEnvironment('CAPTURE_MENUS')) {
    testWidgets('render event and group pages in both themes', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        for (final font in {
          'MenuCapture': 'C:/Windows/Fonts/arial.ttf',
          'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
      });
      for (final brightness in Brightness.values) {
        final group = FlowGroup()..activeRoomId = null;
        for (final page in {
          'events': EventsScreen(service: MenuEvents()),
          'group': GroupRideDashboard(
            service: group,
            busy: false,
            onCreate: () {},
            onJoin: () {},
            onInvite: () {},
            onRoute: () {},
            onClearRoute: () {},
            onLeave: () {},
            onTransfer: () {},
            onReturn: () {},
          ),
        }.entries) {
          final key = GlobalKey();
          final theme = pulsePathTheme(brightness: brightness);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'MenuCapture'),
              ),
              home: RepaintBoundary(key: key, child: page.value),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final folder = Directory('audit/menu-previews')
              ..createSync(recursive: true);
            await File('${folder.path}/${page.key}-${brightness.name}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
        group.dispose();
      }
    });
  }
}
