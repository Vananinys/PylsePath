import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pulsepath/widgets/owner_award_management.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/services/owner_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://owner.example.invalid',
      publishableKey: 'synthetic',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode([
            {
              'id': 'synthetic-user',
              'username': 'Тест',
              'total_count': 1,
              'award_key': 'builtin:test',
              'label': 'Тест',
              'icon': '🏅',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      ),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  test(
    'Search RPC returns typed users instead of a runtime cast failure',
    () async {
      expect(
        (await OwnerService().rewardUsers('Тест')).single['username'],
        'Тест',
      );
    },
  );
  test(
    'Builtin RPC does not prevent initialization of award management',
    () async {
      expect(
        (await OwnerService().builtinAwards()).single['key'],
        'builtin:test',
      );
    },
  );
  test('History RPC returns typed records', () async {
    expect(
      (await OwnerService().awardHistory()).single['id'],
      'synthetic-user',
    );
  });
  testWidgets(
    'Changing search immediately prevents issuing to the old recipient',
    (tester) async {
      final service = FakeOwner();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OwnerAwardManagement(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      final grant = find.widgetWithText(FilledButton, 'Выдать пользователю');
      expect(tester.widget<FilledButton>(grant).onPressed, isNotNull);
      await tester.enterText(find.byType(TextField).first, 'Другой');
      await tester.pump();
      expect(tester.widget<FilledButton>(grant).onPressed, isNull);
      await tester.pump(const Duration(milliseconds: 400));
      service.search.complete([]);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(grant).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class FakeOwner extends OwnerService {
  final search = Completer<List<Map<String, dynamic>>>();
  @override
  Future<List<Map<String, dynamic>>> titles({
    bool includeInactive = false,
  }) async => [];
  @override
  Future<List<CatalogAchievement>> catalog({
    bool includeInactive = false,
  }) async => [];
  @override
  Future<List<Map<String, dynamic>>> builtinAwards() async => [
    {
      'kind': 'achievement',
      'key': 'builtin:test',
      'title': 'Награда',
      'icon': '🏅',
    },
  ];
  @override
  Future<List<Map<String, dynamic>>> rewardUsers([String query = '']) async =>
      query.isEmpty
      ? [
          {'id': 'synthetic-user', 'username': 'Первый', 'total_count': 1},
        ]
      : search.future;
  @override
  Future<List<Map<String, dynamic>>> recipientAwards(String userId) async => [];
}
