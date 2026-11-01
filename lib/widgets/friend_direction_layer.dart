import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/friend_profile.dart';

/// Screen coordinates, including map rotation and the closest world copy.
Offset friendScreenPosition(MapCamera camera, LatLng point) {
  final projected = camera.project(point);
  final center = camera.project(camera.center);
  var dx = projected.x - center.x;
  final world = camera.crs.scale(camera.zoom);
  if (camera.crs.wrapLng != null && world.isFinite && world > 0) {
    dx -= (dx / world).round() * world;
  }
  final dy = projected.y - center.y;
  final angle = camera.rotationRad;
  return Offset(
    camera.nonRotatedSize.x / 2 + dx * math.cos(angle) - dy * math.sin(angle),
    camera.nonRotatedSize.y / 2 + dx * math.sin(angle) + dy * math.cos(angle),
  );
}

/// Intersects the ray from the visible map's center with its inset edge.
Offset? friendEdgePosition(Offset point, Rect visible, Size badge) {
  if (!point.dx.isFinite || !point.dy.isFinite || visible.contains(point)) {
    return null;
  }
  final edge = Rect.fromLTRB(
    visible.left + badge.width / 2,
    visible.top + badge.height / 2,
    visible.right - badge.width / 2,
    visible.bottom - badge.height / 2,
  );
  if (edge.width <= 0 || edge.height <= 0) return null;
  final delta = point - visible.center;
  if (delta.distanceSquared == 0) return null;
  final tx = delta.dx == 0 ? double.infinity : edge.width / 2 / delta.dx.abs();
  final ty = delta.dy == 0 ? double.infinity : edge.height / 2 / delta.dy.abs();
  return visible.center + delta * math.min(tx, ty);
}

class _Direction {
  const _Direction(this.friend, this.position, this.angle, this.distance);
  final FriendProfile friend;
  final Offset position;
  final double angle;
  final String? distance;
  String get detail => [
    if (distance != null) distance!,
    if (!friend.hasFreshMotion) 'Был ${friend.positionAgeText}',
  ].join(' · ');
}

/// Uses only positions already authorized for the map; never fetches locations.
class FriendDirectionLayer extends StatefulWidget {
  const FriendDirectionLayer({
    super.key,
    required this.friends,
    required this.onSelect,
    this.myPosition,
    this.insets = const EdgeInsets.all(12),
  });
  final List<FriendProfile> friends;
  final ValueChanged<FriendProfile> onSelect;
  final LatLng? myPosition;
  final EdgeInsets insets;

  @override
  State<FriendDirectionLayer> createState() => _FriendDirectionLayerState();
}

class _FriendDirectionLayerState extends State<FriendDirectionLayer> {
  Timer? _ageTimer;
  @override
  void initState() {
    super.initState();
    _ageTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (mounted &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ageTimer?.cancel();
    super.dispose();
  }

  void _open(List<_Direction> group) {
    if (group.length == 1) {
      widget.onSelect(group.single.friend);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Друзья за краем карты'),
              ),
              for (final item in group)
                ListTile(
                  leading: Transform.rotate(
                    angle: item.angle,
                    child: const Icon(Icons.navigation_rounded),
                  ),
                  title: Text(item.friend.username),
                  subtitle: Text(
                    '${item.detail}\nПоказать последнюю позицию на карте'
                        .trim(),
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    widget.onSelect(item.friend);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final size = Size(camera.nonRotatedSize.x, camera.nonRotatedSize.y);
    if (!size.width.isFinite || !size.height.isFinite) {
      return const SizedBox.shrink();
    }
    final visible = widget.insets.deflateRect(Offset.zero & size);
    final badge = Size(
      math.min(156, size.width * .43),
      52 + math.max(0, MediaQuery.textScalerOf(context).scale(12) - 12) * 2,
    );
    final directions = <_Direction>[];
    for (final friend in widget.friends) {
      final lat = friend.liveLatitude, lon = friend.liveLongitude;
      if (!friend.hasLivePosition ||
          lat == null ||
          lon == null ||
          !lat.isFinite ||
          !lon.isFinite ||
          lat.abs() > 90 ||
          lon.abs() > 180) {
        continue;
      }
      final point = LatLng(lat, lon);
      final screen = friendScreenPosition(camera, point);
      final edge = friendEdgePosition(screen, visible, badge);
      if (edge == null) continue;
      final delta = screen - visible.center;
      final meters = widget.myPosition == null
          ? null
          : const Distance()(widget.myPosition!, point);
      final distance = meters == null
          ? null
          : meters < 1000
          ? '${meters.round()} м'
          : '${(meters / 1000).toStringAsFixed(1)} км';
      directions.add(
        _Direction(
          friend,
          edge,
          math.atan2(delta.dy, delta.dx) + math.pi / 2,
          distance,
        ),
      );
    }
    directions.sort((a, b) => a.friend.id.compareTo(b.friend.id));
    final groups = <List<_Direction>>[];
    for (final item in directions) {
      final rect = Rect.fromCenter(
        center: item.position,
        width: badge.width + 8,
        height: badge.height + 8,
      );
      final match = groups
          .where(
            (g) => rect.overlaps(
              Rect.fromCenter(
                center: g.first.position,
                width: badge.width,
                height: badge.height,
              ),
            ),
          )
          .firstOrNull;
      if (match == null) {
        groups.add([item]);
      } else {
        match.add(item);
      }
    }
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        for (final group in groups)
          Positioned(
            key: ValueKey('friend-direction-${group.first.friend.id}'),
            left: group.first.position.dx - badge.width / 2,
            top: group.first.position.dy - badge.height / 2,
            width: badge.width,
            height: badge.height,
            child: Semantics(
              button: true,
              label: group.length > 1
                  ? 'Друзья за краем карты: ${group.length}. Выбрать друга'
                  : '${group.first.friend.username}. ${group.first.detail}. Расстояние по прямой до последней позиции. Показать на карте',
              child: Tooltip(
                message: group.length > 1
                    ? 'Выбрать друга'
                    : '${group.first.friend.username}\n${group.first.detail}\nПо прямой до последней позиции · нажмите, чтобы показать',
                child: Material(
                  color: colors.surfaceContainerHigh,
                  elevation: 3,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _open(group),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Transform.rotate(
                            angle: group.first.angle,
                            child: Icon(
                              Icons.navigation_rounded,
                              size: 22,
                              color: group.first.friend.hasFreshMotion
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  group.length > 1
                                      ? 'Друзья · ${group.length}'
                                      : group.first.friend.username,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  group.length > 1
                                      ? 'Выбрать друга'
                                      : group.first.detail.isEmpty
                                      ? 'Показать на карте'
                                      : group.first.detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
