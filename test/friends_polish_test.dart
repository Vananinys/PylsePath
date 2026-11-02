import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/screens/friends_screen.dart';
import 'package:pulsepath/services/friend_service.dart';
import 'package:pulsepath/models/friend_profile.dart';

class FakeFriends extends FriendService {
  @override
  String? get userId => 'me';
  bool failFriends = false;
  final searches = <String, Completer<List<FriendProfile>>>{};
  @override
  Future<List<FriendProfile>?> loadCachedFriends() async => null;
  @override
  Future<List<FriendProfile>> fetchFriends({bool strict = false}) async {
    if (failFriends) throw const FriendServiceException('offline');
    return [];
  }

  @override
  Future<List<FriendRequest>> fetchIncomingRequests({
    bool strict = false,
  }) async => [];
  @override
  Future<List<FriendRequest>> fetchOutgoingRequests({
    bool strict = false,
  }) async => [];
  @override
  Future<List<FriendProfile>> searchUsers(
    String query, {
    bool strict = false,
  }) => (searches[query] = Completer<List<FriendProfile>>()).future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> open(WidgetTester tester, FakeFriends service) async {
    await tester.pumpWidget(
      MaterialApp(home: FriendsScreen(friendService: service)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('friends failure does not become an empty list and retry works', (
    tester,
  ) async {
    final service = FakeFriends()..failFriends = true;
    await open(tester, service);
    await tester.tap(find.text('Друзья').first);
    await tester.pumpAndSettle();
    expect(find.text('Не удалось обновить друзей.'), findsOneWidget);
    expect(find.text('Друзей пока нет'), findsNothing);
    service.failFriends = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Друзей пока нет'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'search ignores late answers and clearing cancels pending results',
    (tester) async {
      final service = FakeFriends();
      await open(tester, service);
      await tester.ensureVisible(find.text('Поиск людей'));
      await tester.tap(find.text('Поиск людей'));
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      await tester.enterText(input, 'Ан');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(input, 'Антон');
      await tester.pump(const Duration(milliseconds: 400));
      service.searches['Антон']!.complete([
        FriendProfile(id: 'new', username: 'Новый результат'),
      ]);
      await tester.pumpAndSettle();
      service.searches['Ан']!.complete([
        FriendProfile(id: 'old', username: 'Старый результат'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Новый результат'), findsOneWidget);
      expect(find.text('Старый результат'), findsNothing);
      await tester.enterText(input, 'Ма');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(input, '');
      await tester.pump();
      service.searches['Ма']!.complete([
        FriendProfile(id: 'late', username: 'Поздний результат'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Поздний результат'), findsNothing);
      expect(find.text('Введите имя райдера'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('search errors have retry at 320px and 200%', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = FakeFriends();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: FriendsScreen(friendService: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Поиск людей'));
    await tester.tap(find.text('Поиск людей'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Тест');
    await tester.pump(const Duration(milliseconds: 400));
    service.searches['Тест']!.completeError(Exception('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Никого не нашли'), findsNothing);
    expect(find.text('Повторить'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
