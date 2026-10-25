import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/screens/moderation_screen.dart';
import 'package:pulsepath/services/moderation_service.dart';
import 'package:pulsepath/widgets/moderation_dialogs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '11111111-1111-4111-8111-111111111111',
      other = '22222222-2222-4222-8222-222222222222';
  var moderator = true, banned = false, forbidden = false;
  final actions = <Map<String, dynamic>>[];
  var listCalls = 0;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://moderation-test.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        http.Response result(Object? body, {int code = 200}) => http.Response(
          jsonEncode(body),
          code,
          headers: {'content-type': 'application/json'},
          request: request,
        );
        if (request.url.path.endsWith('/token')) {
          String part(Object v) =>
              base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
          final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
          return result({
            'access_token':
                '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': exp})}.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test-only',
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'owner@example.invalid',
              'created_at': '2026-10-24T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          });
        }
        if (request.url.path.endsWith('/community_moderation_status'))
          return result({'is_moderator': moderator, 'is_banned': false});
        if (request.url.path.endsWith('/community_moderation_list')) {
          listCalls++;
          return result([
            {
              'id': other,
              'username': 'Rider',
              'is_banned': banned,
              'is_moderator': false,
              'reason': banned ? 'Spam' : null,
              'expires_at': null,
            },
          ]);
        }
        if (request.url.path.endsWith('/moderate_community_user') ||
            request.url.path.endsWith('/moderate_community_content')) {
          if (forbidden)
            return result({
              'message': 'Moderator access required',
              'code': '42501',
            }, code: 403);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          actions.add(body);
          banned = body['p_action'] == 'ban';
          return result(null);
        }
        return result([]);
      }),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'owner@example.invalid',
      password: 'test-only',
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  setUp(() {
    moderator = true;
    banned = false;
    forbidden = false;
    actions.clear();
    listCalls = 0;
  });
  test('status explains community scope without blocking workouts', () {
    final status = ModerationStatus.fromJson({
      'is_moderator': false,
      'is_banned': true,
      'reason': 'Spam',
      'expires_at': '2026-10-25T00:00:00Z',
    });
    expect(status.isBanned, isTrue);
    expect(status.banDescription, contains('Личные заезды доступны'));
    expect(status.banDescription, contains('Spam'));
  });
  test('ban and unban send only scoped moderation parameters', () async {
    final service = ModerationService();
    await service.ban(other, reason: '  Spam  ', hours: 24);
    await service.unban(other, reason: 'Appeal accepted');
    expect(actions.first, {
      'p_user_id': other,
      'p_action': 'ban',
      'p_reason': 'Spam',
      'p_hours': 24,
    });
    expect(actions.last['p_action'], 'unban');
  });
  test('server role rejection is surfaced to the user', () async {
    forbidden = true;
    await expectLater(
      ModerationService().ban(other, reason: 'Spam'),
      throwsA(
        isA<ModerationException>().having(
          (e) => e.message,
          'message',
          contains('только модератору'),
        ),
      ),
    );
    expect(actions, isEmpty);
  });
  testWidgets('ordinary user cannot open user list or ban controls', (
    tester,
  ) async {
    moderator = false;
    await tester.pumpWidget(const MaterialApp(home: ModerationScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Доступ только модераторам сообщества.'), findsOneWidget);
    expect(listCalls, 0);
    expect(find.text('Бан'), findsNothing);
  });
  testWidgets('ban requires a reason and supports an indefinite duration', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ModerationScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Бан'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Заблокировать'));
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
    expect(find.text('Укажите причину, минимум 3 символа'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'Repeated spam');
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Бессрочно').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Заблокировать'));
    await tester.pumpAndSettle();
    expect(actions.single['p_hours'], isNull);
    expect(actions.single['p_reason'], 'Repeated spam');
    expect(find.text('Снять бан'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('closing confirmation never sends a moderation action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModerationAction(context, contentId: other),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
  });
  testWidgets('moderation and ban dialog fit a narrow phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: const ModerationScreen(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Бан'));
    await tester.pumpAndSettle();
    expect(find.text('Заблокировать в сообществе?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
