import 'local_data_integrity.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activity_type.dart';

enum TrailStyle {
  automatic('По виду активности', Icons.auto_awesome_outlined),
  line('Обычная линия', Icons.horizontal_rule),
  footprints('Шаги', Icons.directions_walk),
  boots('Походные ботинки', Icons.hiking),
  running('Беговые следы', Icons.directions_run),
  nordic('Шаги и палки', Icons.nordic_walking),
  bicycle('Городской велосипед', Icons.pedal_bike),
  mountain('Протектор МТБ', Icons.terrain),
  road('Шоссейные шины', Icons.directions_bike),
  gravel('Гравийный протектор', Icons.route),
  scooter('Самокат', Icons.electric_scooter),
  car('Автомобильные колеи', Icons.directions_car),
  arrows('Стрелки направления', Icons.navigation_outlined),
  dots('Точки', Icons.more_horiz);

  const TrailStyle(this.label, this.icon);
  final String label;
  final IconData icon;
}

class TrailAppearance extends ChangeNotifier {
  TrailAppearance();
  static final instance = TrailAppearance();
  static const key = 'trail_appearance_v1';
  static const colors = [
    Colors.blue,
    Colors.deepOrange,
    Colors.teal,
    Colors.purple,
    Colors.green,
    Colors.pink,
    Colors.indigo,
    Colors.brown,
    Colors.black,
    Colors.red,
    Colors.amber,
    Colors.cyan,
  ];
  TrailStyle style = TrailStyle.automatic;
  TrailStyle friendStyle = TrailStyle.automatic,
      idleStyle = TrailStyle.footprints;
  bool onFriends = true, onIdle = true;
  int colorIndex = 0;
  double size = 11, spacing = 28, opacity = .85;
  bool guide = true, onRoutes = true, onRecording = true;
  Future<void> _tail = Future.value();
  bool _unknownVersion = false;
  bool _loaded = false;
  Color get color => colors[colorIndex];
  TrailStyle effective(
    ActivityType activity, {
    String? transport,
    TrailStyle? pattern,
  }) {
    final selected = pattern ?? style;
    if (selected != TrailStyle.automatic) return selected;
    if (activity.isFoot) {
      if (activity.isRunning) return TrailStyle.running;
      if (activity == ActivityType.nordicWalking) return TrailStyle.nordic;
      if (activity == ActivityType.trekking) return TrailStyle.boots;
      return TrailStyle.footprints;
    }
    if (transport == 'Самокат') return TrailStyle.scooter;
    return switch (activity) {
      ActivityType.driving => TrailStyle.car,
      ActivityType.roadCycling => TrailStyle.road,
      ActivityType.gravelRiding => TrailStyle.gravel,
      ActivityType.mountainBiking ||
      ActivityType.bikepacking => TrailStyle.mountain,
      _ => TrailStyle.bicycle,
    };
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'style': style.name,
    'friend_style': friendStyle.name,
    'idle_style': idleStyle.name,
    'friends': onFriends,
    'idle': onIdle,
    'color': colorIndex,
    'size': size,
    'spacing': spacing,
    'opacity': opacity,
    'guide': guide,
    'routes': onRoutes,
    'recording': onRecording,
  };
  double _number(Object? raw, double fallback, double min, double max) =>
      raw is num && raw.isFinite ? raw.toDouble().clamp(min, max) : fallback;
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.get(key);
    _loaded = true;
    if (raw == null) return;
    if (raw is! String) {
      _unknownVersion = true;
      return;
    }
    try {
      final data = jsonDecode(raw) as Map;
      _unknownVersion = data['version'] != 1;
      if (_unknownVersion) return;
      style =
          TrailStyle.values.where((s) => s.name == data['style']).firstOrNull ??
          TrailStyle.automatic;
      colorIndex = data['color'] is int
          ? (data['color'] as int).clamp(0, colors.length - 1)
          : 0;
      friendStyle =
          TrailStyle.values
              .where((s) => s.name == data['friend_style'])
              .firstOrNull ??
          TrailStyle.automatic;
      idleStyle =
          TrailStyle.values
              .where((s) => s.name == data['idle_style'])
              .firstOrNull ??
          TrailStyle.footprints;
      onFriends = data['friends'] is bool ? data['friends'] as bool : true;
      onIdle = data['idle'] is bool ? data['idle'] as bool : true;
      size = _number(data['size'], 11, 6, 20);
      spacing = _number(data['spacing'], 28, 16, 64);
      opacity = _number(data['opacity'], .85, .25, 1);
      guide = data['guide'] is bool ? data['guide'] as bool : true;
      onRoutes = data['routes'] is bool ? data['routes'] as bool : true;
      onRecording = data['recording'] is bool
          ? data['recording'] as bool
          : true;
      notifyListeners();
    } catch (_) {
      _unknownVersion = true;
    }
  }

  Future<void> update({
    TrailStyle? pattern,
    int? color,
    double? markerSize,
    double? density,
    double? alpha,
    bool? showGuide,
    bool? routes,
    bool? recording,
    TrailStyle? friendsPattern,
    TrailStyle? idlePattern,
    bool? friends,
    bool? idle,
    bool reset = false,
  }) {
    final result = _tail.then((_) async {
      if (!_loaded) await load();
      if (_unknownVersion)
        throw StateError(
          'Формат оформления не читается. Исходные настройки не перезаписаны.',
        );
      final before = toJson();
      final next = <String, Object>{
        ...before,
        if (reset) ...{
          'style': 'automatic',
          'friend_style': 'automatic',
          'idle_style': 'footprints',
          'friends': true,
          'idle': true,
          'color': 0,
          'size': 11.0,
          'spacing': 28.0,
          'opacity': .85,
          'guide': true,
          'routes': true,
          'recording': true,
        },
        if (pattern != null) 'style': pattern.name,
        if (color != null) 'color': color.clamp(0, colors.length - 1),
        if (markerSize != null) 'size': _number(markerSize, 11, 6, 20),
        if (density != null) 'spacing': _number(density, 28, 16, 64),
        if (alpha != null) 'opacity': _number(alpha, .85, .25, 1),
        if (showGuide != null) 'guide': showGuide,
        if (routes != null) 'routes': routes,
        if (recording != null) 'recording': recording,
        if (friendsPattern != null) 'friend_style': friendsPattern.name,
        if (idlePattern != null) 'idle_style': idlePattern.name,
        if (friends != null) 'friends': friends,
        if (idle != null) 'idle': idle,
      };
      final prefs = await SharedPreferences.getInstance();
      try {
        final previous = prefs.get(key);
        if (previous is String &&
            LocalDataIntegrity.unknownKeys(
              jsonDecode(previous) as Map,
              next.keys.toSet(),
            )) {
          await LocalDataIntegrity.preserve(prefs, key, previous);
        }
        if (!await prefs.setString(key, jsonEncode(next)))
          throw StateError('Не удалось сохранить оформление');
      } catch (_) {
        await prefs.reload();
        rethrow;
      }
      style = TrailStyle.values.firstWhere((s) => s.name == next['style']);
      colorIndex = next['color'] as int;
      size = (next['size'] as num).toDouble();
      spacing = (next['spacing'] as num).toDouble();
      opacity = (next['opacity'] as num).toDouble();
      guide = next['guide'] as bool;
      onRoutes = next['routes'] as bool;
      onRecording = next['recording'] as bool;
      friendStyle = TrailStyle.values.firstWhere(
        (s) => s.name == next['friend_style'],
      );
      idleStyle = TrailStyle.values.firstWhere(
        (s) => s.name == next['idle_style'],
      );
      onFriends = next['friends'] as bool;
      onIdle = next['idle'] as bool;
      notifyListeners();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
