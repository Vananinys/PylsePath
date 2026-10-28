import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/trail_appearance.dart';
import 'package:pulsepath/models/activity_type.dart';
import 'package:pulsepath/models/friend_profile.dart';
import 'package:pulsepath/models/live_trail_style.dart';
import 'package:pulsepath/services/owned_trail_style_service.dart';
import 'package:pulsepath/widgets/activity_trail_layer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Untrusted remote appearance is bounded and versioned', () {
    final style = LiveTrailStyle.fromRow({
      'version': 1,
      'style': 'evil',
      'color_index': 999,
      'marker_size': double.infinity,
      'spacing': -40,
      'opacity': double.nan,
    });
    expect(style.style, TrailStyle.automatic);
    expect(style.colorIndex, 11);
    expect(style.size, 10);
    expect(style.spacing, 16);
    expect(style.opacity, .85);
    expect(
      LiveTrailStyle.fromRow({'version': 999, 'enabled': false}).enabled,
      isTrue,
    );
  });

  test('Position ticks preserve the owner-selected trail', () {
    final friend = FriendProfile.fromRow({
      'id': 'a',
      'username': 'A',
      'live_trail_style': const LiveTrailStyle(
        style: TrailStyle.car,
        colorIndex: 4,
      ).toRow(),
    });
    final next = friend.copyWith(
      liveLatitude: 55,
      liveLongitude: 83,
      liveUpdatedAt: DateTime.utc(2026),
    );
    expect(next.liveTrailStyle!.style, TrailStyle.car);
    expect(next.liveTrailStyle!.colorIndex, 4);
  });

  test(
    'Offline choice retries after restart without leaking to another account',
    () async {
      String? owner = 'a';
      var offline = true;
      final writes = <String, Map<String, Object>>{};
      OwnedTrailStyleService make() => OwnedTrailStyleService(
        currentOwner: () => owner,
        readRemote: (_) async => null,
        writeRemote: (uid, row) async {
          if (offline) throw StateError('offline');
          writes[uid] = row;
        },
      );
      final first = make();
      await first.save(
        const LiveTrailStyle(style: TrailStyle.boots, colorIndex: 3),
      );
      expect(first.pending, isTrue);
      first.dispose();
      final restarted = make();
      await restarted.load();
      expect(restarted.style.style, TrailStyle.boots);
      expect(restarted.pending, isTrue);
      offline = false;
      await restarted.load(refresh: true);
      expect(restarted.pending, isFalse);
      expect(writes['a']!['style'], 'boots');
      owner = 'b';
      expect(restarted.style.style, TrailStyle.automatic);
      await restarted.load();
      expect(restarted.style.colorIndex, 0);
      await restarted.save(const LiveTrailStyle(style: TrailStyle.arrows));
      expect(writes['b']!['style'], 'arrows');
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('owned_trail_style_v1_a')!)['style'],
        'boots',
      );
      restarted.dispose();
    },
  );

  test('Late account A load cannot paint its style in account B', () async {
    String? owner = 'a';
    final started = Completer<void>();
    final response = Completer<Map<String, dynamic>?>();
    final service = OwnedTrailStyleService(
      currentOwner: () => owner,
      readRemote: (uid) async {
        if (uid == 'a') {
          started.complete();
          return response.future;
        }
        return const LiveTrailStyle(style: TrailStyle.dots).toRow();
      },
    );
    final loading = service.load();
    await started.future;
    owner = 'b';
    expect(service.style.style, TrailStyle.automatic);
    final next = service.load();
    response.complete(const LiveTrailStyle(style: TrailStyle.car).toRow());
    await loading;
    await next;
    expect(service.style.style, TrailStyle.dots);
    service.dispose();
  });

  test('Queued save is rejected after account switch', () async {
    String? owner = 'a';
    final started = Completer<void>();
    final finish = Completer<void>();
    final writes = <String>[];
    final service = OwnedTrailStyleService(
      currentOwner: () => owner,
      writeRemote: (uid, _) async {
        writes.add(uid);
        started.complete();
        await finish.future;
      },
    );
    final first = service.save(const LiveTrailStyle(style: TrailStyle.boots));
    await started.future;
    final stale = service.save(const LiveTrailStyle(style: TrailStyle.car));
    final rejection = expectLater(stale, throwsStateError);
    owner = 'b';
    finish.complete();
    await first;
    await rejection;
    expect(writes, ['a']);
    expect(service.style.style, TrailStyle.automatic);
    service.dispose();
  });

  testWidgets('Viewer cannot replace the owners style or color', (
    tester,
  ) async {
    await TrailAppearance.instance.update(
      friendsPattern: TrailStyle.dots,
      pattern: TrailStyle.boots,
      recording: false,
      friends: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(0, 0),
              initialZoom: 16,
            ),
            children: const [
              ActivityTrailLayer(
                segments: [
                  [LatLng(0, 0), LatLng(0, .001)],
                ],
                activity: ActivityType.hiking,
                live: true,
                recorded: true,
                liveAppearance: LiveTrailStyle(
                  style: TrailStyle.car,
                  colorIndex: 4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is TrailPainter,
      ),
    );
    final painter = paint.painter! as TrailPainter;
    expect(painter.style, TrailStyle.car);
    expect(painter.color, TrailAppearance.colors[4].withValues(alpha: .85));
    await tester.pumpWidget(const SizedBox.shrink());
    await TrailAppearance.instance.update(reset: true);
  });
}
