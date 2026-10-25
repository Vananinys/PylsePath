import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/friend_profile.dart';

/// Groups overlapping avatars at the current zoom, independently of GPS ticks.
class FriendMarkersLayer extends StatelessWidget {
  const FriendMarkersLayer({
    super.key,
    required this.friends,
    required this.markerBuilder,
    required this.onSelect,
  });
  final List<FriendProfile> friends;
  final Widget Function(FriendProfile) markerBuilder;
  final ValueChanged<FriendProfile> onSelect;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final groups = <List<FriendProfile>>[];
    for (final friend in [...friends]..sort((a, b) => a.id.compareTo(b.id))) {
      final point = camera.project(
        LatLng(friend.liveLatitude!, friend.liveLongitude!),
      );
      List<FriendProfile>? match;
      for (final group in groups) {
        final anchor = group.first;
        final other = camera.project(
          LatLng(anchor.liveLatitude!, anchor.liveLongitude!),
        );
        if (point.distanceTo(other) < 64) {
          match = group;
          break;
        }
      }
      if (match == null) {
        groups.add([friend]);
      } else {
        match.add(friend);
      }
    }
    return MarkerLayer(
      markers: [
        for (final group in groups)
          Marker(
            point: LatLng(
              group.first.liveLatitude!,
              group.first.liveLongitude!,
            ),
            width: 76,
            height: 82,
            rotate: true,
            child: Semantics(
              button: true,
              label: group.length == 1
                  ? group.first.username
                  : 'Друзей рядом: ${group.length}',
              child: GestureDetector(
                onTap: () {
                  if (group.length == 1) {
                    onSelect(group.first);
                    return;
                  }
                  showModalBottomSheet<void>(
                    context: context,
                    builder: (sheetContext) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'Друзей рядом: ${group.length}',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          Flexible(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                for (final friend in group)
                                  ListTile(
                                    leading: CircleAvatar(
                                      backgroundImage: friend.avatarUrl == null
                                          ? null
                                          : NetworkImage(friend.avatarUrl!),
                                      child: friend.avatarUrl == null
                                          ? const Icon(Icons.person)
                                          : null,
                                    ),
                                    title: Text(friend.username),
                                    subtitle: Text(friend.positionAgeText),
                                    onTap: () {
                                      Navigator.pop(sheetContext);
                                      onSelect(friend);
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Center(child: markerBuilder(group.first)),
                    if (group.length > 1)
                      Positioned(
                        right: 0,
                        bottom: 15,
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: Colors.deepOrange,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: Text(
                            '${group.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
