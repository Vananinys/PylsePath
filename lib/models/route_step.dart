import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;

class RouteStep {
  final String instruction;
  final String streetName;
  final IconData icon;
  final LatLng location;
  final double distance;
  final double routeOffsetMeters;

  RouteStep({
    required this.instruction,
    required this.streetName,
    required this.icon,
    required this.location,
    required this.distance,
    this.routeOffsetMeters = 0,
  });

  Map<String, dynamic> toJson() => {
    'instruction': instruction,
    'street': streetName,
    'icon': icon.codePoint,
    'lat': location.latitude,
    'lon': location.longitude,
    'distance': distance,
    'offset': routeOffsetMeters,
  };

  static RouteStep? fromJson(dynamic value) {
    if (value is! Map) return null;
    final lat = value['lat'],
        lon = value['lon'],
        offset = value['offset'],
        distance = value['distance'];
    if (lat is! num ||
        lon is! num ||
        offset is! num ||
        distance is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        !offset.isFinite ||
        !distance.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180 ||
        offset < 0 ||
        distance < 0)
      return null;
    const icons = [
      Icons.turn_left,
      Icons.turn_right,
      Icons.flag,
      Icons.straight,
    ];
    return RouteStep(
      instruction: value['instruction']?.toString() ?? 'Следуйте по маршруту',
      streetName: value['street']?.toString() ?? '',
      icon:
          icons.where((icon) => icon.codePoint == value['icon']).firstOrNull ??
          Icons.straight,
      location: LatLng(lat.toDouble(), lon.toDouble()),
      distance: distance.toDouble(),
      routeOffsetMeters: offset.toDouble(),
    );
  }
}
