import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/config/app_variant.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/screens/login_screen.dart';
import 'package:pulsepath/screens/route_places_screen.dart';
import 'package:pulsepath/services/app_update_service.dart';
import 'package:pulsepath/ui/app_appearance.dart';
import 'package:pulsepath/ui/app_theme.dart';
import 'package:pulsepath/widgets/navigation_menu.dart';
import 'package:pulsepath/widgets/route_details_bottom_sheet.dart';
import 'package:pulsepath/widgets/settings_hub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('appearance persists and unknown values use the system theme', () async {
    final appearance = AppAppearance();
    await appearance.load();
    expect(appearance.mode, ThemeMode.system);
    await appearance.setMode(ThemeMode.dark);
    final restored = AppAppearance();
    await restored.load();
    expect(restored.mode, ThemeMode.dark);
    SharedPreferences.setMockInitialValues({
      AppAppearance.preferenceKey: 'invalid',
    });
    await restored.load();
    expect(restored.mode, ThemeMode.system);
    appearance.dispose();
    restored.dispose();
  });

  test(
    'UI beta locks its channel without changing regular preferences',
    () async {
      expect(
        await AppUpdateService.selectedChannel(),
        AppVariant.uiBeta ? UpdateChannel.beta : UpdateChannel.stable,
      );
      if (AppVariant.uiBeta) {
        await expectLater(
          AppUpdateService.selectChannel(UpdateChannel.stable),
          throwsStateError,
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'app_update_channel_v1',
          ),
          isNull,
        );
      }
    },
  );

  for (final brightness in Brightness.values) {
    test('theme text contrast is accessible in ${brightness.name}', () {
      final colors = pulsePathTheme(brightness: brightness).colorScheme;
      double contrast(Color a, Color b) {
        final x = a.computeLuminance(), y = b.computeLuminance();
        return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
      }

      expect(
        contrast(colors.onSurface, colors.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.onSurfaceVariant, colors.surfaceContainerLow),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.onPrimary, colors.primary),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets(
      'menu search keeps real callbacks at 320 px, ${brightness.name}',
      (tester) async {
        resize(tester, const Size(320, 800));
        var opened = false;
        await tester.pumpWidget(
          shell(
            brightness,
            NavigationMenu(
              children: [
                ListTile(
                  title: const Text('Сохранённые маршруты'),
                  subtitle: const Text('Готовые пути'),
                  onTap: () => opened = true,
                ),
                ListTile(title: const Text('Сообщения'), onTap: () {}),
              ],
            ),
            scale: 2,
          ),
        );
        await tester.enterText(find.byType(TextField), 'пути');
        await tester.pumpAndSettle();
        expect(find.text('Сообщения'), findsNothing);
        await tester.tap(find.text('Сохранённые маршруты'));
        expect(opened, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('route sheet fits 320 px and 200% text in ${brightness.name}', (
      tester,
    ) async {
      resize(tester, const Size(320, 850));
      await tester.pumpWidget(shell(brightness, routeSheet(), scale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Нет данных'), findsWidgets);
    });
  }

  testWidgets('settings search finds voice and theme by task', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHub(
          summaries: const {
            'Внешний вид': 'Оформление',
            'Тренировки': 'Запись',
          },
          children: const [
            SettingsSectionHeading('Внешний вид'),
            AppearanceSetting(),
            SettingsSectionHeading('Тренировки'),
            Text('Голосовые подсказки'),
          ],
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'голос');
    await tester.pumpAndSettle();
    expect(find.text('Тренировки'), findsOneWidget);
    expect(find.text('Внешний вид'), findsNothing);
    await tester.tap(find.text('Тренировки'));
    await tester.pumpAndSettle();
    expect(find.text('Голосовые подсказки'), findsOneWidget);
  });

  testWidgets('places explanation scrolls at 320 px and 200% text', (
    tester,
  ) async {
    resize(tester, const Size(320, 640));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const RoutePlacesScreen(points: []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Найти места по маршруту'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme selector applies and persists a choice', (tester) async {
    await AppAppearance.instance.load();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: const AppearanceSetting())),
    );
    await tester.tap(find.text('Тема приложения'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тёмная'));
    await tester.pumpAndSettle();
    expect(AppAppearance.instance.mode, ThemeMode.dark);
    expect(
      (await SharedPreferences.getInstance()).getString(
        AppAppearance.preferenceKey,
      ),
      'dark',
    );
  });

  if (const bool.fromEnvironment('CAPTURE_UI')) {
    testWidgets('capture actual login and route widgets in both themes', (
      tester,
    ) async {
      resize(tester, const Size(390, 900));
      await tester.runAsync(() async {
        final loader = FontLoader('InterfaceCapture')
          ..addFont(
            File('C:/Windows/Fonts/arial.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          );
        await loader.load();
        await (FontLoader('MaterialIcons')..addFont(
              File(
                'C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      });
      for (final brightness in Brightness.values) {
        for (final entry in {
          'login': const LoginScreen(),
          'route': Scaffold(body: routeSheet()),
        }.entries) {
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: pulsePathTheme(brightness: brightness).copyWith(
                textTheme: pulsePathTheme(brightness: brightness).textTheme
                    .apply(fontFamily: 'InterfaceCapture'),
              ),
              home: RepaintBoundary(key: key, child: entry.value),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final dir = Directory('audit/interface-captures')
              ..createSync(recursive: true);
            await File('${dir.path}/${entry.key}-${brightness.name}.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    });
  }
}

void resize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget shell(Brightness brightness, Widget child, {double scale = 1}) =>
    MaterialApp(
      theme: pulsePathTheme(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: child),
      ),
    );

Widget routeSheet() => RouteDetailsBottomSheet(
  finishAddress: 'Парк у реки',
  finishPoint: null,
  selectedActivity: ActivityType.values.first,
  activityTypes: ActivityType.values,
  routeDistanceKm: null,
  routeDurationMin: null,
  elevationGainMeters: 0,
  elevationLossMeters: 0,
  surfaceInfo: null,
  isLoadingRoute: false,
  isBookmarked: false,
  isNavigating: false,
  onClearRoute: () {},
  onActivityChanged: (_) {},
  onToggleBookmark: () {},
  onToggleNavigation: () {},
  onShareRoute: () {},
  formatDuration: (_) => '30 мин',
  formatETA: (_) => 'Прибытие в 15:30',
  calculateCalories: () => 180,
);
