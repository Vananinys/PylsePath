// Этап 0: реестр модулей, пресеты и сквозная передача uiPreset/modulesEnabled
// через модель профиля и строку Supabase.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/data/ui_modules.dart';
import 'package:pulsepath/models/user_profile.dart';
import 'package:pulsepath/screens/settings_screen.dart';
import 'package:pulsepath/services/profile_sync_service.dart';
import 'package:pulsepath/state/profile_provider.dart';

UserProfile _profile({String? uiPreset, Set<String>? modules}) => UserProfile(
  weightKg: 70,
  heightCm: 175,
  age: 30,
  uiPreset: uiPreset,
  modulesEnabled: modules,
);

void main() {
  group('UiPreset', () {
    test('каждый пресет непуст и содержит базовый модуль history', () {
      for (final preset in UiPreset.values) {
        expect(preset.modules, isNotEmpty);
        expect(preset.modules, contains('history'));
      }
    });

    test('Геймер включает все известные модули, включая стикеры', () {
      expect(UiPreset.gamer.modules, UiModules.allIds);
      expect(UiPreset.gamer.modules, contains(UiModules.stickers));
    });

    test('остальные пресеты отключают игровые стикеры', () {
      expect(UiPreset.laconic.modules, isNot(contains(UiModules.stickers)));
      expect(UiPreset.athlete.modules, isNot(contains(UiModules.stickers)));
      expect(UiPreset.urban.modules, isNot(contains(UiModules.stickers)));
    });

    test('Состав пресетов соответствует мастер-плану', () {
      expect(UiPreset.laconic.modules, {'history'});
      expect(UiPreset.athlete.modules, {
        'saved_routes',
        'history',
        'achievements',
        'offline_maps',
        'garage',
      });
      expect(UiPreset.urban.modules, {
        'history',
        'chats',
        'community',
        'group_rides',
      });
    });

    test('fromId: известные id, null и мусор → laconic', () {
      expect(UiPreset.fromId('athlete'), UiPreset.athlete);
      expect(UiPreset.fromId(null), UiPreset.laconic);
      expect(UiPreset.fromId(''), UiPreset.laconic);
      expect(UiPreset.fromId('unknown'), UiPreset.laconic);
    });
  });

  group('effectiveEnabledModules', () {
    test('явный набор профиля приоритетнее пресета', () {
      final profile = _profile(uiPreset: 'gamer', modules: {'history'});
      expect(effectiveEnabledModules(profile), {'history'});
    });

    test('без ручного набора берётся набор пресета', () {
      expect(effectiveEnabledModules(_profile(uiPreset: 'urban')), {
        'history',
        'chats',
        'community',
        'group_rides',
      });
    });

    test('null-пресет без набора — Лаконичный (существующие пользователи)', () {
      expect(effectiveEnabledModules(_profile()), {'history'});
    });
  });

  group('UserProfile json', () {
    test('roundtrip сохраняет пресет и набор модулей', () {
      final profile = _profile(
        uiPreset: 'urban',
        modules: {'history', 'chats'},
      );
      final restored = UserProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );
      expect(restored.uiPreset, 'urban');
      expect(restored.modulesEnabled, {'history', 'chats'});
    });

    test('старые записи без новых полей читаются как null', () {
      final restored = UserProfile.fromJson({
        'weightKg': 70,
        'heightCm': 175,
        'age': 30,
      });
      expect(restored.uiPreset, isNull);
      expect(restored.modulesEnabled, isNull);
    });
  });

  group('ProfileSyncService', () {
    test('toRow пишет ui_preset и modules_enabled, когда они заданы', () {
      final row = ProfileSyncService.toRow(
        profile: _profile(uiPreset: 'gamer', modules: {'history'}),
        userId: '00000000-0000-0000-0000-000000000000',
      );
      expect(row['ui_preset'], 'gamer');
      expect(row['modules_enabled'], ['history']);
    });

    test('toRow не пишет null-значения (не затирает облако)', () {
      final row = ProfileSyncService.toRow(
        profile: _profile(),
        userId: '00000000-0000-0000-0000-000000000000',
      );
      expect(row.containsKey('ui_preset'), isFalse);
      expect(row.containsKey('modules_enabled'), isFalse);
    });

    test('profileFieldsFromRow читает jsonb-колонки', () {
      final fields = ProfileSyncService.profileFieldsFromRow({
        'ui_preset': 'athlete',
        'modules_enabled': ['garage', 'history'],
      });
      expect(fields['uiPreset'], 'athlete');
      expect(fields['modulesEnabled'], {'garage', 'history'});
    });

    test('profileFieldsFromRow без jsonb-колонок отдаёт null', () {
      final fields = ProfileSyncService.profileFieldsFromRow({});
      expect(fields['uiPreset'], isNull);
      expect(fields['modulesEnabled'], isNull);
    });
  });

  group('SettingsScreen', () {
    testWidgets('с провайдером показывает настройки модулей и не падает', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final provider = ProfileProvider();
      await provider.ensureLoaded();
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(provider: provider)),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.text('Внешний вид'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Кастомизация'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Модули приложения'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Модули приложения'));
      await tester.pumpAndSettle();
      expect(find.text('Соберите своё приложение'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Тренировочный центр и история'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      // Модули пресета по умолчанию (Лаконичный): история включена.
      final historySwitch = tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Тренировочный центр и история'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(historySwitch.value, isTrue);
    });

    testWidgets('без провайдера секция скрыта, экран работает', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));

      expect(find.text('Соберите своё приложение'), findsNothing);
      await tester.tap(find.text('Тренировки'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Подсказки и трансляция в фоне'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Подсказки и трансляция в фоне'), findsOneWidget);
    });
  });
}
