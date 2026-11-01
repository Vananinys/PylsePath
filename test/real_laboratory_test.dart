import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pulsepath/widgets/laboratory_controls.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/controllers/map_navigation_controller.dart';
import 'package:pulsepath/services/laboratory_motion_source.dart';
import 'package:pulsepath/models/gps_signal.dart';
import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/data/user_scope.dart';
import 'package:latlong2/latlong.dart';

import 'location_recovery_test.dart' show PhoneLocation;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '00000000-0000-4000-8000-000000000001';
  final writes = <Map<String, dynamic>>[];
  var allowed = true;
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
        if (request.url.path.endsWith('/my_lab_access')) {
          return http.Response(
            jsonEncode({'can_simulate': allowed, 'is_owner': false}),
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

  late PhoneLocation phone;
  late GeolocatorPlatform original;
  late MapNavigationController controller;
  setUp(() {
    allowed = true;
    SharedPreferences.setMockInitialValues({});
    WorkoutHistoryRepository.resetInstancesForTesting();
    original = GeolocatorPlatform.instance;
    phone = PhoneLocation();
    GeolocatorPlatform.instance = phone;
    controller = MapNavigationController();
  });
  tearDown(() async {
    controller.dispose();
    await phone.close();
    GeolocatorPlatform.instance = original;
  });
  test('Denied server access cannot replace the actual GPS source', () async {
    allowed = false;
    await expectLater(controller.beginLaboratory(), throwsStateError);
    expect(controller.laboratory, isNull);
  });
  test('Active real recording prevents laboratory entry', () async {
    controller.startWorkout();
    await expectLater(controller.beginLaboratory(), throwsStateError);
    expect(controller.laboratory, isNull);
    expect(controller.isWorkoutActive, isTrue);
  });
  test(
    'Laboratory observations drive real recording; save is isolated',
    () async {
      await controller.initLocationTracking();
      await controller.beginLaboratory();
      controller.setAutoPauseEnabled(false);
      final lab = controller.laboratory!;
      controller.setShareLivePosition(true);
      controller.startWorkout();
      lab.moving = true;
      lab.emit();
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(controller.recordedPath.length, greaterThanOrEqualTo(2));
      expect(controller.totalDistanceMeters, greaterThan(5));
      await expectLater(controller.endLaboratory(), throwsStateError);
      final beforePause = controller.recordedPath.length;
      controller.pauseWorkout();
      lab.point = const Distance().offset(lab.point, 5, 90);
      lab.emit();
      expect(controller.recordedPath.length, beforePause);
      controller.resumeWorkout();
      lab.emit();
      final saved = await controller.finishAndSaveWorkout(
        title: 'Lab evidence',
      );
      expect(saved, isNotNull);
      final records = await controller.laboratoryStore.results();
      expect(records.single.localId, saved!.localId);
      expect(records.single.routePoints.length, saved.routePoints.length);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(UserScope.keyFor('workout_draft', me)), isNull);
      expect(prefs.getString(UserScope.keyFor('workout_history', me)), isNull);
      expect(writes, isEmpty);
      await controller.endLaboratory();
      expect(controller.laboratoryActive, isFalse);
      expect(phone.subscriptions, greaterThanOrEqualTo(2));
      expect(controller.currentLocation.latitude, phone.fix().latitude);
    },
  );
  test(
    'GPS loss is caused by missing observations, not a ready-made result',
    () async {
      await controller.initLocationTracking();
      await controller.beginLaboratory();
      final lab = controller.laboratory!;
      final last = controller.gpsSignal.value;
      lab.gpsAvailable = false;
      lab.point = const LatLng(57, 85);
      lab.emit();
      expect(controller.currentLocation.latitude, isNot(57));
      expect(controller.gpsSignal.value.updatedAt, last.updatedAt);
      expect(
        last
            .checkedAt(last.updatedAt!.add(const Duration(seconds: 31)))
            .quality,
        GpsQuality.lost,
      );
      lab.gpsAvailable = true;
      lab.emit();
      expect(controller.currentLocation.latitude, 57);
      expect(controller.gpsSignal.value.quality, GpsQuality.good);
    },
  );
  test(
    'Deviation is detected by production navigation and clears on return',
    () async {
      await controller.initLocationTracking();
      await controller.beginLaboratory();
      final lab = controller.laboratory!;
      final start = lab.point;
      controller.loadImportedTrack([
        start,
        const Distance().offset(start, 500, 0),
      ]);
      controller.setNavigating(true);
      await Future<void>.delayed(Duration.zero);
      lab.point = const Distance().offset(start, 120, 90);
      lab.emit();
      lab.emit();
      lab.emit();
      expect(controller.isOffRoute, isTrue);
      expect(controller.routeDeviationMeters, greaterThan(90));
      lab.point = start;
      lab.emit();
      expect(controller.isOffRoute, isFalse);
    },
  );
  test(
    'Checkpoint survives controller restart without touching real draft',
    () async {
      await controller.beginLaboratory();
      controller.startWorkout();
      controller.laboratory!.emit();
      controller.checkpointWorkout();
      final drafts = await controller.laboratoryStore.drafts();
      expect(drafts.single.path, isNotEmpty);
      final id = drafts.single.localId;
      controller.dispose();
      controller = MapNavigationController();
      await controller.beginLaboratory();
      final recovered = (await controller.laboratoryStore.drafts()).single;
      controller.restoreInterruptedWorkout(recovered);
      expect(controller.workoutSessionId, id);
      expect(controller.isWorkoutPaused, isTrue);
      await controller.finishAndSaveWorkout();
      expect(await controller.laboratoryStore.drafts(), isEmpty);
      expect((await controller.laboratoryStore.results()).single.localId, id);
    },
  );
  testWidgets(
    'Real controls fit 320px / 200 percent and leave map actions available',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => controller.beginLaboratory());
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 1000),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: LaboratoryControls(
                controller: controller,
                mapCenter: () => const LatLng(56, 84),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Управление движением'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'Following input polyline turns at its actual corner and can steer away',
    () {
      var now = DateTime.now();
      final start = const LatLng(56, 84);
      final corner = const Distance().offset(start, 20, 0);
      final finish = const Distance().offset(corner, 20, 90);
      final source = LaboratoryMotionSource(start, now: () => now);
      source.speedKmh = 36;
      source.start();
      source.followRoute([start, corner, finish]);
      now = now.add(const Duration(seconds: 3));
      source.tick();
      expect(const Distance()(corner, source.point), closeTo(10, 1));
      expect(source.point.longitude, greaterThan(corner.longitude));
      source.steer(180);
      expect(source.followingRoute, isFalse);
      source.dispose();
    },
  );
  test('Movement integrates actual elapsed time and heading', () {
    var now = DateTime.now();
    final source = LaboratoryMotionSource(const LatLng(56, 84), now: () => now);
    source.start();
    source.moving = true;
    source.speedKmh = 36;
    source.heading = 90;
    final start = source.point;
    now = now.add(const Duration(seconds: 2));
    source.tick();
    expect(
      const Distance().as(LengthUnit.Meter, start, source.point),
      closeTo(20, 1),
    );
    final moved = source.point;
    now = now.add(const Duration(minutes: 2));
    source.tick();
    expect(source.point, moved);
    source.dispose();
  });
}
