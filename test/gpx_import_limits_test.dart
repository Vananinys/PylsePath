// Regression tests for the GPX import limits fix (base d49a9f3).
//
// Expected behavior: parseTrack reports an explicit result (full, truncated,
// oversized, invalid, no track) instead of collapsing everything into an
// empty list, the import shows truthful messages, and a partially read cloud
// track can never overwrite the full GPX with re-serialized geometry.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pulsepath/data/workout_history_repository.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/ride_moment.dart';
import 'package:pulsepath/models/saved_route.dart';
import 'package:pulsepath/services/rides_service.dart';
import 'package:pulsepath/utils/gpx_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = UploadCountingHarness();
  late WorkoutHistoryRepository repo;

  setUpAll(() async {
    await harness.ready;
    WorkoutHistoryRepository.resetInstancesForTesting();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferences.resetStatic();
    harness.uploaded.clear();
    WorkoutHistoryRepository.resetInstancesForTesting();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('workout_history_${UploadCountingHarness.uid}');
    repo = WorkoutHistoryRepository();
  });

  group('GpxUtils.parseTrack explicit results', () {
    test('a valid file below the point limit parses fully', () {
      final points = _track(1000);
      final parsed = GpxUtils.parseTrack(
        GpxUtils.build(points: points, segmentStarts: const []),
      );
      expect(parsed.status, GpxParseStatus.ok);
      expect(parsed.points, hasLength(1000));
      expect(parsed.totalTrackPoints, 1000);
      expect(parsed.segmentStarts, [0]);
      expect(parsed.sourcePointIndices, hasLength(1000));
    });

    test('exactly 100 000 points is a complete track, not a truncation', () {
      final points = _track(100000);
      final parsed = GpxUtils.parseTrack(
        GpxUtils.build(points: points, segmentStarts: const []),
      );
      expect(parsed.status, GpxParseStatus.ok);
      expect(parsed.points, hasLength(100000));
      // GPX keeps 6 decimals; compare with that precision.
      expect(parsed.points.last.latitude, closeTo(points.last.latitude, 1e-6));
    });

    test('100 001 points reports a partial result with the true total', () {
      final points = _track(100001);
      final parsed = GpxUtils.parseTrack(
        GpxUtils.build(points: points, segmentStarts: const []),
      );
      expect(parsed.status, GpxParseStatus.truncatedPoints);
      expect(parsed.points, hasLength(100000));
      expect(parsed.totalTrackPoints, 100001);
      expect(
        parsed.points.last.latitude,
        closeTo(points[99999].latitude, 1e-6),
      );
    });

    test('a point limit hit inside multiple segments keeps the retained starts', () {
      final points = _track(100001);
      final parsed = GpxUtils.parseTrack(
        GpxUtils.build(
          points: points,
          segmentStarts: const [1, 60000, 100000],
        ),
      );
      expect(parsed.status, GpxParseStatus.truncatedPoints);
      expect(parsed.points, hasLength(100000));
      expect(parsed.totalTrackPoints, 100001);
      // The last one-point segment (index 100000) is entirely beyond the cap.
      expect(parsed.segmentStarts, [0, 1, 60000]);
    });

    test('a file above the size limit is oversized without parsing', () {
      final oversized = '${' ' * (20 * 1024 * 1024 + 1)}</gpx>';
      final parsed = GpxUtils.parseTrack(oversized);
      expect(parsed.status, GpxParseStatus.oversized);
      expect(parsed.points, isEmpty);
      expect(parsed.totalTrackPoints, 0);
    });

    test('a file just below the size limit is still parsed', () {
      const stub =
          '<gpx><trk><trkseg><trkpt lat="56.48" lon="84.95"/></trkseg></trk></gpx>';
      // 20 MiB is the Dart string length cap (code units), not file bytes.
      final padded =
          '${' ' * (20 * 1024 * 1024 - stub.length)}$stub';
      final parsed = GpxUtils.parseTrack(padded);
      expect(parsed.status, GpxParseStatus.ok);
      expect(parsed.points, hasLength(1));
    });

    test('an empty payload is noTrack', () {
      expect(GpxUtils.parseTrack(null).status, GpxParseStatus.noTrack);
      expect(GpxUtils.parseTrack('').status, GpxParseStatus.noTrack);
      expect(GpxUtils.parse(null), isEmpty);
      expect(GpxUtils.parse(''), isEmpty);
    });

    test('broken XML is invalidXml', () {
      expect(
        GpxUtils.parseTrack('<gpx><trkseg><trkpt lat="1" lon="2"></trkseg>')
            .status,
        GpxParseStatus.invalidXml,
      );
      expect(GpxUtils.parseTrack('not xml at all').status,
          GpxParseStatus.invalidXml);
    });

    test('a valid GPX without a supported track is noTrack', () {
      const waypointsOnly =
          '<gpx><wpt lat="56.48" lon="84.95"/></gpx>';
      final parsed = GpxUtils.parseTrack(waypointsOnly);
      expect(parsed.status, GpxParseStatus.noTrack);
      expect(parsed.points, isEmpty);
      const metadataOnly = '<gpx><metadata><name>Пусто</name></metadata></gpx>';
      expect(GpxUtils.parseTrack(metadataOnly).status, GpxParseStatus.noTrack);
    });

    test(
      'totalTrackPoints counts every trkpt node, valid or not, across segments',
      () {
        // 99 999 valid + 2 invalid + 2 valid + 2 valid in a second segment =
        // 100 005 nodes, 100 003 of them valid. The cap keeps the first
        // 100 000 valid points, so the warning must say «100 000 из 100 005»
        // — the same numbers the UI reports.
        final buffer = StringBuffer()
          ..writeln('<gpx><trk><name>Смешанный</name><trkseg>')
          ..write(_trkptXml(_track(99999)));
        for (var i = 0; i < 2; i++) {
          buffer.writeln('<trkpt lon="84.95" />');
        }
        buffer
          ..write(_trkptXml(_track(2, start: 99999)))
          ..writeln('</trkseg>')
          ..writeln(
            '<trkseg>${_trkptXml(_track(2, start: 100001))}</trkseg>'
            '</trk></gpx>',
          );
        final parsed = GpxUtils.parseTrack(buffer.toString());
        expect(parsed.status, GpxParseStatus.truncatedPoints);
        expect(parsed.points, hasLength(100000));
        expect(parsed.totalTrackPoints, 100005);
        expect(parsed.name, 'Смешанный');
        expect(parsed.sourcePointIndices, hasLength(100000));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'invalid points alone never mark a complete track as truncated',
      () {
        // 10 valid + 3 invalid, no cap reached: everything supported was
        // read, so the track is complete despite the dropped garbage nodes.
        final buffer = StringBuffer()
          ..write('<gpx><trk><trkseg>')
          ..write(_trkptXml(_track(10)))
          ..write('<trkpt lon="84.95" /><trkpt lat="not-a-number" lon="84.95" />')
          ..write('<trkpt lat="56" lon="1000" />')
          ..write('</trkseg></trk></gpx>');
        final parsed = GpxUtils.parseTrack(buffer.toString());
        expect(parsed.status, GpxParseStatus.ok);
        expect(parsed.points, hasLength(10));
        expect(parsed.totalTrackPoints, 13);
      },
    );
  });

  test(
    'RidesService marks a cloud ride partial when its GPX exceeds the point cap',
    () {
      final points = _track(100001);
      final gpx = GpxUtils.build(points: points, segmentStarts: const [50000]);
      final row = {
        'id': 'remote-1',
        'user_id': 'u',
        'distance_km': 500.0,
        'duration_seconds': 100001,
        'calories': 100,
        'elevation_gain': 10,
        'gpx_data': gpx,
        'vehicle_id': null,
        'transport_type': 'cycling',
        'created_at': DateTime.utc(2026, 11, 15, 9).toIso8601String(),
        'workout_details': {
          'segment_starts': [50000],
        },
        'activity_local_day': '2026-11-15',
      };

      final ride = RidesService.rideFromRow(row);
      expect(ride, isNotNull);
      expect(ride!.routePointsPartial, isTrue);
      expect(ride.routePoints, hasLength(100000));
      // The banner and dialogs must report the same total as the file held.
      expect(ride.routePointsTotal, 100001);

      // A ride at the cap (100 000 points) stays fully usable.
      final fullRow = {...row}
        ..['id'] = 'remote-2'
        ..['gpx_data'] = GpxUtils.build(
          points: _track(100000),
          segmentStarts: const [50000],
        );
      final full = RidesService.rideFromRow(fullRow);
      expect(full!.routePointsPartial, isFalse);
      expect(full.routePoints, hasLength(100000));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'A partial cloud ride survives a full history round trip with the flag',
    () async {
      final partial = SavedRoute(
        localId: 'cloud-row-1',
        title: 'partial',
        distance: '500.00 км',
        duration: '27 ч',
        surfaceSummary: '',
        finishPoint: const LatLng(56.4801, 84.9501),
        routePoints: _track(100000),
        activityType: ActivityType.cycling,
        cloudSynced: true,
        remoteId: 'remote-1',
        routePointsPartial: true,
        routePointsTotal: 20000,
        createdAt: DateTime.utc(2026, 11, 15, 9),
      );
      await repo.addWorkout(partial);
      await repo.load();
      final restored = repo.workoutHistory.single;
      expect(restored.routePointsPartial, isTrue);
      expect(restored.routePointsTotal, 20000);
    },
  );

  test(
    'the partial flag survives withSyncState and withLibraryDetails copies',
    () {
      final partial = SavedRoute(
        localId: 'copy-probe',
        title: 'partial',
        distance: '500.00 км',
        duration: '27 ч',
        surfaceSummary: '',
        finishPoint: const LatLng(56.4801, 84.9501),
        routePoints: _track(3),
        activityType: ActivityType.cycling,
        cloudSynced: true,
        remoteId: 'remote-1',
        routePointsPartial: true,
        routePointsTotal: 152340,
        createdAt: DateTime.utc(2026, 11, 15, 9),
      );

      final synced = partial.withSyncState(remoteId: 'remote-2', cloudSynced: false);
      expect(synced.routePointsPartial, isTrue);
      expect(synced.routePointsTotal, 152340);

      // Metadata edits in the library must not silently mark the track full.
      final relabeled = partial.withLibraryDetails(title: 'Новое имя');
      expect(relabeled.routePointsPartial, isTrue);
      expect(relabeled.routePointsTotal, 152340);
      expect(relabeled.title, 'Новое имя');
    },
  );

  test(
    'addRideMoment refuses a partial ride with an explicit message',
    () async {
      final partial = SavedRoute(
        localId: 'cloud-row-1',
        title: 'partial',
        distance: '500.00 км',
        duration: '27 ч',
        surfaceSummary: '',
        finishPoint: const LatLng(56.4801, 84.9501),
        routePoints: _track(3),
        activityType: ActivityType.cycling,
        cloudSynced: true,
        remoteId: 'remote-1',
        routePointsPartial: true,
        createdAt: DateTime.utc(2026, 11, 15, 9),
      );
      await repo.addWorkout(partial);
      await expectLater(
        repo.addRideMoment(
          partial,
          const RideMoment(
            id: 'm1',
            pointIndex: 1,
            kind: RideMomentKind.rest,
            distanceMeters: 5,
          ),
        ),
        throwsA(
          isA<HistoryRefusedException>().having(
            (e) => e.message,
            'message',
            contains('не полностью'),
          ),
        ),
      );
      await repo.load();
      expect(
        repo.workoutHistory.single.workoutDetails.rideMoments,
        isEmpty,
        reason: 'the refused moment must not be stored',
      );
    },
  );

  test(
    'retryUnsynced never uploads a partial ride but uploads a normal one',
    () async {
      final partial = SavedRoute(
        localId: 'cloud-row-partial',
        title: 'partial',
        distance: '500.00 км',
        duration: '27 ч',
        surfaceSummary: '',
        finishPoint: const LatLng(56.4801, 84.9501),
        routePoints: _track(3),
        activityType: ActivityType.cycling,
        // Not synced: only the upload refusal can protect the cloud row.
        cloudSynced: false,
        remoteId: 'remote-partial',
        routePointsPartial: true,
        createdAt: DateTime.utc(2026, 11, 15, 9),
      );
      final normal = SavedRoute(
        localId: 'normal-ride',
        title: 'normal',
        distance: '1.00 км',
        duration: '5 мин',
        surfaceSummary: '',
        finishPoint: const LatLng(55, 83),
        routePoints: const [LatLng(55, 83), LatLng(55.001, 83)],
        activityType: ActivityType.cycling,
        cloudSynced: false,
        createdAt: DateTime.utc(2026, 11, 15, 10),
      );
      await repo.addWorkout(partial);
      await repo.addWorkout(normal);

      await repo.retryUnsynced();

      // Only the complete ride reached the network; the partial geometry
      // never left the device.
      expect(
        harness.uploaded.map((r) => r['id']),
        ['normal-ride'],
      );
      await repo.load();
      expect(
        repo.workoutHistory
            .singleWhere((r) => r.localId == 'cloud-row-partial')
            .cloudSynced,
        isFalse,
        reason: 'a partial ride stays local instead of overwriting the cloud GPX',
      );
      expect(
        repo.workoutHistory
            .singleWhere((r) => r.localId == 'normal-ride')
            .cloudSynced,
        isTrue,
      );
    },
  );
}

List<LatLng> _track(int n, {int start = 0}) {
  var lat = 56.48, lon = 84.95;
  return [
    for (var i = start; i < start + n; i++)
      LatLng(lat + i * 0.000001, lon + i * 0.000001),
  ];
}

String _trkptXml(List<LatLng> points) =>
    points
        .map(
          (p) =>
              '<trkpt lat="${p.latitude.toStringAsFixed(6)}" '
              'lon="${p.longitude.toStringAsFixed(6)}" />',
        )
        .join();

/// The data-protection harness needs the authenticated uid scope; network
/// uploads are counted with a mock client.
class UploadCountingHarness {
  static const uid = '00000000-0000-4000-8000-000000000001';
  final uploaded = <Map<String, dynamic>>[];
  late final Future<void> ready;

  UploadCountingHarness() {
    ready = () async {
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
        url: 'https://gpx-limits-fix.example.invalid',
        publishableKey: 'test-only',
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
        ),
        httpClient: MockClient((request) async {
          const headers = {'content-type': 'application/json'};
          if (request.url.path.endsWith('/token')) {
            String part(Object value) => base64Url
                .encode(utf8.encode(jsonEncode(value)))
                .replaceAll('=', '');
            final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
            return http.Response(
              jsonEncode({
                'access_token':
                    '${part({'alg': 'HS256'})}.${part({'sub': uid, 'exp': expiry})}.signature',
                'refresh_token': 'test-refresh',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': uid,
                  'aud': 'authenticated',
                  'role': 'authenticated',
                  'email': 'gpx@example.invalid',
                  'created_at': '2026-11-01T00:00:00Z',
                  'app_metadata': {},
                  'user_metadata': {},
                },
              }),
              200,
              headers: headers,
              request: request,
            );
          }
          if (request.url.path.endsWith('/rides') && request.method == 'POST') {
            uploaded.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
            return http.Response(
              jsonEncode({'id': uploaded.last['id']}),
              201,
              headers: headers,
              request: request,
            );
          }
          return http.Response('[]', 200, headers: headers, request: request);
        }),
      );
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'gpx@example.invalid',
        password: 'test-only',
      );
    }();
  }
}
