import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:pulsepath/models/ride_moment.dart';
import 'package:pulsepath/models/workout_details.dart';
import 'package:pulsepath/services/rides_service.dart';
import 'package:pulsepath/utils/gpx_utils.dart';

import 'network_guard.dart';

// Coordinates are written independently of the parser output. The corrupted
// point is impossible, so the expected repaired track excludes it.
const LatLng pointA = LatLng(55.000000, 83.000000);
const LatLng pointB = LatLng(55.001000, 83.001000);
const LatLng pointC = LatLng(55.002000, 83.002000);
const LatLng pointD = LatLng(55.004000, 83.004000);
const LatLng pointE = LatLng(55.005000, 83.005000);
const LatLng pointF = LatLng(55.006000, 83.006000);

const List<LatLng> controlPoints = [
  LatLng(54.000000, 82.000000),
  LatLng(54.001000, 82.001000),
  LatLng(54.002000, 82.002000),
  LatLng(54.003000, 82.003000),
  LatLng(54.004000, 82.004000),
  LatLng(54.005000, 82.005000),
];

String invalidMiddleGpx() => '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="PulsePath integrity test" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>Broken middle point</name>
  </metadata>
  <trk>
    <name>Broken middle point</name>
    <trkseg>
      <trkpt lat="55.000000" lon="83.000000"/>
      <trkpt lat="55.001000" lon="83.001000"/>
    </trkseg>
    <trkseg>
      <trkpt lat="55.002000" lon="83.002000"/>
      <trkpt lat="999.000000" lon="83.003000"/>
      <trkpt lat="55.004000" lon="83.004000"/>
    </trkseg>
    <trkseg>
      <trkpt lat="55.005000" lon="83.005000"/>
      <trkpt lat="55.006000" lon="83.006000"/>
    </trkseg>
  </trk>
