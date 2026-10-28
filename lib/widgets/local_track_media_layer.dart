import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/ride_media_repository.dart';
import '../models/ride_media.dart';
import '../models/track_media_groups.dart';
import 'track_media_thumbnail.dart';

class LocalTrackMediaLayer extends StatefulWidget {
  const LocalTrackMediaLayer({
    super.key,
    required this.rideId,
    required this.points,
    required this.onOpen,
  });
  final String rideId;
  final List<LatLng> points;
  final Future<void> Function(RideMedia) onOpen;
  @override
  State<LocalTrackMediaLayer> createState() => _LocalTrackMediaLayerState();
}

class _LocalTrackMediaLayerState extends State<LocalTrackMediaLayer> {
  late RideMediaRepository _repo;
  late Future<List<RideMedia>> _items;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LocalTrackMediaLayer old) {
    super.didUpdateWidget(old);
    if (old.rideId != widget.rideId) _load();
  }

  void _load() {
    _repo = RideMediaRepository(widget.rideId);
    _items = _repo.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<RideMedia>>(
    future: _items,
    builder: (context, snapshot) {
      final groups = groupTrackMedia(
        _repo.isCurrent ? snapshot.data ?? [] : <RideMedia>[],
        widget.points,
        (m) => m.pointIndex,
        MapCamera.of(context).zoom,
      );
      return MarkerLayer(
        markers: [
          for (final group in groups)
            Marker(
              point: widget.points[group.first.pointIndex],
              width: 60,
              height: 60,
              child: TrackMediaThumbnail(
                local: group.first,
                count: group.length,
                onTap: () async {
                  await widget.onOpen(group.first);
                  if (mounted) setState(_load);
                },
              ),
            ),
        ],
      );
    },
  );
}
