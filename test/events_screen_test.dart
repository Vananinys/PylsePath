import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulsepath/screens/events_screen.dart';
import 'package:pulsepath/services/events_service.dart';

class FakeEvents extends EventsService {
  bool joined = false;
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    calls.add(action);
    if (action == 'join') {
      joined = true;
      return {'ok': true};
    }
    return {
      'owner': false,
      'creator': false,
      'moderator': false,
      'xp': 0,
      'rewards': [],
      'items': [
        {
          'id': 'event-1',
          'creator_id': 'different-owner',
          'kind': 'beta',
          'title': 'Тестируем PulsePath',
          'description': 'Добровольный тест',
          'xp': 50,
          'badge': 'Исследователь',
          'ends_at': DateTime.now()
              .add(const Duration(days: 1))
              .toIso8601String(),
          'joined': joined,
          'earned': false,
        },
      ],
    };
  }
}

void main() {
  testWidgets('Member can join and see survey without staff controls', (
    tester,
  ) async {
    final service = FakeEvents();
    await tester.pumpWidget(MaterialApp(home: EventsScreen(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('Тестируем PulsePath'), findsOneWidget);
    expect(find.text('Создать'), findsNothing);
    expect(find.text('Ответы'), findsNothing);
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Участвовать'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Участвовать'));
    await tester.pumpAndSettle();
    expect(service.calls, contains('join'));
    expect(find.text('Пройти опрос'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
