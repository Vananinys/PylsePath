import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/screens/public_profile_screen.dart';
import 'package:pulsepath/widgets/public_profile_dashboard.dart';
import 'package:pulsepath/ui/app_theme.dart';
import 'package:pulsepath/models/friend_profile.dart';

void main() {
  const me = '00000000-0000-4000-8000-000000000001';
  const friend = '00000000-0000-4000-8000-000000000002';
  var friends = true, requested = false, postsFail = false;
  var requestsSent = 0;
  final paths = <String>[];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://profile-test.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        paths.add(path);
        Object body = [];
        var code = 200;
        if (path.endsWith('/token')) {
          String part(Object v) =>
              base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
          body = {
            'access_token':
                '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test-only',
            'user': {
              'id': me,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.invalid',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-01-01T00:00:00Z',
            },
          };
        } else if (path.endsWith('/public_profiles')) {
          body = [
            {
              'id': friend,
              'username': 'Александр — длинное имя участника',
              'city': 'Томск',
              'preferred_riding_type': 'road',
            },
          ];
        } else if (path.endsWith('/friends')) {
          body = friends
              ? [
                  {'friend_id': friend},
                ]
              : [];
        } else if (path.endsWith('/friend_requests')) {
          if (request.method == 'POST') {
            requestsSent++;
            requested = true;
            code = 201;
          }
          body = requested
              ? [
                  {
                    'id': 'request',
                    'from_user': me,
                    'to_user': friend,
                    'created_at': '2026-11-01T00:00:00Z',
                  },
                ]
              : [];
        } else if (path.endsWith('/get_profile_activity')) {
          body = {'day': '2026-11-01', 'visible': false};
        } else if (path.endsWith('/community_moderation_status')) {
          body = {};
        } else if (path.endsWith('/community_posts') && postsFail) {
          code = 400;
          body = {'message': 'test unavailable'};
        }
        return http.Response(
          jsonEncode(body),
          code,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: 'test@example.invalid',
      password: 'test-only',
    );
  });
  tearDownAll(() async => Supabase.instance.dispose());
  setUp(() {
    friends = true;
    requested = false;
    postsFail = false;
    requestsSent = 0;
    paths.clear();
  });

  final captureKey = GlobalKey();
  Future<void> open(
    WidgetTester tester,
    Brightness brightness, {
    bool capture = false,
  }) async {
    tester.view.physicalSize = capture
        ? const Size(390, 1000)
        : const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: capture
            ? pulsePathTheme(brightness: brightness).copyWith(
                textTheme: pulsePathTheme(brightness: brightness).textTheme
                    .apply(fontFamily: 'Segoe UI'),
              )
            : pulsePathTheme(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(capture ? 1 : 2)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: const PublicProfileScreen(userId: friend),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PublicProfileDashboard), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  Future<void> tab(WidgetTester tester, String label) async {
    final target = find.widgetWithText(Tab, label);
    if (tester.getCenter(target).dy > 700) {
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -700));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final brightness in Brightness.values) {
    if (const bool.fromEnvironment('CAPTURE_PUBLIC_PROFILE')) {
      testWidgets('Public profile preview $brightness', (tester) async {
        await tester.runAsync(() async {
          for (final entry in {
            'Segoe UI': 'C:/Windows/Fonts/segoeui.ttf',
            'MaterialIcons': 'C:/src/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
          }.entries) {
            await (FontLoader(entry.key)..addFont(
                  File(entry.value).readAsBytes().then(ByteData.sublistView),
                ))
                .load();
          }
        });
        await open(tester, brightness, capture: true);
        await tester.runAsync(() async {
          final image =
              await (captureKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('audit/2026-11-01/profile/public-${brightness.name}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
    testWidgets(
      'Actual friend profile sections and privacy at 320px/200% $brightness',
      (tester) async {
        await open(tester, brightness);
        final message = find.text('Написать сообщение');
        await tester.ensureVisible(message);
        expect(message, findsOneWidget);
        expect(find.text('Пригласить в совместный заезд'), findsOneWidget);
        expect(find.text('Добавить в друзья'), findsNothing);
        expect(find.text('Вес'), findsNothing);
        expect(find.text('Возраст'), findsNothing);
        await tab(tester, 'Активность');
        expect(
          find.text('Пользователь скрыл статистику активности'),
          findsOneWidget,
        );
        await tab(tester, 'Гараж');
        expect(
          find.text('Пользователь пока не опубликовал велосипеды'),
          findsOneWidget,
        );
        await tab(tester, 'Публикации');
        expect(find.text('Постов пока нет'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Friend request is explicit and waits for acceptance', (
    tester,
  ) async {
    friends = false;
    await open(tester, Brightness.light);
    final button = find.text('Добавить в друзья');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(requestsSent, 1);
    expect(
      find.text('Заявка в друзья отправлена. Ожидаем подтверждения участника.'),
      findsOneWidget,
    );
    expect(find.text('Написать сообщение'), findsNothing);
    expect(paths.any((p) => p.contains('group_')), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Posts failure stays an error and can be retried', (
    tester,
  ) async {
    postsFail = true;
    await open(tester, Brightness.dark);
    await tab(tester, 'Публикации');
    expect(find.text('Публикации не загрузились'), findsOneWidget);
    expect(find.text('Постов пока нет'), findsNothing);
    postsFail = false;
    await tester.ensureVisible(find.text('Повторить'));
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Постов пока нет'), findsOneWidget);
  });

  testWidgets('Pulling down reloads a preloaded public profile', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PublicProfileScreen(
          userId: friend,
          preloaded: FriendProfile(id: friend, username: 'Старое имя'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Старое имя'), findsOneWidget);
    expect(find.byTooltip('Обновить профиль'), findsNothing);
    await tester.drag(find.byType(NestedScrollView), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(find.text('Александр — длинное имя участника'), findsOneWidget);
    expect(
      paths.where((path) => path.endsWith('/public_profiles')),
      isNotEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
