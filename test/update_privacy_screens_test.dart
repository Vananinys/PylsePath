import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/screens/app_versions_screen.dart';
import 'package:pulsepath/screens/usage_statistics_screen.dart';
import 'package:pulsepath/services/app_update_service.dart';
import 'package:pulsepath/services/usage_statistics.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'version archive fits narrow screen and beta requires explicit choice',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
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
          home: AppVersionsScreen(
            installedCode: 69,
            loadReleases: (channel) async => [
              AppRelease(
                versionCode: 67,
                versionName: '1.12.14',
                apkPath: 'android/67/pulsepath-67.apk',
                apkUrl: null,
                apkSha256: 'a' * 64,
                apkSizeBytes: 100,
                notes: 'Предыдущая стабильная версия',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Скачать старую версию'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Бета'));
      await tester.pumpAndSettle();
      expect(find.text('Участвовать в бета-тесте?'), findsOneWidget);
      expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await AppUpdateService.selectedChannel(), UpdateChannel.stable);
    },
  );
  testWidgets(
    'local counters are optional and no share is offered before data exists',
    (tester) async {
      final service = UsageStatistics(ownerResolver: () => 'widget-owner');
      await tester.pumpWidget(
        MaterialApp(home: UsageStatisticsScreen(service: service)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false,
      );
      await tester.tap(find.text('Вести локальные счётчики'));
      await tester.pumpAndSettle();
      expect(find.text('Разрешить локально'), findsOneWidget);
      expect((await service.snapshot())['enabled'], false);
      await tester.tap(find.text('Не включать'));
      await tester.pumpAndSettle();
      expect((await service.snapshot())['enabled'], false);
    },
  );
}
