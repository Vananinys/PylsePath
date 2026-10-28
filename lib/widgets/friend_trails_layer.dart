import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../data/trail_appearance.dart';
import '../models/activity_type.dart';
import '../models/friend_profile.dart';
import '../models/friend_trail_buffer.dart';
import 'activity_trail_layer.dart';

/// Short, fading tails under friend avatars. Does not intercept map gestures.
class FriendTrailsLayer extends StatefulWidget {
  const FriendTrailsLayer({super.key, required this.friends});
  final List<FriendProfile> friends;

  @override
  State<FriendTrailsLayer> createState() => _FriendTrailsLayerState();
}

class _FriendTrailsLayerState extends State<FriendTrailsLayer>
    with WidgetsBindingObserver {
  final _buffer = FriendTrailBuffer();
  final _automatic = TrailAppearance();
  Timer? _timer;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (_foreground) _buffer.sync(widget.friends, DateTime.now());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_foreground) return;
      setState(() => _buffer.prune(DateTime.now()));
    });
  }

  @override
  void didUpdateWidget(covariant FriendTrailsLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_foreground) _buffer.sync(widget.friends, DateTime.now());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _buffer.clear();
    if (_foreground) _buffer.sync(widget.friends, DateTime.now());
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _buffer.clear();
    _automatic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    MapCamera.of(context);
    final now = DateTime.now();
    final lines = <Polyline>[];
    final decorations = <Widget>[];
    _buffer.prune(now);
    for (final friend in widget.friends) {
      final points = _buffer.pointsFor(friend.id);
      if (points.length < 2) continue;
      // Stable across devices; different friends remain distinguishable.
      final hash = friend.id.codeUnits.fold(
        0,
        (sum, code) => (sum * 31 + code) & 0x7fffffff,
      );
      final color =
          TrailAppearance.colors[hash % TrailAppearance.colors.length];
      final activity = ActivityType.values
          .where((a) => a.name == friend.liveActivity)
          .firstOrNull;
      final age =
          now.difference(points.last.at).inMilliseconds /
          FriendTrailBuffer.lifetime.inMilliseconds;
      decorations.add(
        Opacity(
          opacity: (1 - age).clamp(0.0, 1.0),
          child: ActivityTrailLayer(
            segments: [
              [for (final point in points) point.position],
            ],
            activity: activity ?? ActivityType.hiking,
            recorded: true,
            baseColor: color,
          ),
        ),
      );
    }
    return IgnorePointer(
      child: Stack(
        children: [
          PolylineLayer(polylines: lines),
          if (decorations.isNotEmpty) Stack(children: decorations),
        ],
      ),
    );
  }
}
