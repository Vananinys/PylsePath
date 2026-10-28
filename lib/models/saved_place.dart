import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../utils/ride_id.dart';

enum SavedPlaceKind {
  home('Дом', Icons.home_outlined),
  work('Работа', Icons.work_outline),
  start('Место старта', Icons.flag_outlined),
  water('Вода', Icons.water_drop_outlined),
  parking('Мой велосипед', Icons.pedal_bike),
  other('Другое', Icons.bookmark_outline);

  const SavedPlaceKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Personal device-only point; never part of public map reports or ride exports.
class SavedPlace {
  factory SavedPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    SavedPlaceKind kind = SavedPlaceKind.other,
  }) {
    final clean = name.trim();
    final identity = id ?? newRideId();
    if (identity.isEmpty ||
        identity.length > 80 ||
        clean.isEmpty ||
        clean.length > 80 ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      throw const FormatException('Некорректное название или координаты места');
    }
    return SavedPlace._(identity, clean, latitude, longitude, kind);
  }

  const SavedPlace._(
    this.id,
    this.name,
    this.latitude,
    this.longitude,
    this.kind,
  );
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final SavedPlaceKind kind;
  LatLng get point => LatLng(latitude, longitude);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'kind': kind.name,
  };

  factory SavedPlace.fromJson(Map<String, dynamic> json) {
    final kind = SavedPlaceKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    if (json['id'] is! String ||
        json['name'] is! String ||
        json['latitude'] is! num ||
        json['longitude'] is! num ||
        kind == null) {
      throw const FormatException('Повреждена запись места');
    }
    return SavedPlace(
      id: json['id'] as String,
      name: json['name'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      kind: kind,
    );
  }
}
