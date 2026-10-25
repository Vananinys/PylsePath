// Юнит-тесты арифметики периодов прогресса и парсинга данных заезда.
import 'package:flutter_test/flutter_test.dart';

import 'package:pulsepath/models/progress_period.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:latlong2/latlong.dart';

const _point = LatLng(52.52, 13.405);

SavedRoute _route({
  String title = 'Тренировка',
  String distance = '0 км',
  DateTime? createdAt,
}) {
  return SavedRoute(
    title: title,
    distance: distance,
    duration: '30 мин',
    surfaceSummary: 'Тест',
    finishPoint: _point,
    routePoints: const [_point],
    activityType: ActivityType.mountainBiking,
    createdAt: createdAt,
  );
}

void main() {
  group('ProgressPeriod.windowStart', () {
    // Среда, 11 марта 2026.
    final wednesday = DateTime(2026, 3, 11, 14, 30);

    test('день начинается с полуночи', () {
      expect(ProgressPeriod.day.windowStart(wednesday), DateTime(2026, 3, 11));
    });

    test('неделя начинается с понедельника', () {
      expect(ProgressPeriod.week.windowStart(wednesday), DateTime(2026, 3, 9));
    });

    test('понедельник — начало своей же недели', () {
      final monday = DateTime(2026, 3, 9, 8, 0);
      expect(ProgressPeriod.week.windowStart(monday), DateTime(2026, 3, 9));
    });

    test('воскресенье относится к неделе с прошлого понедельника', () {
      final sunday = DateTime(2026, 3, 15, 23, 59);
      expect(ProgressPeriod.week.windowStart(sunday), DateTime(2026, 3, 9));
    });

    test('начало недели корректно переезжает в прошлый месяц', () {
      // 1 марта 2026 — воскресенье, значит неделя началась 23 февраля.
      final marchFirst = DateTime(2026, 3, 1, 10, 0);
      expect(
        ProgressPeriod.week.windowStart(marchFirst),
        DateTime(2026, 2, 23),
      );
    });

    test('месяц начинается с 1-го числа', () {
      expect(ProgressPeriod.month.windowStart(wednesday), DateTime(2026, 3, 1));
    });

    test('год начинается с 1 января', () {
      expect(ProgressPeriod.year.windowStart(wednesday), DateTime(2026, 1, 1));
    });
  });

  group('ProgressPeriod.contains', () {
    final now = DateTime(2026, 3, 11, 14, 30);

    test('заезд ровно в начале окна считается', () {
      expect(ProgressPeriod.day.contains(DateTime(2026, 3, 11), now), isTrue);
      expect(ProgressPeriod.week.contains(DateTime(2026, 3, 9), now), isTrue);
      expect(ProgressPeriod.month.contains(DateTime(2026, 3, 1), now), isTrue);
      expect(ProgressPeriod.year.contains(DateTime(2026, 1, 1), now), isTrue);
    });

    test('заезд за миг до начала окна не считается', () {
      expect(
        ProgressPeriod.day.contains(
          DateTime(2026, 3, 10, 23, 59, 59, 999),
          now,
        ),
        isFalse,
      );
      expect(
        ProgressPeriod.week.contains(DateTime(2026, 3, 8, 23, 59), now),
        isFalse,
      );
      expect(
        ProgressPeriod.month.contains(DateTime(2026, 2, 28, 23, 59), now),
        isFalse,
      );
      expect(
        ProgressPeriod.year.contains(DateTime(2025, 12, 31, 23, 59), now),
        isFalse,
      );
    });

    test('окна вложены: день ⊆ неделя ⊆ месяц ⊆ год', () {
      final when = DateTime(2026, 3, 10, 12, 0); // вчера
      expect(ProgressPeriod.day.contains(when, now), isFalse);
      expect(ProgressPeriod.week.contains(when, now), isTrue);
      expect(ProgressPeriod.month.contains(when, now), isTrue);
      expect(ProgressPeriod.year.contains(when, now), isTrue);
    });

    test('дата «из будущего» (сбитые часы) попадает в период', () {
      expect(
        ProgressPeriod.day.contains(DateTime(2026, 3, 11, 23, 0), now),
        isTrue,
      );
    });
  });

  group('ProgressPeriod метаданные', () {
    test('у каждого периода свой ключ хранилища', () {
      final keys = ProgressPeriod.values.map((p) => p.storageKey).toSet();
      expect(keys.length, ProgressPeriod.values.length);
    });

    test('дефолтные цели лежат в допустимых границах', () {
      for (final period in ProgressPeriod.values) {
        expect(
          period.defaultGoalKm,
          greaterThanOrEqualTo(ProgressPeriod.minGoalKm),
        );
        expect(
          period.defaultGoalKm,
          lessThanOrEqualTo(ProgressPeriod.maxGoalKm),
        );
      }
    });

    test('границы цели: 10..5000 км', () {
      expect(ProgressPeriod.minGoalKm, 10);
      expect(ProgressPeriod.maxGoalKm, 5000);
    });
  });

  group('SavedRoute.distanceKm', () {
    test(
      'километры',
      () => expect(_route(distance: '12.5 км').distanceKm, 12.5),
    );
    test(
      'запятая как разделитель',
      () => expect(_route(distance: '3,83 км').distanceKm, 3.83),
    );
    test(
      'метры переводятся в километры',
      () => expect(_route(distance: '3830 м').distanceKm, 3.83),
    );
    test('без единиц', () => expect(_route(distance: '7.5').distanceKm, 7.5));
    test('ноль', () => expect(_route(distance: '0 км').distanceKm, 0.0));
    test(
      'мусор не роняет расчёт',
      () => expect(_route(distance: '—').distanceKm, 0.0),
    );
    test('пустая строка', () => expect(_route(distance: '').distanceKm, 0.0));
  });

  group('SavedRoute.dateTime', () {
    test('берётся из createdAt', () {
      final created = DateTime(2026, 5, 4, 9, 15);
      expect(_route(createdAt: created).dateTime, created);
    });

    test('у старых записей дата достаётся из заголовка', () {
      final route = _route(title: 'Тренировка 2026-09-30 15:41');
      expect(route.dateTime, DateTime(2026, 9, 30, 15, 41));
    });

    test('createdAt важнее заголовка', () {
      final created = DateTime(2026, 1, 2, 3, 4);
      final route = _route(
        title: 'Тренировка 2020-01-01 00:00',
        createdAt: created,
      );
      expect(route.dateTime, created);
    });

    test('без даты вообще — считаем свежей', () {
      final route = _route(title: 'Просто маршрут');
      final diff = DateTime.now().difference(route.dateTime).abs();
      expect(diff.inMinutes, lessThan(1));
    });

    test('JSON-раундтрип сохраняет дату', () {
      final created = DateTime(2026, 7, 8, 19, 30);
      final restored = SavedRoute.fromJson(
        _route(createdAt: created, distance: '5 км').toJson(),
      );
      expect(restored.dateTime, created);
      expect(restored.distanceKm, 5.0);
    });

    test('старый JSON без createdAt читается', () {
      final json = _route(title: 'Тренировка 2026-04-05 08:10').toJson()
        ..remove('createdAt');
      expect(SavedRoute.fromJson(json).dateTime, DateTime(2026, 4, 5, 8, 10));
    });
  });
}
