import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '00000000-0000-4000-8000-000000000001';
  final writes = <Map<String, dynamic>>[];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://position-test.example.invalid',
      publishableKey: 'test-only',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
          String part(Object value) => base64Url
              .encode(utf8.encode(jsonEncode(value)))
              .replaceAll('=', '');
          return http.Response(
            jsonEncode({
              'access_token':
                  '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': exp})}.signature',
              'token_type': 'bearer',
              'expires_in': 3600,
              'refresh_token': 'fake',
              'user': {
                'id': me,
                'aud': 'authenticated',
                'role': 'authenticated',
                'email': 'test@example.invalid',
                'app_metadata': {},
                'user_metadata': {},
                'created_at': '2026-10-17T00:00:00Z',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/live_positions')) {
          writes.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('', 201, request: request);
        }
        return http.Response(
          '[]',
          200,
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
  tearDownAll(() => Supabase.instance.dispose());
  setUp(writes.clear);
  Position fix() => Position(
    latitude: 56.48,
    longitude: 84.95,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 1,
    heading: 0,
    headingAccuracy: 1,
    speed: 0,
    speedAccuracy: 1,
  );

  test('An explicitly enabled fresh GPS fix is shared while app is open without starting a workout', () async {
    final controller = MapNavigationController()..setShareLivePosition(true);
    controller.applyGpsSampleForTesting(fix());
    await Future<void>.delayed(Duration.zero);
    expect(controller.isWorkoutActive, isFalse);
    expect(writes, hasLength(1));
    expect(writes.single['latitude'], 56.48);
    expect(writes.single['activity'], 'idle');
    controller.dispose();
  });
  test(
    'Sharing disabled or app in background without workout does not publish',
    () async {
      final hidden = MapNavigationController()..setShareLivePosition(false);
      hidden.applyGpsSampleForTesting(fix());
      await Future<void>.delayed(Duration.zero);
      expect(writes, isEmpty);
      hidden.dispose();
      final background = MapNavigationController()
        ..setShareLivePosition(true)
        ..setSharingForeground(false);
      background.applyGpsSampleForTesting(fix());
      await Future<void>.delayed(Duration.zero);
      expect(writes, isEmpty);
      background.dispose();
    },
  );
  test(
    'Fresh default controller never publishes location without opt in',
    () async {
      final controller = MapNavigationController();
      expect(controller.shareLivePosition, isFalse);
      controller.applyGpsSampleForTesting(fix());
      await Future<void>.delayed(Duration.zero);
      expect(writes, isEmpty);
      controller.dispose();
    },
  );
}