</gpx>
''';

WorkoutDetails staleDetails() => const WorkoutDetails(
  segmentStarts: [0, 2, 5],
  rideMoments: [
    RideMoment(
      id: 'before-gap',
      kind: RideMomentKind.rest,
      pointIndex: 1,
      distanceMeters: 100,
    ),
    RideMoment(
      id: 'after-gap',
      kind: RideMomentKind.climb,
      pointIndex: 5,
      distanceMeters: 500,
    ),
  ],
);

Map<String, dynamic> row({
  required String gpx,
  required Map<String, dynamic> details,
}) => {
  'id': 'ride-cloud-1',
  'user_id': 'owner-cloud',
  'distance_km': 0.7,
  'duration_seconds': 600,
  'calories': 50,
  'elevation_gain': 12,
  'gpx_data': gpx,
  'vehicle_id': null,
  'transport_type': 'cycling',
  'created_at': '2026-10-03T10:00:00.000Z',
  'workout_details': details,
};

void expectPoint(LatLng actual, LatLng expected, {String? reason}) {
  expect(actual.latitude, closeTo(expected.latitude, 1e-9), reason: reason);
  expect(actual.longitude, closeTo(expected.longitude, 1e-9), reason: reason);
}

void main() {
  setUpAll(NetworkGuard.install);
  tearDownAll(NetworkGuard.restore);

  test('valid GPX with multiple segments keeps moments and boundaries on their points', () {
    final gpx = GpxUtils.build(
      points: controlPoints,
      name: 'Control track',
      segmentStarts: const [0, 2, 5],
    );
    final parsed = GpxUtils.parseTrack(gpx);
    expect(parsed.points, hasLength(6));
    expect(parsed.segmentStarts, [0, 2, 5]);
    final parsedSegments = WorkoutDetails.splitTrack(
      parsed.points,
      parsed.segmentStarts,
    );
    expect(parsedSegments.map((segment) => segment.length), [2, 3, 1]);
    expectPoint(parsedSegments[0].first, controlPoints[0]);
    expectPoint(parsedSegments[1].first, controlPoints[2]);
    expectPoint(parsedSegments[2].first, controlPoints[5]);

    const details = WorkoutDetails(
      segmentStarts: [0, 2, 5],
      rideMoments: [
        RideMoment(
          id: 'before',
          kind: RideMomentKind.rest,
          pointIndex: 1,
          distanceMeters: 100,
        ),
        RideMoment(
          id: 'after',
          kind: RideMomentKind.climb,
          pointIndex: 5,
          distanceMeters: 500,
        ),
      ],
    );
    final route = RidesService.rideFromRow(
      row(gpx: gpx, details: details.toJson()),
    );
    expect(route, isNotNull);
    expect(route!.routePoints, hasLength(6));
    for (var i = 0; i < controlPoints.length; i++) {
      expectPoint(route.routePoints[i], controlPoints[i]);
    }
    expect(route.workoutDetails.segmentStarts, [0, 2, 5]);
    final before = route.workoutDetails.rideMoments.singleWhere(
      (moment) => moment.id == 'before',
    );
    final after = route.workoutDetails.rideMoments.singleWhere(
      (moment) => moment.id == 'after',
    );
    expectPoint(route.routePoints[before.pointIndex], controlPoints[1]);
    expectPoint(route.routePoints[after.pointIndex], controlPoints[5]);
  });

  test('a bad middle point does not silently move segment boundaries', () {
    final gpx = invalidMiddleGpx();
    final parsed = GpxUtils.parseTrack(gpx);

    // Independent expectation after dropping lat=999: A B / C / D / E F.
    expect(parsed.points, hasLength(6));
    final expected = [pointA, pointB, pointC, pointD, pointE, pointF];
    for (var i = 0; i < expected.length; i++) {
      expectPoint(parsed.points[i], expected[i]);
    }
    expect(parsed.segmentStarts, [
      0,
      2,
      3,
      4,
    ], reason: 'the invalid point must break the segment, not shift indices');
    final segments = WorkoutDetails.splitTrack(
      parsed.points,
      parsed.segmentStarts,
    );
    expect(segments.map((segment) => segment.length), [2, 1, 1, 2]);
    expectPoint(segments[0].first, pointA);
    expectPoint(segments[1].first, pointC);
    expectPoint(segments[2].first, pointD);
    expectPoint(segments[3].first, pointE);

    // These are the indices stored before the bad point was discovered:
    // B was index 1, E was index 5. After dropping the bad point E is index 4.
    final route = RidesService.rideFromRow(
      row(gpx: gpx, details: staleDetails().toJson()),
    );

    // A repairable row stays visible, and every stored
    // boundary must be remapped to the repaired point array.
    expect(
      route,
      isNotNull,
      reason: 'a repairable ride must remain accessible',
    );
    if (route == null) throw StateError('repairable ride rejected');
    expect(route.routePoints, hasLength(6));
    for (var i = 0; i < expected.length; i++) {
      expectPoint(route.routePoints[i], expected[i]);
    }
    expect(route.workoutDetails.segmentStarts, [
      0,
      2,
      3,
      4,
    ], reason: 'stale segment_starts were trusted after a point was dropped');
  });

  test('a bad middle point does not silently move a later ride moment', () {
    final route = RidesService.rideFromRow(
      row(gpx: invalidMiddleGpx(), details: staleDetails().toJson()),
    );

    // A repairable row stays visible, and every stored
    // moment index must be remapped to the repaired point array.
    expect(
      route,
      isNotNull,
      reason: 'a repairable ride must remain accessible',
    );
    if (route == null) throw StateError('repairable ride rejected');
    expect(route.routePoints, hasLength(6));
    final before = route.workoutDetails.rideMoments.singleWhere(
      (moment) => moment.id == 'before-gap',
    );
    final after = route.workoutDetails.rideMoments.singleWhere(
      (moment) => moment.id == 'after-gap',
    );
    expect(before.pointIndex, lessThan(route.routePoints.length));
    expect(after.pointIndex, lessThan(route.routePoints.length));
    expectPoint(
      route.routePoints[before.pointIndex],
      pointB,
      reason: 'the moment before the gap moved',
    );
    expectPoint(
      route.routePoints[after.pointIndex],
      pointE,
      reason: 'the moment after the gap points to the wrong coordinate',
    );
  });
  test('removed and out-of-range anchors are never moved onto a neighbour', () {
    final details = staleDetails().toJson();
    details['ride_moments'] = [
      ...(details['ride_moments'] as List),
      {'id': 'invalid-point', 'kind': 'rest', 'point_index': 3, 'meters': 300},
      {'id': 'outside', 'kind': 'rest', 'point_index': 99, 'meters': 900},
    ];
    details['samples'] = [
      {'seconds': 0, 'meters': 0, 'track_point_index': 1},
      {'seconds': 1, 'meters': 100, 'track_point_index': 3},
      {'seconds': 2, 'meters': 200, 'track_point_index': 5},
    ];
    final ride = RidesService.rideFromRow(
      row(gpx: invalidMiddleGpx(), details: details),
    )!;
    expect(ride.workoutDetails.rideMoments.map((m) => m.id), [
      'before-gap',
      'after-gap',
    ]);
    expect(ride.workoutDetails.samples.map((s) => s.trackPointIndex), [
      1,
      null,
      4,
    ]);
    expect(GpxUtils.parseTrack(invalidMiddleGpx()).sourcePointIndices, [
      0,
      1,
      2,
      4,
      5,
      6,
    ]);
  });
}
