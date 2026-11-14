import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:pulsepath/screens/route_builder_screen.dart';
import 'package:pulsepath/screens/route_geometry_editor_screen.dart';
import 'package:pulsepath/models/route_edit_state.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';

import 'support/main_map_test_host.dart';

class RejectingDraftStore extends InMemorySharedPreferencesStore {
  RejectingDraftStore(String raw)
    : super.withData({'flutter.route_planner_draft_v1_guest': raw});
  bool reject = false;
  @override
  Future<bool> setValue(String type, String key, Object value) async =>
      reject && key.contains('route_planner_draft')
      ? false
      : super.setValue(type, key, value);
}

// Regression coverage for draft preservation using synthetic data only.
void main() {
  const key = 'route_planner_draft_v1_guest';
  String draft({bool roads = true}) => jsonEncode({
    'points': [
      [56.0, 85.0],
      [56.01, 85.01],
    ],
    'labels': ['Synthetic start', 'Synthetic finish'],
    'roads': roads,
    'activity': 'cycling',
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({key: draft()});
    SavedRoutesRepository.resetInstancesForTesting();
  });
  Future<void> open(WidgetTester t, {bool host = false}) async {
    if (host) {
      await t.pumpWidget(
        MaterialApp(
          home: MainMapTestHost(
            child: Builder(
              builder: (ctx) => Center(
                child: FilledButton(
                  onPressed: () => Navigator.push(
                    ctx,
                    MaterialPageRoute(
                      builder: (_) => const RouteBuilderScreen(
                        initialCenter: LatLng(56, 85),
                      ),
                    ),
                  ),
                  child: const Text('Open audit planner'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open audit planner'));
    } else {
      await t.pumpWidget(
        const MaterialApp(
          home: RouteBuilderScreen(initialCenter: LatLng(56, 85)),
        ),
      );
    }
    await t.pumpAndSettle();
    expect(find.text('Продолжить черновик'), findsOneWidget);
  }

  testWidgets('R1: mode is disabled until the existing draft is recovered', (
    t,
  ) async {
    await open(t);
    final control = find.widgetWithText(ChoiceChip, 'Вручную');
    await t.ensureVisible(control);
    await t.tap(control);
    await t.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect((jsonDecode(prefs.getString(key)!) as Map)['points'], hasLength(2));
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      const MaterialApp(
        home: RouteBuilderScreen(initialCenter: LatLng(56, 85)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Продолжить черновик'), findsOneWidget);
  });
  testWidgets(
    'R2: starting over requires confirmation and Cancel preserves the draft',
    (t) async {
      await open(t);
      final action = find.text('Начать новый маршрут');
      await t.ensureVisible(action);
      await t.tap(action);
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        (jsonDecode((await SharedPreferences.getInstance()).getString(key)!)
            as Map)['points'],
        hasLength(2),
      );
      await t.tap(find.text('Вернуться'));
      await t.pumpAndSettle();
      expect(find.text('Продолжить черновик'), findsOneWidget);
    },
  );
  testWidgets(
    'R3: an unchanged road plan copy preserves estimate and anchors',
    (t) async {
      final points = [
        const LatLng(56, 85),
        const LatLng(56.01, 85.01),
        const LatLng(56.02, 85.02),
      ];
      final source = RouteEditState(
        points,
        estimatedSeconds: 600,
        controls: [points.first, points.last],
      ).plannedCopy(title: 'Road plan', activity: ActivityType.cycling);
      await t.pumpWidget(
        MaterialApp(home: RouteGeometryEditorScreen(source: source)),
      );
      await t.pumpAndSettle();
      final save = find.text('Сохранить отдельный маршрут');
      await t.ensureVisible(save);
      await t.tap(save);
      await t.pumpAndSettle();
      final saved = SavedRoutesRepository().savedRoutes.single;
      expect(saved.routePoints, source.routePoints);
      expect(saved.durationSeconds, 600);
      expect(saved.planningPoints, [points.first, points.last]);
    },
  );
  testWidgets(
    'R4: failed draft persistence blocks exit and never promises recovery',
    (t) async {
      final store = RejectingDraftStore(draft(roads: false));
      SharedPreferencesStorePlatform.instance = store;
      await open(t, host: true);
      await t.tap(find.text('Продолжить черновик'));
      await t.pumpAndSettle();
      store.reject = true;
      final remove = find.byTooltip('Убрать финиш');
      await t.ensureVisible(remove);
      await t.tap(remove);
      await t.pumpAndSettle();
      final durable = (await store.getAll())['flutter.$key'] as String;
      expect((jsonDecode(durable) as Map)['points'], hasLength(2));
      for (
        var i = 0;
        i < 3 && find.byType(AlertDialog).evaluate().isEmpty;
        i++
      ) {
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
      }
      expect(find.text('Черновик ещё не сохранён'), findsOneWidget);
      expect(find.text('Выйти с черновиком'), findsNothing);
    },
  );
}
