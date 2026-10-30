import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/friend_motion.dart';
import '../models/friend_profile.dart';
import 'friend_markers_layer.dart';
import 'friend_trails_layer.dart';

/// One animation clock for avatars and trail endpoints; no predicted positions.
class FriendMotionLayer extends StatefulWidget {
  const FriendMotionLayer({
    super.key,
    required this.friends,
    required this.markerBuilder,
    required this.onSelect,
  });
  final List<FriendProfile> friends;
  final Widget Function(FriendProfile) markerBuilder;
  final ValueChanged<FriendProfile> onSelect;

  @override
  State<FriendMotionLayer> createState() => _FriendMotionLayerState();
}

class _FriendMotionLayerState extends State<FriendMotionLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _motion = <String, FriendMotion>{};
  late final _clock =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1800),
      )..addListener(() {
        if (mounted) setState(() {});
      });
  Timer? _freshness;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _sync();
    _freshness = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _foreground) setState(() {});
    });
  }

  void _sync() {
    if (!_foreground) return;
    final now = DateTime.now();
    final ids = widget.friends.map((f) => f.id).toSet();
    _motion.removeWhere((id, _) => !ids.contains(id));
    for (final f in widget.friends) {
      final lat = f.liveLatitude, lon = f.liveLongitude, at = f.liveUpdatedAt;
      if (lat == null ||
          lon == null ||
          at == null ||
          !lat.isFinite ||
          !lon.isFinite ||
          lat.abs() > 90 ||
          lon.abs() > 180) {
        _motion.remove(f.id);
        continue;
      }
      final point = LatLng(lat, lon);
      final motion = _motion.putIfAbsent(f.id, () => FriendMotion(point, at));
      motion.update(point, at, now, paused: f.livePaused);
    }
    if (_motion.values.any((m) => m.animating(now))) _clock.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant FriendMotionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _clock.stop();
    _motion.clear();
    if (state == AppLifecycleState.resumed) _sync();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _freshness?.cancel();
    _clock.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final positions = {
      for (final e in _motion.entries) e.key: e.value.position(now),
    };
    final displayed = [
      for (final f in widget.friends)
        if (positions[f.id] != null)
          f.copyWith(
            liveLatitude: positions[f.id]!.latitude,
            liveLongitude: positions[f.id]!.longitude,
            liveUpdatedAt: f.liveUpdatedAt,
            liveActivity: f.liveActivity,
            liveSpeedKmh: f.liveSpeedKmh,
          ),
    ];
    return Stack(
      children: [
        FriendTrailsLayer(friends: widget.friends, displayPositions: positions),
        FriendMarkersLayer(
          friends: displayed,
          markerBuilder: widget.markerBuilder,
          headings: {
            for (final f in displayed)
              if (f.hasFreshMotion &&
                  !f.livePaused &&
                  _motion[f.id]?.direction(now) != null)
                f.id: _motion[f.id]!.direction(now)!,
          },
          onSelect: (f) => widget.onSelect(
            widget.friends.firstWhere((raw) => raw.id == f.id),
          ),
        ),
      ],
    );
  }
}
